#!/usr/bin/env bash
## Assumptions
# A ssh key is available to connect to the remote machine
# You are running this from the destination (local) machine

# Utility vars
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
if [[ two_remotes -eq 1 ]]; then
  _warning "Validating second remotes ssh.."
  _validateSsh "${remote2_ssh_user}@${remote2_ssh_host}" ${remote2_ssh_port}
fi
_testFs
_note "Validations Complete"

remote_backup_file_path="${local_db_dump_dir}${remote_db_dump_file_name}_${date_stamp}.sql.gz"
if [[ two_remotes -eq 1 ]]; then
    local_backup_file_path="${local_db_dump_dir}${local_db_dump_file_name}_remote2_${date_stamp}.sql.gz"
else
    local_backup_file_path="${local_db_dump_dir}${local_db_dump_file_name}_${date_stamp}.sql.gz"
fi

_header "Local DB Backup"
  # Backup local db ###########################################################
 # If skip_local_db_dump
if [[ skip_local_db_dump -ne 1 ]]; then
    # See https://github.com/netz98/n98-magerun2#stripped-database-dump for strip options
    # Strip Personally Identifiable info in all cases possible! @trade strips most PII
    if [[ local_uses_ddev -eq 1 ]]; then
        _note "DDEV db dump started"
        ddev export-db --database=${local_db_name} -f ${local_backup_file_path}
    elif [[ two_remotes -eq 1 ]]; then
        _note "Backing up remote #2"
        ssh $remote2_ssh_user@$remote2_ssh_host "${remote2_n98_command} -v --root-dir=${remote2_magento_root} db:dump --no-tablespaces --strip=\"${remote_strip_string}\" --stdout | gzip -9" | pv > ${local_backup_file_path}
    else
        ${local_n98_command} --root-dir=${local_magento_root} db:dump -v --compression="gzip" --no-tablespaces --strip="${local_strip_string}" ${local_backup_file_path}
    fi
    # If backup file isn't found, exit, otherwise note the file path and size
    if [[ ! -s "${local_backup_file_path}" ]]; then
        _die "Local DB dump failed! Aborting!"
    fi

    _success "Local DB backup complete, file is "${local_backup_file_path}" with size of $((`du -k ${local_backup_file_path} | cut -f1` / 1024))MB"
else
    _warning "Skipping local db dump"
fi

# Backup core_config_data table if preserve_core_config is set
if [[ preserve_core_config -eq 1 ]]; then
    _header "Core Config Data Backup"
    core_config_backup_file="${local_db_dump_dir}core_config_data_${date_stamp}.sql.gz"
    if [[ local_uses_ddev -eq 1 ]]; then
        ddev exec -s web "mysqldump ${local_db_name} core_config_data | gzip" | pv > ${core_config_backup_file}
    else
    ${local_n98_command} --root-dir=${local_magento_root} db:dump -v --include=core_config_data --stdout | gzip -9 | pv > ${core_config_backup_file}
    fi
    if [[ ! -s "${core_config_backup_file}" ]]; then
        _die "Core config data backup failed! Aborting!"
    fi
    _success "Core config data backup complete, file is "${core_config_backup_file}" with size of $((`du -k ${core_config_backup_file} | cut -f1` / 1024))MB"
fi

# Pull down remote db ##################################################
_header "Remote DB backup and download"
if [[ two_remotes -eq 1 ]]; then
    _warning "This backup will be imported to remote #2"
fi
if [[ skip_to_restore -eq 1 ]]; then
    _header "Skipping backup and going right to restoring with file ${backup_file_location}${backup_file_name}"
    remote_backup_file_path="${backup_file_location}${backup_file_name}"
    _success "Using existing backup at "${remote_backup_file_path}" with size of $((`du -k ${remote_backup_file_path} | cut -f1` / 1024))MB"
else
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

    # Exclude tables string to add to the remote n98 command
    if [[ -n "${exclude_tables}" ]]; then
        remote_exclude_tables="--exclude=\"${exclude_tables}\""
        # Update remote n98 command
        remote_n98_command="${remote_n98_command} ${remote_exclude_tables}"
        # Echo updated command
        # echo "Using updated remote n98 command: ${remote_n98_command}"
    fi

    # Dump the data with exclusions
    remote_data_backup_file="${local_db_dump_dir}${remote_db_dump_file_name}_data_${date_stamp}.sql.gz"
    _arrow "Pulling down remote data dump to ${remote_data_backup_file}"
    ssh $remote_ssh_user@$remote_ssh_host "${remote_n98_command} -v --root-dir=${remote_magento_root} db:dump --no-tablespaces --strip=\"${remote_strip_string}\" ${remote_exclude_tables} --stdout | gzip -9" | pv > ${remote_data_backup_file}
    if [[ $? -ne 0 ]]; then
        _die "Remote DB data dump failed! Aborting!"
    fi
    _success "Remote DB data pulled down to ${remote_data_backup_file} with size of $((`du -k ${remote_data_backup_file} | cut -f1` / 1024))MB"

    # Combine the schema and data dumps
    combined_backup_file="${local_db_dump_dir}${remote_db_dump_file_name}_combined_${date_stamp}.sql.gz"
    _arrow "Combining schema and data dumps into ${combined_backup_file}"
    zcat ${remote_schema_backup_file} ${remote_data_backup_file} | gzip -9 > ${combined_backup_file}
    if [[ $? -ne 0 ]]; then
        _die "Combining schema and data dumps failed! Aborting!"
    fi
    _success "Combined DB dump created at ${combined_backup_file} with size of $((`du -k ${combined_backup_file} | cut -f1` / 1024))MB"
    remote_backup_file_path="${combined_backup_file}"
fi

# Confirm the file was saved, if not - die
if [[ ! -s "${remote_backup_file_path}" ]]; then
    _die "Remote DB dump filepath not working! Aborting!"
fi

# Start local processing ##################################################
# Restore backup from remote into local using ddev or n98
_warning "Restoring remote backup to local database"
if [[ local_uses_ddev -eq 1 ]]; then
    ${local_zcat_cmd} "${remote_backup_file_path}" | pv | ddev import-db --database=${local_db_name}
elif [[ two_remotes -eq 1 ]]; then
    rsync --progress ${remote_backup_file_path} ${remote2_ssh_user}@${remote2_ssh_host}:/tmp/
    ssh $remote2_ssh_user@$remote2_ssh_host "${remote2_n98_command} --root-dir=${remote2_magento_root} db:import --drop --compression=gzip /tmp/${remote_db_dump_file_name}_${date_stamp}.sql.gz"
else
    ${local_n98_command} --root-dir=${local_magento_root} db:import --drop --compression=gzip ${remote_backup_file_path}
fi
_errorExitPromptNoSuccessMsg $? "DB restore into local did not return a 0 result! Continue anyway?"

_success "DB import complete."

# Restore core_config_data table if preserve_core_config is set
if [[ preserve_core_config -eq 1 ]]; then
    _warning "Restoring core_config_data table"
    if [[ local_uses_ddev -eq 1 ]]; then
        ${local_zcat_cmd} "${core_config_backup_file}" | ddev import-db --no-drop --database=${local_db_name}
    elif [[ two_remotes -eq 1 ]]; then
        ssh $remote2_ssh_user@$remote2_ssh_host "zcat /tmp/${remote_db_dump_file_name}_${date_stamp}.sql.gz" | pv | ${remote2_n98_command} --root-dir=${remote2_magento_root} db:import --compression=gzip
    else
        ${local_zcat_cmd} "${core_config_backup_file}" | pv | ${local_n98_command} --root-dir=${local_magento_root} db:import --compression=gzip
    fi
    if [[ $? -ne 0 ]]; then
        _die "Core config data restore failed! Aborting!"
    fi
    _success "Core config data restore complete."
fi

# Remove backups if configured to
if [[ keep_remote_backups -eq 0 ]]; then
    _warning "Removing remote backup from local filesystem"
    rm ${remote_backup_file_path}
    _errorExitPromptNoSuccessMsg $? "Removal of locally stored remote DB backup Failed! You'll need to remove this manually. Continue anyway?"
    if [[ two_remotes -eq 1 ]]; then
        ssh $remote2_ssh_user@$remote2_ssh_host "rm /tmp/${remote_db_dump_file_name}_${date_stamp}.sql.gz"
        _errorExitPromptNoSuccessMsg $? "Removal of remotely stored remote DB backup Failed! You'll need to remove this manually. Continue anyway?"
    fi
fi

# Only execute the following blocks if preserve_core_config is not set
if [[ preserve_core_config -ne 1 ]]; then
    # replace URLs per your local config only for web*url paths
    _warning "Starting replacements in core_config_data"
    for i in ${replacement_array[@]} ; do
    #      %:* means - starting on the right and moving left, select everything from : onward (First half)
    #      #*: means - starting on the left and moving right, select everything from : onward (Second half)
        KEY=${i%:*};
        VAL=${i#*:};
        if [[ two_remotes -eq 1 ]]; then
            ssh $remote2_ssh_user@$remote2_ssh_host ${remote2_n98_command} --root-dir=${remote2_magento_root} db:query "UPDATE core_config_data SET \`value\` = REPLACE(\`value\`, '${KEY}', '${VAL}') WHERE path LIKE \"%web/%url%\" OR path LIKE \"%cookie%\""
        else
            ${local_n98_command} --root-dir=${local_magento_root} db:query "UPDATE core_config_data SET \`value\` = REPLACE(\`value\`, '${KEY}', '${VAL}') WHERE path LIKE \"%web/%url%\" OR path LIKE \"%cookie%\""
        fi
        _errorExitPromptNoSuccessMsg $? "DB replacements did not return a 0 result! Continue anyway?"
        _success "${KEY} instances replaced with '${VAL}'"
    done
    _success "Domain replacements complete"

    # Remove config values matching removal paths
    _warning "Starting value removals in core_config_data"
    for i in ${removal_array[@]} ; do
            if [[ two_remotes -eq 1 ]]; then
               ssh $remote2_ssh_user@$remote2_ssh_host ${remote2_n98_command} --root-dir=${remote2_magento_root} db:query "UPDATE core_config_data SET \`value\` = '' WHERE path LIKE \"${i}\""
            else
            ${local_n98_command} --root-dir=${local_magento_root} db:query "UPDATE core_config_data SET \`value\` = '' WHERE path LIKE \"${i}\""
            fi
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
fi

# Apply local configs
_arrow "app:config:import beginning"
if [[ two_remotes -eq 1 ]]; then
   ssh $remote2_ssh_user@$remote2_ssh_host ${remote2_n98_command} --root-dir=${remote2_magento_root} app:config:import
else
${local_n98_command} --root-dir=${local_magento_root} app:config:import
fi
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

# Media Sync ##################################################
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

_success "Finished at $(date +%Y-%m-%d-%H:%M:%S)"
endtime=$(date +%s)
deltatime=$(($endtime - $starttime))
echo "Time elapsed was "$(_convertsecs $deltatime)
_safeExit
