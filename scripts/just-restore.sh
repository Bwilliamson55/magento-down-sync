#!/usr/bin/env bash
## Assumptions
# A ssh key is available to connect to the remote machine
# You are running this from the destination (local) machine

## This only runs the restore steps of the down-sync process, Database only

#utility vars
date_stamp=$(date +%Y%m%d%H%M%S)
starttime=$(date +%s)
conf_file=down-sync.conf

# Pull in config
if [[ ! -s "$conf_file" ]]; then
    echo "Config file ${conf_file} missing!"
    exit 1;
fi

if [[ ! -s "functions.sh" ]]; then
    echo "functions script missing!"
    exit 1;
fi

. "functions.sh"
_success "Functions loaded"
. "$conf_file"
_success "Config file loaded"

# Update local n98 command if using ddev
if [[ local_uses_ddev -eq 1 ]]; then
    local_n98_command="ddev exec -s web "${local_n98_command}
    echo "Using ddev n98 command: ${local_n98_command}"
fi

_arrow "Starting at $(date +%Y-%m-%d-%H:%M:%S)"
_header "****** Using $conf_file to begin down sync from ${remote_ssh_host} ******"

# Run validators and tests
_arrow "Validations Starting"
_testRequiredCmds
_validateSsh "${remote_ssh_user}@${remote_ssh_host}" ${remote_ssh_port}
_testFs
_note "Validations Complete"

#Restore backup from remote into local
if [[ local_uses_ddev -eq 1 ]]; then
    ${local_zcat_cmd} "${remote_backup_file_path}" | pv | ddev import-db --database=${local_db_name}
else
    ${local_n98_command} --root-dir=${local_magento_root} db:import --drop --compression=gzip ${remote_backup_file_path}
fi
_errorExitPromptNoSuccessMsg $? "DB restore into local did not return a 0 result! Continue anyway?"

_success "DB import complete."

_success "Finished at $(date +%Y-%m-%d-%H:%M:%S)"
endtime=$(date +%s)
deltatime=$(($endtime - $starttime))
echo "Time elapsed was "$(_convertsecs $deltatime)
_safeExit
