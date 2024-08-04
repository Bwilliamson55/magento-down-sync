#!/usr/bin/env bash

## This only runs the Replace, Add, Remove, and Config Import steps of the down-sync process

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

. "${conf_file}"
echo "Config file loaded"
. "functions.sh"
_success "Functions loaded"
_arrow "Starting at $(date +%Y-%m-%d-%H:%M:%S)"
_header "****** Using $conf_file to begin down sync from ${remote_ssh_host} ******"

# Update local n98 command if using ddev
if [[ local_uses_ddev -eq 1 ]]; then
    local_n98_command="ddev exec -s web --raw "${local_n98_command}
fi

# Run validators and tests
_arrow "Validations Starting"
_testRequiredCmds
_testFs
_note "Validations Complete"

# replace URLs per your local config only for web*url paths
_warning "Starting replacements in core_config_data"
for i in ${replacement_array[@]} ; do
#      %:* means - starting on the right and moving left, select everything from : onward (First half)
#      #*: means - starting on the left and moving right, select everything from : onward (Second half)
    KEY=${i%:*};
    VAL=${i#*:};
    ${local_n98_command} --root-dir=${local_magento_root} db:query "UPDATE core_config_data SET \`value\` = REPLACE(\`value\`, '${KEY}', '${VAL}') WHERE path LIKE \"%web/%url%\" OR path LIKE \"%cookie%\""
    _errorExitPromptNoSuccessMsg $? "DB replacements did not return a 0 result! Continue anyway?"
    _success "${KEY} instances replaced with '${VAL}'"
done
_success "Domain replacements complete"

# Remove config values matching removal paths
_warning "Starting value removals in core_config_data"
for i in ${removal_array[@]} ; do
    ${local_n98_command} --root-dir=${local_magento_root} db:query "UPDATE core_config_data SET \`value\` = '' WHERE path LIKE \"${i}\""
    _errorExitPromptNoSuccessMsg $? "DB removals did not return a 0 result! Continue anyway?"
    _success "${i} values removed"
done
_success "Config removals complete"

# Replace or add values via scope, scopeid, path, value
_warning "Starting additions and updates in core_config_data"

for i in "${addition_array[@]}"; do
    scope=$(echo "$i" | awk -F '::' '{print $1}')
    scope_id=$(echo "$i" | awk -F '::' '{print $2}')
    key=$(echo "$i" | awk -F '::' '{print $3}')
    value=$(echo "$i" | awk -F '::' '{print $4}')

    ${local_n98_command} --root-dir="${local_magento_root}" config:store:set --scope="$scope" --scope-id="$scope_id" "$key" "$value"
    _errorExitPromptNoSuccessMsg $? "Config updates did not return a 0 result! Continue anyway?"
    _success "$key updated with value $value for scope $scope - scope_id-$scope_id"
done

_success "Config updates complete"


# apply local configs
_arrow "app:config:import beginning"
${local_n98_command} --root-dir=${local_magento_root} app:config:import
_errorExitPromptNoSuccessMsg $? "Config import into local via N98 did not return a 0 result! Continue anyway?"

#Scramble email addresses with configured exclusions
if [[ anon_email -eq 1 ]]; then
    _success "Email anonymizer starting.."

    for table_and_column in "${email_anonymization_tables[@]}"; do
        #      %:* means - starting on the right and moving left, select everything from : onward (First half)
        #      #*: means - starting on the left and moving right, select everything from : onward (Second half)
        table=${table_and_column%:*}
        column=${table_and_column#*:}
        _arrow "Anonymizing emails in ${table}.${column}"
        anonymize_email "$table" "$column"
    done
    _success "Email anonymizer finished"
fi

_success "Finished at $(date +%Y-%m-%d-%H:%M:%S)"
endtime=$(date +%s)
deltatime=$(($endtime - $starttime))
echo "Time elapsed was "$(_convertsecs $deltatime)
_safeExit
