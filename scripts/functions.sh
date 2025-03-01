#!/bin/bash
#
# Pretty stuff
#
_bold=$(tput bold)
_underline=$(tput sgr 0 1)
_reset=$(tput sgr0)

_purple=$(tput setaf 171)
_red=$(tput setaf 1)
_green=$(tput setaf 76)
_tan=$(tput setaf 3)
_blue=$(tput setaf 38)

anonymize_email() {
    local table=$1
    local email_column=$2

    if [[ two_remotes -eq 1 ]]; then
        ssh $remote2_ssh_user@$remote2_ssh_host "${remote2_n98_command} --root-dir=${remote2_magento_root} db:query 'UPDATE \`${table}\` SET \`${email_column}\` = REPLACE(\`${email_column}\`, SUBSTRING(\`${email_column}\`, LOCATE(\"@\", \`${email_column}\`)), CONCAT(\"+\", SUBSTRING(MD5(SUBSTRING(\`${email_column}\`, LOCATE(\"@\", \`${email_column}\`))) FROM 1 FOR 6), \"@${anon_email_domain}\")) WHERE \`${email_column}\` NOT LIKE \"%@${exclude_email_domain}\"'"
    else
        ${local_n98_command} --root-dir=${local_magento_root} db:query "UPDATE \`${table}\` SET \`${email_column}\` = REPLACE(\`${email_column}\`, SUBSTRING(\`${email_column}\`, LOCATE('@', \`${email_column}\`)), CONCAT('+', SUBSTRING(MD5(SUBSTRING(\`${email_column}\`, LOCATE('@', \`${email_column}\`))) FROM 1 FOR 6), '@${anon_email_domain}')) WHERE \`${email_column}\` NOT LIKE '%@${exclude_email_domain}'"
    fi
    _errorExitPromptNoSuccessMsg $? "Anonymizing emails in ${table}.${email_column} did not return a 0 result! Continue anyway?"
}

function _header() {
  printf '\n%s%s==========  %s  ==========%s\n' "$_bold" "$_blue" "$@" "$_reset"
}

function _arrow() {
  printf '➜ %s\n' "$@"
}

function _success() {
  printf '%s✔ %s%s\n' "$_green" "$@" "$_reset"
}

function _error() {
  printf '%s✖ %s%s\n' "$_red" "$@" "$_reset"
}

function _warning() {
  printf '%s➜ %s%s\n' "$_tan" "$@" "$_reset"
}

function _underline() {
  printf '%s%s%s%s\n' "$_underline" "$_bold" "$@" "$_reset"
}

function _bold() {
  printf '%s%s%s\n' "$_bold" "$@" "$_reset"
}

function _note() {
  printf '%s%s%sNote:%s %s%s%s\n' "$_underline" "$_bold" "$_blue" "$_reset" "$_blue" "$@" "$_reset"
}

#
# Utility
#

# Convert seconds to hh:mm:ss format
function _convertsecs() {
  ((h = ${1} / 3600))
  ((m = (${1} % 3600) / 60))
  ((s = ${1} % 60))
  printf "%02d:%02d:%02d\n" $h $m $s
}

function _die() {
  _error "$@"
  exit 1
}

function _safeExit() {
  exit 0
}

function _confirmOrDie() {
  local message=${1:?$(_error "The message for the confirmation must be provided")}
  _warning "$1"
  select yn in "Yes" "No"; do
    case $yn in
    Yes)
      break
      ;;
    No)
      _safeExit
      break
      ;;
    esac
  done
}

#
# Validation and checks
#

# Throw a confirmation message if the passed in result is not 0
function _errorExitPrompt() {
  local res=${1:?$(_error "The result needs to be supplied (1 or 0 usually)")}
  local msg=${2:-"Success, I guess"}
  local emsg=${3:-"$res There were errors; you should fix them. Continue anyway?"}
  case "$res" in
    0) _success "$msg" ;;
    *) _confirmOrDie "$emsg" ;;
  esac
}

# If you want to catch an error but not output anything on success
function _errorExitPromptNoSuccessMsg() {
  local res=${1:?$(_error "The result needs to be supplied (1 or 0 usually)")}
  local emsg=${2:-"$res There were errors; you should fix them. Continue anyway?"}
  case "$res" in
    0)  ;;
    *) _confirmOrDie "$emsg" ;;
  esac
}

# Using batchmode for a "quick" ssh verification
function _validateSsh() {
  local ssh_target_host=${1:?$(_error "The ssh target host ip or fqdn needs to be defined")}
  local ssh_port=${2:?$(_error "The SSH port for $1 needs to be defined")}
  local timeout=${3:-5}
  ssh -p ${ssh_port} -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=${timeout} ${ssh_target_host} 'exit 0'
  _errorExitPrompt $? "SSH connection works" "SSH doesn't work. Continue anyway?"
}

# Test the handed in string as a command
function _cmdExists() {
  command -v "$1" >/dev/null 2>&1
}

# Use the array passed in (@) and run each command, but output directly to null
function _cmdsExist() {
  local check=(${@:?$(_error "Commands array must be provided for validation")})
  local cmds=("$@")
  local error=0
  for c in "${cmds[@]}"; do
    if _cmdExists ${c}; then
      _success "${c} found"
    else
      _error "${c} not found"
      error=1
    fi
  done
  $(exit "${error}")
}

# Pass the configured array to the exists function
function _testRequiredCmds() {
  _header "Checking that commands exist locally"
  _warning "This does not check these cmds on the remote machine"
  _cmdsExist "${required_cmds_test[@]}"
  _errorExitPrompt $? "All cmds found!"
}

# Run a "USE" statement on the configured mysql servers to verify they work
function _testMysql() {
  _header "Checking Mysql Connections"
  local error=0

  _note "Checking local mysql connection"
  if [[ ${local_uses_ddev} -eq 1 ]]; then
    ddev exec -s web "${local_mysql_cmd} ${local_mysql_creds_and_dbname} -e \"use ${local_db_name}\"" 2>/dev/null
  elif [[ $two_remotes -eq 1 ]]; then
      ssh -p ${remote2_ssh_port} ${remote2_ssh_user}@${remote2_ssh_host} "${remote2_mysql_cmd} ${remote2_mysql_creds_and_dbname} -e \"use ${remote2_db_name}\"" 2>/dev/null
  else
    ${local_mysql_cmd} ${local_mysql_creds_and_dbname} -e "use ${local_db_name}" #2>/dev/null
  fi
  case "$?" in
    0) _success "Local mysql connection works" ;;
    *) _error "$? Local mysql connection does not work"; error=1; ;;
  esac
  #Remote
  _note "Checking remote mysql connection"
  ssh -p ${remote_ssh_port} ${remote_ssh_user}@${remote_ssh_host} "${remote_mysql_cmd} ${remote_mysql_creds_and_dbname} -e \"use ${remote_db_name}\"" 2>/dev/null
  case "$?" in
    0) _success "Remote mysql connection works" ;;
    *) _error "$? Remote mysql connection does not work"; error=1; ;;
  esac
  _errorExitPrompt $error "Mysql looks good!" "Mysql did not pass all checks. Continue anyway?"
}

# Test file system and verify the configured paths work
function _testFs() {
  local error=0
  _header "Checking for access to the file system"

  _note "Checking dbdump location"
  touch ${local_db_dump_dir}${remote_db_dump_file_name}.sql.gz.test
  [ -w $_ ]
  case "$?" in
    0) _success "Local fs works"; rm ${local_db_dump_dir}${remote_db_dump_file_name}.sql.gz.test ;;
    *) _error "$? Local fs not working - check path and permissions"; error=1; ;;
  esac
  _note "Checking rsync location"
  #Check for read permissions only
  ssh -p ${remote_ssh_port} ${remote_ssh_user}@${remote_ssh_host} "test -r $remote_config_path"
  case "$?" in
    0) _success "Remote fs works" ;;
    *) _error "$? Remote fs not working - check ssh and permissions"; error=1; ;;
  esac
  _errorExitPrompt $error "Filesystem looks good!" "Filesystem did not pass all checks. Continue anyway?"
}
