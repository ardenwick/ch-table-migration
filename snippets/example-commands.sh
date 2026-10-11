./ch-table-migration init tasks/http_log_local --log-level debug \
    --force --create --start \
    --chc "--user=operator --password=default" \
    --db business --local http_log_local \
    --partitionby 'toDate(timestamp)' --primarykey ' ' --orderby '(tenant,timestamp)' \
    -v STATE_MigrateData_DATETIME_COLUMN=timestamp \
    -v STATE_DropTables_DROP_OLD_TABLE_IF_CONSISTENT=true;
