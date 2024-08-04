#!/usr/bin/env bash
## Assumptions
# A ssh key is available to connect to the remote machine
# You are running this from the destination (local) machine

## This only runs the download steps of the down-sync process, Media, and Database

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
_validateSsh "${remote_ssh_user}@${remote_ssh_host}" ${remote_ssh_port}
_testFs
_note "Validations Complete"

# Sync media from remote
if [[ sync_media -eq 1 ]]; then
    _arrow "Syncing media from remote and excluding ${exclude_media_dirs}"

    # Convert the exclude_media_dirs string into an array
    IFS=',' read -r -a exclude_dirs_array <<< "$exclude_media_dirs"

    # Create the exclude arguments for rsync
    exclude_args=()
    for dir in "${exclude_dirs_array[@]}"; do
        exclude_args+=("--exclude=$dir")
    done

    # Execute rsync with the exclude arguments
    rsync -avz "${exclude_args[@]}" --progress $remote_ssh_user@$remote_ssh_host:$remote_media_path $local_media_path

    _errorExitPromptNoSuccessMsg $? "Rsync did not return a 0 result! Continue anyway?"
    _success "Media sync complete"
fi

_header "Remote DB backup and download"
# Get creds for mysqldump directly, for schema specifically
_arrow "Gathering db creds from remote for schema dump"
_arrow "Getting Host.."
db_host=$(ssh $remote_ssh_user@$remote_ssh_host "${remote_n98_command} --root-dir=${remote_magento_root} config:env:show db.connection.default.host")
_arrow "Getting Name.."
db_name=$(ssh $remote_ssh_user@$remote_ssh_host "${remote_n98_command} --root-dir=${remote_magento_root} config:env:show db.connection.default.dbname")
_arrow "Getting User.."
db_user=$(ssh $remote_ssh_user@$remote_ssh_host "${remote_n98_command} --root-dir=${remote_magento_root} config:env:show db.connection.default.username")
_arrow "Getting Pass.."
db_pass=$(ssh $remote_ssh_user@$remote_ssh_host "${remote_n98_command} --root-dir=${remote_magento_root} config:env:show db.connection.default.password")

# Dump the schema (DDL) only
remote_schema_backup_file="${local_db_dump_dir}${remote_db_dump_file_name}_schema_${date_stamp}.sql.gz"
_arrow "Pulling down remote schema dump to ${remote_schema_backup_file}"
ssh $remote_ssh_user@$remote_ssh_host "mysqldump -h ${db_host} -u ${db_user} -p${db_pass} --no-data ${db_name} | gzip -9" | pv > ${remote_schema_backup_file}
if [[ $? -ne 0 ]]; then
    _die "Remote DB schema dump failed! Aborting!"
fi
_success "Remote DB schema pulled down to ${remote_schema_backup_file} with size of $((`du -k ${remote_schema_backup_file} | cut -f1` / 1024))MB"

# Exlude tables string to add to the remote n98 command
if [[ -n "${exclude_tables}" ]]; then
    remote_exclude_tables="--exclude=\"${exclude_tables}\""
    # Update remote n98 command
    remote_n98_command="${remote_n98_command} ${remote_exclude_tables}"
    # Echo updated command
    # echo "Using updated remote n98 command: ${remote_n98_command}"
fi

# Dump the data with exclusions
remote_data_backup_file="${local_db_dump_dir}${remote_db_dump_file_name}_data_${date_stamp}.sql.gz"
ssh $remote_ssh_user@$remote_ssh_host "${remote_n98_command} -v --root-dir=${remote_magento_root} db:dump --no-tablespaces --strip=\"${remote_strip_string}\" ${remote_exclude_tables} --stdout | gzip -9" | pv > ${remote_data_backup_file}
if [[ $? -ne 0 ]]; then
    _die "Remote DB data dump failed! Aborting!"
fi
_success "Remote DB data pulled down to ${remote_data_backup_file} with size of $((`du -k ${remote_data_backup_file} | cut -f1` / 1024))MB"

# Combine the schema and data dumps
combined_backup_file="${local_db_dump_dir}${remote_db_dump_file_name}_combined_${date_stamp}.sql.gz"
zcat ${remote_schema_backup_file} ${remote_data_backup_file} | gzip -9 > ${combined_backup_file}
if [[ $? -ne 0 ]]; then
    _die "Combining schema and data dumps failed! Aborting!"
fi
_success "Combined DB dump created at ${combined_backup_file} with size of $((`du -k ${combined_backup_file} | cut -f1` / 1024))MB"
remote_backup_file_path="${combined_backup_file}"

_success "Finished at $(date +%Y-%m-%d-%H:%M:%S)"
endtime=$(date +%s)
deltatime=$(($endtime - $starttime))
echo "Time elapsed was "$(_convertsecs $deltatime)
_safeExit
