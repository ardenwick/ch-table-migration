#!/bin/bash

declare -g MYPID=$BASHPID

# Logging facility
export NORMAL=$'\e[0m' BOLD=$'\e[1m' FAINT=$'\e[2m' ITALIC=$'\e[3m' UNDERLINE=$'\e[4m' REVERSED=$'\e[7m'
export RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' BLUE=$'\e[34m' MAGENTA=$'\e[35m' CYAN=$'\e[36m' WHITE=$'\e[37m' 
export BG_RED=$'\e[41m' BG_GREEN=$'\e[42m' BG_YELLOW=$'\e[43m' BG_BLUE=$'\e[44m' BG_MAGENTA=$'\e[45m' BG_CYAN=$'\e[46m' BG_WHITE=$'\e[47m'
export NC=$'\e[0m' RST=$'\e[0m'

export LOG_FD_STDOUT=11 LOG_FD_STDERR=12
eval "exec $LOG_FD_STDOUT>&1 $LOG_FD_STDERR>&2"

# level name ==> level priority number
declare -A LOG_LEVELS=( [TRACE]=1 [DEBUG]=10 [INFO]=20 [NOTIFY]=25 [WARN]=30 [ERROR]=40 [FATAL]=50 )
# level name ==> color escape sequence
declare -A LOG_COLORS=( [TRACE]="$FAINT$WHITE" [DEBUG]="$FAINT$GREEN" [INFO]="$BOLD$WHITE" [NOTIFY]="$UNDERLINE$BOLD$YELLOW" [WARN]="$BOLD$YELLOW" [ERROR]="$BOLD$RED" [FATAL]="$REVERSED$RED" )

declare -gu LOG_LEVEL=${LOG_LEVEL:-INFO}

function LOG() {
    local MYPID=${MYPID:-$BASHPID}
    local levelName=$1; shift; local s="$*"
    [[ ${LOG_LEVELS[$levelName]} ]] || return 0
    (( ${LOG_LEVELS[$levelName]} < ${LOG_LEVELS[$LOG_LEVEL]} )) && return 0

    local time=$(date +'%F %T.%3N') color=${LOG_COLORS[$levelName]}
    echo -e "$MAGENTA$time$NC <$MAGENTA$MYPID$NC> [${color}${levelName}$NC] ${color}${s}$NC"
}

function log_trace(){ local MYPID=${MYPID:-$BASHPID}; ( set +x; LOG TRACE "$@" >&$LOG_FD_STDOUT ); }
function log_debug(){ local MYPID=${MYPID:-$BASHPID}; ( set +x; LOG DEBUG "$@" >&$LOG_FD_STDOUT ); }
function log_info(){ local MYPID=${MYPID:-$BASHPID}; ( set +x; LOG INFO "$@" >&$LOG_FD_STDOUT ); }
function log_notify(){ local MYPID=${MYPID:-$BASHPID}; ( set +x; LOG NOTIFY "$@" >&$LOG_FD_STDOUT ); }
function log_warn(){ local MYPID=${MYPID:-$BASHPID}; ( set +x; LOG WARN "$@" >&$LOG_FD_STDERR ); }
function log_warning(){ local MYPID=${MYPID:-$BASHPID}; ( set +x; LOG WARN "$@" >&$LOG_FD_STDERR ); }
function log_error(){ local MYPID=${MYPID:-$BASHPID}; ( set +x; LOG ERROR "$@" >&$LOG_FD_STDERR ); }
function log_fatal(){ local MYPID=${MYPID:-$BASHPID}; ( set +x; LOG FATAL "$@" >&$LOG_FD_STDERR ); }

function log_prefix() { local prefix=$1; awk "{ printf \"${MAGENTA}%s${NC} $prefix %s\n\",strftime(\"%F %T\"),\$0 }"; }
function log_error_prefix() { local prefix=$1; awk "{ printf \"${MAGENTA}%s${NC} $prefix %s\n\",strftime(\"%F %T\"),\$0 }" >&2; }

function get_color()
{
    local text="$*"; [ -z "$text" ] && text=$(cat);
    local hash=$(( 0x$(echo "$text" | sha256sum | cut -c 1-8) ))

    # Make a random RGB color that has constant brightness.
    # https://en.wikipedia.org/wiki/YCbCr

    # Note that this is darker than the middle relative luminance, see "Gamma_correction" and "Luma_(video)".
    # It still looks awesome.
    local y=128;

    local cb=$((hash % 256));
    local cr=$((hash / 256 % 256));

    local r=$(( (y*1000 + 1402 * (cr - 128)) / 1000 )); r=$(( r <= 255 ? r : 255 )); r=$(( r > 0 ? r : 0 ));
    local g=$(( (y*1000 - 344 * (cb - 128) - 714 * (cr - 128)) / 1000 )); g=$(( g <= 255 ? g : 255 )); g=$(( g > 0 ? g : 0 ));
    local b=$(( (y*1000 + 1772 * (cb - 128)) / 1000 )); b=$(( b <= 255 ? b : 255 )); b=$(( b > 0 ? b : 0 ));

    # ANSI escape sequence to set 24-bit foreground font color in terminal.
    echo $'\033'"[38;2;${r};${g};${b}m";
    # echo -e "text=$text\t y=$y\t cb=$cb\t cr=$cr\t r=$r\t g=$g\t b=$b" >&2
}

function timestamp_ms() { date +%s%3N; }
function datetime_ms() { date +'%Y-%m-%d %H:%M:%S.%3N'; }
function mktmp() { local file=$(mktemp /tmp/for_each_line2_XXXXXX); echo $file; log_trace "Temporary file $file required by ${FUNCNAME[1]}"; }
function rm_if_empty() {  local f=$1; if [ $(stat -c %s "$f") == '0' ]; then rm -f "$f"; fi; }

declare -g SIGNAL_QUEUE_FILE=for_each_line2.$BASHPID.sig

declare -A BACKUP_SIGNAL_ACTIONS=()

function disable_signals() { for sig; do BACKUP_SIGNAL_ACTIONS[$sig]=$(trap -p $sig); trap "echo $sig >> $SIGNAL_QUEUE_FILE; log_info 'Received signal $sig'" $sig; done; }
function restore_signals() { for sig; do eval "${BACKUP_SIGNAL_ACTIONS[$sig]:-"trap - $sig"}"; unset "BACKUP_SIGNAL_ACTIONS[$sig]"; done; }

function trap_kill_group(){
    local terminate=${1:-'false'} code=${2:-'1'};
    trap \
        "trap - SIGINT SIGTERM EXIT; [ $terminate == true ] && kill -s SIGTERM -- -$$; [ -n \"\$(jobs -p)\" ] && kill -s SIGTERM \$(jobs -p) 2>/dev/null" \
        SIGINT SIGTERM EXIT;
}
function trap_restore_kill_group(){ trap - SIGINT SIGTERM EXIT; }

function wait_pids_patiently()
{
    local initial_interval=$1 pids=( $2 ) names=( $3 )
    local N=${#pids[@]}

    if [ ${#pids[@]} -gt 1 ]; then
        log_debug "Will wait for ${#pids[*]} pids ${pids[*]}, each named ${names[*]}"
    else
        log_debug "Will wait for pid ${pids[*]} named ${names[*]}"
    fi

    local interval=$initial_interval last=$(timestamp_ms) last_remaining=""
    while true; do
        sleep 0.2
        local i=0 remaining=""
        while (( i < N )); do
            local pid=${pids[i]}
            if [ -e /proc/$pid ]; then
                remaining+="${names[i]}($pid) ";
            else
                if ! wait $pid; then return 1; fi
            fi
            ((++i));
        done
        if [ -z "$remaining" ]; then break; fi

        if (($(timestamp_ms) - last > interval * 1000)); then
            log_debug "Still waiting for $(echo $remaining | wc -w) PIDs: $remaining";
            if [ "$remaining" == "$last_remaining" ]; then
                ((interval+=3));
            else
                ((interval=initial_interval));
            fi
            last=$(timestamp_ms) last_remaining=$remaining
        fi
    done
}

# ClickHouse Error Codes
CHEC_INCORRECT_NUMBER_OF_COLUMNS=7
CHEC_SIZES_OF_COLUMNS_DOESNT_MATCH=9
CHEC_NOT_FOUND_COLUMN_IN_BLOCK=10
CHEC_NO_SUCH_COLUMN_IN_TABLE=16
CHEC_BAD_ARGUMENTS=36
CHEC_SYNTAX_ERROR=62
CHEC_QUOTA_EXCEEDED=201
CHEC_TOO_MANY_SIMULTANEOUS_QUERIES=202
CHEC_MEMORY_LIMIT_EXCEEDED=241
CHEC_TOO_MANY_PARTS=252
CHEC_TABLE_SIZE_EXCEEDS_MAX_DROP_SIZE_LIMIT=359
CHEC_QUERY_WAS_CANCELLED=394
CHEC_KEEPER_EXCEPTION=999
CHEC_UNKNOWN_EXCEPTION=1002

# Error code handling actions
declare -A ECH_MODES=(
    [0]=finish
    [UNKNOWN]=terminate # Not an exception code
    [$CHEC_INCORRECT_NUMBER_OF_COLUMNS]=terminate
    [$CHEC_SIZES_OF_COLUMNS_DOESNT_MATCH]=terminate
    [$CHEC_NOT_FOUND_COLUMN_IN_BLOCK]=terminate
    [$CHEC_NO_SUCH_COLUMN_IN_TABLE]=terminate
    [$CHEC_BAD_ARGUMENTS]=terminate
    [$CHEC_SYNTAX_ERROR]=terminate
    [$CHEC_QUOTA_EXCEEDED]=infinite_retry
    [$CHEC_TOO_MANY_SIMULTANEOUS_QUERIES]=infinite_retry
    [$CHEC_MEMORY_LIMIT_EXCEEDED]=retry
    [$CHEC_TOO_MANY_PARTS]=infinite_retry
    [$CHEC_TABLE_SIZE_EXCEEDS_MAX_DROP_SIZE_LIMIT]='F create_force_drop_flag'
    [$CHEC_KEEPER_EXCEPTION]=infinite_retry
    [$CHEC_UNKNOWN_EXCEPTION]=terminate
)

declare -A BACKUP_ECH_MODES=()

function restore_ech_modes() {
    for code in ${!BACKUP_ECH_MODES[@]}; do
        ECH_MODES[$code]=${BACKUP_ECH_MODES[$code]}
        log_debug "Reset error code handling mode $code: '${ECH_MODES[$code]}'."
    done
    BACKUP_ECH_MODES=();
}

declare BACKUP_DSH=''

function restore_dsh() { if [ -n "$BACKUP_DSH" ]; then DSH=$BACKUP_DSH; fi; BACKUP_DSH=''; }

# Error Code Handling Modes
#   ech_spec := '--' 'CODE' <code> <ech_mode> [callee] [ ',' 'CODE' <code> <ech_mode> [callee]]...
#   ech_mode := 'infinite_retry'|'always_retry'|'retry'|'ignore'|'finish'|'ok'|'exit'|'terminate'|'call'
#   callee := '<function_name>' | '<script_file>'
# 
# Scoping
#   1. ^ <any query> <ech_spec> $
#      The ECH spec is scoped to a single query
#   2. ^ <ech_spec> $
#      Stay effective for following lines
# 
# ECH Callee Definition
#   Function naming:  function ECH_<custom_function_name>()
#   Arguments:        $1:code $2:query
#   Returns:
#     0: The error code is handled. No query retry needed.
#     1: Can not handle the error code, or another error occured.
#     2: The error code is handled. Query should be retried.
function apply_ech_modes()
{
    local mode_names="infinite_retry|always_retry|retry|ignore|finish|ok|exit|terminate|call"
    local code mode maybe_ech_spec=$1

    local regex="-- *CODE (.*)"
    if [[ "$maybe_ech_spec" =~ $regex ]]; then maybe_ech_spec="CODE ${BASH_REMATCH[1]}"; else return 0; fi

    regex="^CODE +([0-9*,-]+) +($mode_names)( *,? *)(.*)$"

    log_debug "May be ECH spec: '$maybe_ech_spec'"

    local rest # rest of text
    while [[ "$maybe_ech_spec" =~ $regex ]]; do

        code=${BASH_REMATCH[1]} mode=${BASH_REMATCH[2]} rest=${BASH_REMATCH[4]}

        if [ $mode == call ]; then # CODE 123 call 'some_predefined_func', CODE 456 call "/some/script.sh"
            func_callee_regex="^([a-zA-Z_][0-9a-zA-Z_]+)( *,? *)(.*)"
            script_callee_regex="^('[^']+'|\"[^\"]+\"|[^ ]+)( *,? *)(.*)"
            if [[ $rest =~ $func_callee_regex ]]; then
                ECH_MODES[$code]="F ${BASH_REMATCH[1]}"
                log_debug "Set error code handling call $code: function ${ECH_MODES[$code]:2}."
            elif [[ $rest =~ $script_callee_regex ]]; then
                ECH_MODES[$code]="S ${BASH_REMATCH[1]}"
                log_debug "Set error code handling call $code: script file '${ECH_MODES[$code]:2}'."
            else
                log_debug "Error: Invalid ECH spec, expected a file path: $rest"
                return 1 
            fi
            rest=${BASH_REMATCH[3]}
        else
            if [[ $code =~ ^[0-9]+$ ]]; then # CODE 123
                BACKUP_ECH_MODES[$code]=${ECH_MODES[$code]}
                ECH_MODES[$code]=$mode
                log_debug "Set error code handling mode $code: '${ECH_MODES[$code]}'."
            elif [[ $code =~ ^[0-9]+-[0-9]+ ]]; then # CODE 23-26
                local code_start code_end
                IFS=- read code_start code_end <<<"$code"
                for code in $(seq $code_start 1 $code_end); do
                    BACKUP_ECH_MODES[$code]=${ECH_MODES[$code]}
                    ECH_MODES[$code]=$mode
                done
                log_debug "Set error handling mode to '${ECH_MODES[$code]}' for code $code_start to $code_end."
            elif [[ $code =~ , ]]; then # CODE 23,26
                for code in ${code//,/ }; do
                    BACKUP_ECH_MODES[$code]=${ECH_MODES[$code]}
                    ECH_MODES[$code]=$mode
                    log_debug "Set error code handling mode $code: '${ECH_MODES[$code]}'."
                done
            elif [[ $code == '*' ]]; then # CODE *
                for code in $(seq 1 1 1002); do
                    BACKUP_ECH_MODES[$code]=${ECH_MODES[$code]}
                    ECH_MODES[$code]=$mode
                done
                log_debug "Set error handling mode to '${ECH_MODES[$code]}' for code 1 to 1002."
            else
                log_error "Error: Invalid error code spec: $code."
                return 1
            fi
        fi
        maybe_ech_spec=$rest
    done
    # Unclean finish
    if [ -n "$maybe_ech_spec" ]; then
        log_error "Error: Invalid ECH spec: $rest"
        return 1
    fi
}

# Dirty State Handling
#   dsh_spec := '--' 'DIRTY' call [callee]
#   callee := '<function_name>'
# 
# Scoping
#   1. ^ <any query> <dsh_spec> $
#      The DSH spec is scoped to a single query
#   2. ^ <dsh_spec> $
#      Stay effective for following lines
# 
# DSH Callee Definition
#   Function naming:  function DSH_<custom_function_name>()
#   Arguments:        $1:query
#   Returns:
#     0: The dirty state is cleared. No query retry needed.
#     1: Can not handle the dirty state, or another error occured.
#     2: The dirty state is handled. Query should be retried.
function apply_dsh()
{
    local maybe_dsh_spec=$1 callee=''

    local regex="-- *DIRTY call (.*)"
    if [[ "$maybe_dsh_spec" =~ $regex ]]; then callee="${BASH_REMATCH[1]}"; else return 0; fi

    log_debug "May be DSH spec: '$maybe_dsh_spec'"

    local func_callee_regex="^([a-zA-Z_][0-9a-zA-Z_]+)"
    if [[ $callee =~ $func_callee_regex ]]; then
        DSH=${BASH_REMATCH[1]}
        log_debug "Set dirty state handler to function '$DSH'"
    else
        log_debug "Error: Invalid DSH spec, expected a function name: '$callee'"
        return 1 
    fi
}

# ECH callee insert_select_delete_where
function ECH_insert_select_delete_where()
{
    local code=$1 query=$2 # INSERT INTO {{dst_table}} SELECT * FROM {{src_table}} WHERE toStartOfInterval({{datetime_column}},INTERVAL {{interval}})='...'
    local regex="INSERT INTO ([a-zA-Z0-9_.\`]+)[ \(]*.*SELECT .+ FROM .+ WHERE (.+);.*$"
    if [[ "$query" =~ $regex ]]; then
        local table=${BASH_REMATCH[1]} condition=${BASH_REMATCH[2]}
        if [[ "$condition" =~ ^(.+)('SETTINGS '.+)$ ]]; then
            condition=${BASH_REMATCH[1]}
        fi
        (
            set -e;
            apply_ech_modes "-- CODE 0 ok, CODE $CHEC_SYNTAX_ERROR terminate"
            # Kill insert queries working on the condition
            do_query_with_error_code_handling "KILL QUERY WHERE query LIKE ${Q}INSERT INTO $table% WHERE $condition%${Q} SYNC"

            local query="ALTER TABLE $table DELETE WHERE $condition";

            local partition_by
            partition_by=$(kube_chc_query "SHOW CREATE TABLE $table FORMAT TSVRaw" | grep '^PARTITION BY');

            if [ -n "$partition_by" ]; then # has partition key
                local partitions
                partitions=$(kube_chc_query "SELECT DISTINCT _partition_value FROM $table WHERE $condition ORDER BY _partition_value FORMAT TSVRaw")
                if [ -z "$partitions" ]; then
                    query="";
                    log_debug "[ECH_insert_select_delete_where] No partitions found matching condition \"$condition\". Nothing to delete."
                elif [ $(echo "$partitions" | wc -l) -le 100 ]; then
                    local commands=$(sed -r "s|^.+$|    DELETE IN PARTITION & WHERE $condition,|g" <<<"$partitions")
                    query=$(echo -e "ALTER TABLE $table\n${commands%,}")
                    log_debug "[ECH_insert_select_delete_where] Will delete only in partitions ${partitions//$'\n'/ }."
                else
                    log_debug "[ECH_insert_select_delete_where] Too many partitions found matching condition \"$condition\", will delete without partition condition"
                fi
            fi
            if [ -n "$query" ]; then
                set_chc_params --alter_sync=2 --mutations_sync=2
                do_query_with_error_code_handling "$query" # Possible recursion ?
            fi
        )
        if [ $? != 0 ]; then return 1; fi
        return 2;
    else
        return 1 # Unhandled
    fi
}

# DSH callee insert_select_delete_where
function DSH_insert_select_delete_where() { ECH_insert_select_delete_where "$@"; }

function create_or_delete_flag_file()
{(
    set -e;
    local create=$1 file=$2 pids='';
    for pod in ${SERVER_PODS[@]}; do
        if [ "$create" == true ]; then
            $KUBECTL exec $pod -- touch /var/lib/clickhouse/flags/$file &
        else
            $KUBECTL exec $pod -- rm -rf /var/lib/clickhouse/flags/$file &
        fi
        pids+=" $!"
    done
    for pid in $pids; do wait $pid; done
)}

# ECH callee create_force_drop_flag
function ECH_create_force_drop_flag() { create_or_delete_flag_file true force_drop_table; return 2; }
# ECH callee delete_force_drop_flag
function ECH_delete_force_drop_flag() { create_or_delete_flag_file false force_drop_table; return 0; }


function generate()
{
    local generator_queries_file=$1
    log_info "Generating queries to run with '$generator_queries_file', into '$QUERIES_FILE'..."
    kube_chc_query "$(cat $generator_queries_file)" --format TSVRaw > $QUERIES_FILE
    local ret=$?
    if ((ret != 0)); then rm_if_empty $QUERIES_FILE; exit $ret; fi
    log_info "Got $(cat $QUERIES_FILE | wc -l) queries."
    QUERIES_FILE_SHA=$(sha1sum "$QUERIES_FILE" | awk '{print$1}')
}

# dst_table,src_table,datetime_column="toDateTime(recordTimestamp,'Asian/Shanghai')",interval
declare -A PARSE_ASSIGNMENTS_RESULT

parse_assignments() {
    local input=$1
    local key value rest
    log_debug "[parse_assignments] Got user assignments: $input"

    # Split input string by ',' that are not inside quotes
    local regex="([^,=]+)=('[^']+'|\"[^\"]+\"|[^,]+)(,|\$)(.*)"
    while [[ $input =~ $regex ]]; do
        key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]} rest=${BASH_REMATCH[4]}

        value=${value%\"}
        value=${value#\"}

        log_debug "[parse_assignments] $key = \"$value\""
        PARSE_ASSIGNMENTS_RESULT[$key]=$value
        input=$rest
    done
}

# Substitute assigned arguments from PARSE_ASSIGNMENTS_RESULT
function substitute_args()
{
    local text=$1
    for key in ${!PARSE_ASSIGNMENTS_RESULT[@]}; do
        local value=${PARSE_ASSIGNMENTS_RESULT[$key]}
        text=$(sed -re "s|\\{\\{$key\\}\\}|$value|g" <<<"$text")
    done
    echo "$text"
}

function substitute_vars()
{
    local text=$1
    text=$(sed -re "s|<<RANDOM>>|$(date +'%s.%6N')-$RANDOM|g" <<<"$text")
    echo "$text"
}

function gather_template_args()
{
    local text=$1
    local arg_names=$(grep -Po "\{\{[a-zA-Z0-9_]+\}\}" <<<"$text" | tr -d '{}')
    local template_arg_names=""
    for name in $arg_names; do
        if [[ ! " $template_arg_names " =~ " $name " ]]; then template_arg_names+=" $name"; fi
    done
    echo $template_arg_names
}

declare -gx Q='$$'; # HereDoc separator

# Templated generators
declare -A templates=(
    [insert_select_by_timeslot]="
    SELECT '-- DIRTY call insert_select_delete_where' AS query
    UNION ALL
    SELECT '-- CODE $CHEC_MEMORY_LIMIT_EXCEEDED call insert_select_delete_where' AS query
    UNION ALL
    SELECT
        concat(
            ${Q}INSERT INTO {{dst_table}} SELECT * FROM {{src_table}} WHERE toStartOfInterval({{datetime_column}},INTERVAL {{interval}})='${Q},
            toString(toStartOfInterval({{datetime_column}},INTERVAL {{interval}}) AS timeSlot),
            ${Q}' SETTINGS insert_deduplicate=0,insert_deduplication_token='<<RANDOM>>'; -- COUNT ${Q},
            toString(count())
        ) AS query
    FROM {{src_table}}
    GROUP BY timeSlot
    ORDER BY timeSlot {{direction}}"

    [insert_select_with_columns_by_timeslot]="
    SELECT '-- DIRTY call insert_select_delete_where' AS query
    UNION ALL
    SELECT '-- CODE $CHEC_MEMORY_LIMIT_EXCEEDED call insert_select_delete_where' AS query
    UNION ALL
    WITH (
        SELECT
            arrayStringConcat(groupArray(name) AS names,','),
            throwIf(length(names)==0, 'No common column names between {{src_table}} and {{dst_table}}')
        FROM (
            SELECT database,table,name,default_kind FROM system.columns WHERE database||'.'||table=replaceRegexpAll('{{src_table}}','\`','') AND default_kind NOT IN ('EPHEMERAL')
        ) AS src INNER JOIN (
            SELECT database,table,name,default_kind FROM system.columns WHERE database||'.'||table=replaceRegexpAll('{{dst_table}}','\`','') AND default_kind NOT IN ('ALIAS','MATERIALIZED','EPHEMERAL')
        ) AS dst USING (name)
    ) AS columns_str
    SELECT
        concat(
            ${Q}INSERT INTO {{dst_table}}(${Q}, columns_str.1,
            ${Q}) SELECT ${Q},
            columns_str.1,
            ${Q} FROM {{src_table}} WHERE toStartOfInterval({{datetime_column}},INTERVAL {{interval}})='${Q},
            toString(toStartOfInterval({{datetime_column}},INTERVAL {{interval}}) AS timeSlot),
            ${Q}' SETTINGS insert_deduplicate=0,insert_deduplication_token='<<RANDOM>>'; -- COUNT ${Q},
            toString(count())
        ) AS query
    FROM {{src_table}}
    GROUP BY timeSlot
    ORDER BY timeSlot {{direction}}"

    [drop_partition]="
    SELECT * FROM
    (
        WITH
            (SELECT partition_key!='' FROM system.tables WHERE database='{{db}}' AND table='{{table}}') AS has_partition_key,
            splitByChar(',', replace(if(position(partition,'(')==1, substr(partition,2,-1), partition),'\'','')) AS _partition_values,
            rowNumberInAllBlocks() DIV {{batch}} AS blockNumber,
            arrayStringConcat(groupArray('DROP PARTITION ID \''||partition_id||'\''),',') AS commands_str,
            arrayStringConcat(groupArray(partition), ',') AS partitions_str
        SELECT concat('ALTER TABLE \`',database,'\`.\`',table,'\` ',commands_str,
                ' SETTINGS alter_sync=2,mutations_sync=2',' -- Partitions ', partitions_str) AS query
        FROM
        (
            SELECT DISTINCT database,table,partition,partition_id
            FROM system.parts
            WHERE has_partition_key AND active AND database='{{db}}' AND table='{{table}}' AND {{conditions}}
            ORDER BY database,table,partition
        )
        GROUP BY database,table,blockNumber
        UNION ALL
        SELECT 'SELECT 1 -- CODE 0 call delete_force_drop_flag'
    ) ORDER BY query"

    [drop_partition_on_cluster]="
    SELECT * FROM
    (
        WITH
            (SELECT partition_key!='' FROM system.tables WHERE database='{{db}}' AND table='{{table}}') AS has_partition_key,
            splitByChar(',', replace(if(position(partition,'(')==1, substr(partition,2,-1), partition),'\'','')) AS _partition_values,
            rowNumberInAllBlocks() DIV {{batch}} AS blockNumber,
            arrayStringConcat(groupArray('DROP PARTITION ID \''||partition_id||'\''),',') AS commands_str,
            arrayStringConcat(groupArray(partition), ',') AS partitions_str
        SELECT concat('ALTER TABLE \`',database,'\`.\`',table,'\`',${Q} ON CLUSTER '{cluster}' ${Q},commands_str,
                ' SETTINGS alter_sync=2,mutations_sync=2,distributed_ddl_task_timeout=7200',' -- Partitions ', partitions_str) AS query
        FROM
        (
            SELECT DISTINCT database,table,partition,partition_id
            FROM clusterAllReplicas('{cluster}',system.parts)
            WHERE has_partition_key AND active AND database='{{db}}' AND table='{{table}}' AND {{conditions}}
            ORDER BY database,table,partition
        )
        GROUP BY database,table,blockNumber
        UNION ALL
        SELECT 'SELECT 1 -- CODE 0 call delete_force_drop_flag'
    ) ORDER BY query"
)

function generate_from_template()
{
    declare -A templates_arg_names=()
    for template_name in ${!templates[@]}; do
        templates_arg_names[$template_name]=$(gather_template_args "${templates[$template_name]}")
    done

    local action=$1 name=$2; shift 2

    local regex="gen|templates|args|preview"
    if ! [[ "$action" =~ $regex ]]; then echo "Valid actions: $regex."; exit 1; fi

    if [ $action == templates ]; then
        if [ -z "$name" ]; then
            for template_name in ${!templates[@]}; do
                echo
                echo "$template_name:"
                echo -e "\e[2m${templates[$template_name]}\e[0m"
            done
        else
            echo "$name:"
            echo -e "\e[2m${templates[$name]}\e[0m"
        fi
        exit 0;
    fi
    if [ $action == args ]; then
        if [ -z "$name" ]; then
            for template_name in ${!templates[@]}; do
                echo
                echo "$template_name:"
                echo -n "    "; echo ${templates_arg_names[$template_name]} | tr ' ' ','
            done
        else
            echo "$name:"
            echo -n "    "; echo ${templates_arg_names[$name]} | tr ' ' ','
        fi
        exit 0;
    fi
    # if [ $action == gen ]; then ... fi
    if [ -z "$name" ]; then echo "Empty name passed to generator."; exit 1; fi
    if [ -z "${templates[$name]}" ]; then echo "No such template: '$name', known template names are: ${!templates_arg_names[@]}."; exit 1; fi

    required_num_args=$(echo ${templates_arg_names[$name]} | wc -w)

    # dst_table,src_table,datetime_column="toDateTime(recordTimestamp,'Asian/Shanghai')",interval
    local args=$1
    if [ $(echo "$args" | tr -d ' ' | tr '=' ' ' | wc -w) -lt $((required_num_args+1)) ]; then
        echo -n "Not enough arguments passed to template '$name', required: "
        echo ${templates_arg_names[$name]} | tr ' ' ','
        exit 1
    fi
    parse_assignments "$args"
    # for key in ${!PARSE_ASSIGNMENTS_RESULT[@]}; do
    #     echo "$key = |${PARSE_ASSIGNMENTS_RESULT[$key]}|"
    # done
    local templated=$(substitute_args "${templates[$name]}")

    local generator_queries_file=$(mktmp)

    local unassigned_args=$(gather_template_args "$templated")
    if [ -n "$unassigned_args" ]; then
        log_info "Partially templated generator query: \e[2m$templated\e[0m"
        log_info "Error. Some template arguments are not assigned: $unassigned_args"
        exit 1
    fi

    log_trace "Templated generator query: \e[2m$templated\e[0m"

    echo "$templated" > $generator_queries_file

    generate $generator_queries_file; rm -rf $generator_queries_file

    log_info "Wrote $QUERIES_FILE"

    if [ $action == preview ]; then exit 0; fi
}

# Query exception code
declare EXCEPTION_CODE=0

function grep_exception_code() { sed -nr 's|^Code: ([0-9]+)\. DB::.+|\1|p; s|^std::exception. Code: ([0-9]+)[^0-9].+|\1|p'; }

# Space characters in arguments are not supported.
function kube_ch()
{
    local pod=$1 cmd=$2 query=$3; shift 3
    local cmd_str="$KUBECTL exec -i $pod -- $cmd $* --query $query"
    if [ -n "$DRY_RUN" ]; then log_trace "Executing (dry run): $cmd_str"; return 0; else log_trace "Executing: $cmd_str"; fi

    EXCEPTION_CODE=0

    local pod_color=$(get_color $pod)
    local stderr_file=$(mktmp)
    local exit_code_file=$(mktmp)

    (
        set +e -o pipefail;
        $KUBECTL exec -i $pod -- bash -c "f=\$(mktemp);while [ -f \$f ];do sleep 0.02;((++i % 1000 == 0))&&echo -n ~@~@~@~HEARTBEAT~@~@~@~;done& $cmd $*;r=\$?;rm -f \$f 2>/dev/null;wait;exit \$r" 2>$stderr_file <<<"$query" | sed 's/~@~@~@~HEARTBEAT~@~@~@~//g';
        echo $? > $exit_code_file
    )

    local ret=$(cat $exit_code_file)
    if [ $ret != 0 ]; then
        EXCEPTION_CODE=$(cat $stderr_file | tee >(log_prefix "[$pod_color$pod$RST]" >&2) | grep_exception_code | head -1)
    elif [ $(stat -c %s $stderr_file) != 0 ]; then
        ret=1;
        log_error "Uncaught error with zero exit code but non-empty stderr content:\n$(cat $stderr_file)"
    fi
    log_debug "Exception code: $EXCEPTION_CODE, return: $ret."
    rm -f $stderr_file $exit_code_file
    return $ret
}

function kube_chc_query() { kube_ch ${SERVER_PODS[0]} clickhouse-client "$@" "${CHC_FLAGS[@]}"; }

function kube_chc_query_all()
{
    local query=$1; shift
    local cmd_str="clickhouse-client ${CHC_FLAGS[*]} $* --query $query"
    if [ -n "$DRY_RUN" ]; then log_trace "Executing (dry run) in all PODs: $cmd_str"; return 0; else log_trace "Executing in all PODs: $cmd_str"; fi

    EXCEPTION_CODE=0

    local -A stderr_files=()
    local -a pids=()

    trap_kill_group;
    for pod in ${SERVER_PODS[@]}; do
        stderr_files[$pod]=$(mktmp)
        if [ ${LOG_PREFIX:-false} == true ]; then
            local pod_color=$(get_color $pod)
            $KUBECTL exec -i $pod -- clickhouse-client "${CHC_FLAGS[@]}" "$@" 2>${stderr_files[$pod]} <<<"$query" | log_prefix "[$pod_color$pod$RST]" &
        else
            $KUBECTL exec -i $pod -- clickhouse-client "${CHC_FLAGS[@]}" "$@" 2>${stderr_files[$pod]} <<<"$query" &
        fi
        pids+=" $!"
    done
    if ! wait_pids_patiently 10 "$pids" "${SERVER_PODS[*]}"; then return 1; fi
    trap_restore_kill_group;

    # Messy error outputs
    local stderr_size=0
    for f in ${stderr_files[@]}; do stderr_size=$((stderr_size + $(stat -c %s $f) )); done

    if (( stderr_size > 0 )); then
        for pod in ${!stderr_files[@]}; do
            local pod_color=$(get_color $pod)
            local exception_code=$(cat ${stderr_files[$pod]} | tee >(log_error_prefix "[$pod_color$pod$RST]") | grep_exception_code | head -1)
            if ((EXCEPTION_CODE == 0 && exception_code != 0)); then EXCEPTION_CODE=$exception_code; fi
        done
    fi
    rm -rf ${stderr_files[*]};
    if [ $EXCEPTION_CODE != 0 ]; then
        log_debug "Exception code: $EXCEPTION_CODE, return 1"
        return 1
    fi
}

SERVER_PODS=()
KUBECTL=${KUBECTL:-kubectl}
CLICKHOUSE_SERVER_POD_LABEL='clickhouse.altinity.com/chi'

function get_server_pods()
{
    if ! command -v kubectl >/dev/null; then
        log_error "Command 'kubectl' not found."
        return 1;
    fi

    local ns=$1
    if [ -n "$ns" ]; then
        if ! $KUBECTL get ns "$ns" >/dev/null; then
            log_error "Cannot find namespace $ns."
            return 1;
        fi
        KUBECTL="$KUBECTL -n $ns";
    fi
    SERVER_PODS=( $($KUBECTL get pods -l $CLICKHOUSE_SERVER_POD_LABEL -oname | cut -d/ -f2) )

    if ((${#SERVER_PODS[@]} == 0)); then
        log_error "Cannot find any ClickHouse server PODs in namespace $ns."
        return 1;
    fi
    # Verify these are actually ClickHouse PODs
    local res=$(kube_chc_query_all "SELECT 1") regex="^1{${#SERVER_PODS[@]}}\$"
    if ! [[ "$(echo "$res" | tr -d '\n')" =~ $regex ]]; then
        log_error "All PODs should be healthy ClickHouse server, but some are not responding to query 'SELECT 1'. Results: \n$res"
        return 1;
    fi
    log_debug "Server PODs: ${SERVER_PODS[*]}"
}

declare cumulative_memory_errors=0 # State variable of do_query_with_error_code_handling()

# Arguments
#   (1) $1:query
#       Run the `query` with error code (exception code) handled as specifed by ECH specs.
#       See function apply_ech_modes().
#   (2) $1:queries_file $2:line_number $3:query
#       Run the `query` with error code (exception code) handled, checking possible cancel points between query retries.
#       See function check_cancel_point().
# Returns
#   0: Query succeeded
#   1: Error code unhandled
#   2: Ignored on error
function do_query_with_error_code_handling()
{
    # set -x
    local queries_file n query
    local retry=0 first_time=$(timestamp_ms)

    if (($# == 1)); then query=$1
    elif (($# == 3)); then queries_file=$1 n=$2 query=$3
    else
        log_error "Wrong number of arguments."
        return 1
    fi

    while true; do
        if [ -n "$queries_file" ]; then
            # A bit dirty, but logging the line number during infinite query retry can be helpful.
            local retry_hint=""; ((retry > 0)) && retry_hint="(Retry $retry) "
            log_info "${retry_hint}At $queries_file:$n"
        fi

        kube_chc_query "$query"

        # Messy error handling
        local code=${EXCEPTION_CODE:-'UNKNOWN'}
        local mode=${ECH_MODES[$code]}

        if [[ $mode =~ finish|ok ]]; then return 0; fi
        if [[ $mode =~ exit|terminate ]]; then log_error "Query exception code $code, will terminate."; return 1; fi

        if ((retry > 0 && CLICKHOUSE_RETRY_TIMEOUT > 0 && $(timestamp_ms) - first_time > CLICKHOUSE_RETRY_TIMEOUT * 1000)); then
            log_error "Query exception code $code. Timeout exceeded retrying for the query, will terminate";
            return 1
        fi

        if [ -z "$mode" ]; then
            log_error "Query exception code $code. Can not handle the error code, will terminate."
            return 1
        elif [[ $mode == ignore ]]; then
            # If we chose to ignore memory errors, still exit after some cumulative memory errors.
            if ((code == CHEC_MEMORY_LIMIT_EXCEEDED)); then
                if ((CLICKHOUSE_MAX_CUMULATIVE_MEMORY_ERRORS > 0 && ++cumulative_memory_errors > CLICKHOUSE_MAX_CUMULATIVE_MEMORY_ERRORS)); then
                    log_error "Exceeding limit CLICKHOUSE_MAX_CUMULATIVE_MEMORY_ERRORS($CLICKHOUSE_MAX_CUMULATIVE_MEMORY_ERRORS), will terminate."
                    return 1
                fi
            fi
            return 2;
        elif [[ $mode =~ infinite_retry|always_retry ]]; then
            log_error "Query exception code $code. Will retry (infinitely) after $CLICKHOUSE_RETRY_INTERVAL sec...";
            sleep $CLICKHOUSE_RETRY_INTERVAL
        elif [[ $mode == retry ]]; then
            if ((retry < CLICKHOUSE_RETRIES)); then
                log_error "Query exception code $code. Retrying ($((CLICKHOUSE_RETRIES - retry)) times left) in $CLICKHOUSE_RETRY_INTERVAL second(s).";
                sleep $CLICKHOUSE_RETRY_INTERVAL
            else
                log_error "Reached max retry attempts, will terminate."
                return 1
            fi
        elif [[ $mode =~ ^('F '|'S ') ]]; then
            local ech_callee=${mode:2}
            if [[ $mode =~ ^F ]]; then
                if ! (declare -F | grep -qw ECH_${ech_callee}); then log_error "ECH function is not defined: ${ech_callee}"; return 1; fi
                log_warn "Code $code, calling ECH function $ech_callee";
                ECH_${ech_callee} $code "$query";
            elif [[ $mode =~ ^S ]]; then
                if ! [ -x "$ech_callee" ]; then log_error "File does not exist or is not executable: $ech_callee"; return 1; fi
                log_warn "Code $code, calling ECH script $ech_callee";
                bash "$ech_callee" $code "$query";
            fi
            local calle_ret=$? # ECH Callee Definition - Returns
            if [ $calle_ret == 0 ]; then
                log_info "Error code $code handled by ECH callee $ech_callee";
                return 0; # Consider the query succeeded
            elif [ $calle_ret == 1 ]; then
                log_error "ECH callee $ech_callee returned non-zero code $calle_ret. The error code $code from query cannot be handled, will terminate.";
                return 1;
            elif [ $calle_ret == 2 ]; then
                log_info "Error code $code handled by ECH callee $ech_callee, retrying the query.";
            fi
        fi
        ((++retry));
    done
}

declare -a state_variables=(
    i # line number
    DIRTY # dirty state
    QUERIES_FILE_SHA # SHA-1 of queries file
    CLICKHOUSE_RETRIES
    CLICKHOUSE_RETRY_TIMEOUT
    CLICKHOUSE_RETRY_INTERVAL
    CLICKHOUSE_MAX_CUMULATIVE_MEMORY_ERRORS

    ## About command line
    KUBECTL # Can be set to like 'KUBECTL="kubectl --kubeconfig=/path/to/alternative/kube.conf"'
    CLICKHOUSE_POD SERVER_PODS CHC_FLAGS

    ## ECH, DSH
    ECH_MODES BACKUP_ECH_MODES
    DSH BACKUP_DSH
)

function variables_declaration() { for var; do declare -p $var 2>/dev/null | sed -r '1{ /^declare -[-aAfFgilrtux]*a/{ s|\[[0-9]+\]=||g }; s|^declare |declare -g |g}'; done; }

function load_state()
{
    if ! [ -f $STATE_FILE ]; then log_error "State file '$STATE_FILE' does not exist."; exit 1; fi
    {
        flock -x 10;
        unset ${state_variables[@]}
        source $STATE_FILE
        [ -f $STATE_FILE.override ] && source $STATE_FILE.override;
    } 10< $STATE_FILE
    log_info "load_state: i=${i} DIRTY=${DIRTY} QUERIES_FILE_SHA=${QUERIES_FILE_SHA}"
}

function store_state()
{
    if (($# != 2)); then log_error "Wrong number of arguments passed to store_state: $#, should be 2."; exit 1; fi
    {
        flock -x 10;
        disable_signals SIGINT SIGTERM SIGTSTP EXIT

        i=${1:-$i} DIRTY=${2:-$DIRTY}

        if [ -f $STATE_FILE.override ]; then
            if [ $(cat $STATE_FILE.override | wc -l) -gt 1024 ]; then
                log_error "Too many lines in '$STATE_FILE.override', refusing to include it."
                command mv $STATE_FILE.override $STATE_FILE.override.refused
            else
                source $STATE_FILE.override && rm -f $STATE_FILE.override;
            fi
        fi
        variables_declaration ${state_variables[@]} >&10
        restore_signals SIGINT SIGTERM SIGTSTP EXIT
    } 10> $STATE_FILE

    if [ -f $SIGNAL_QUEUE_FILE ]; then
        local signals=$(cat $SIGNAL_QUEUE_FILE; rm -f $SIGNAL_QUEUE_FILE)
        for sig in $signals; do kill -s $sig -- $$; done
    fi
}

declare -ga lines=();
declare -g  i=0  N=0  DIRTY=false;

function should_continue_on_state()
{
    if ! [ -f "$QUERIES_FILE" ]; then return 1; fi # false
    if ! [ -f "$STATE_FILE" ]; then return 1; fi # false
    if [ $(stat -c %Y $STATE_FILE) -lt $(stat -c %Y $QUERIES_FILE) ]; then
        log_error "State file '$STATE_FILE' is older than queries file '$QUERIES_FILE', this is unexpected. Will not proceed."
        exit 1;
    fi
    if [[ -e $STATE_FILE && $(stat -c %s $STATE_FILE) == 0 ]]; then
        log_error "State file '$STATE_FILE' is empty, this is unexpected. Will not proceed."
        exit 1;
    fi

    local sha sha_stored
    sha=$(sha1sum "$QUERIES_FILE" | awk '{print$1}')
    sha_stored=$(load_state; echo $QUERIES_FILE_SHA)

    if [ -z "$sha_stored" ]; then # State file exists but SHA-1 not recorded, which may be user's intention.
        QUERIES_FILE_SHA=$sha;
    else
        if [ $sha != $sha_stored ]; then
            log_error "SHA-1 sum of '$QUERIES_FILE' doesn't match that stored in state, will not proceed."
            exit 1;
        fi
    fi
    return 0;
}

function lock_file_100_or_exit()
{
    exec 100< $QUERIES_FILE # open

    local ret
    flock -E 249 -xn 100; ret=$?

    if [ $ret != 0 ]; then
        if [ $ret == 249 ]; then
            echo "Unable to lock queries file '$QUERIES_FILE', maybe another instance is running ?";
        fi
        exit 1;
    fi
}

function unlock_file_100(){ exec 100<&-; }

function func_defined() { declare -F "$1" >/dev/null; }

function execute_queries()
{
    local regex_empty_query='^\s*(--.*|/\*.*\*/)\s*$'
    i=${i:-'0'}; # new state

    while ((i < N)); do
        local line=${lines[i]}

        if [[ "$DIRTY" == true && -z "$DSH" ]]; then log_warn "State dirty, but DSH not specified."; fi
        if [[ "$DIRTY" == true && -n "$DSH" ]]; then # state dirty and DSH defined.
            if ! func_defined "DSH_$DSH"; then
                log_error "Dirty state handler '$DSH' not found, unable to proceed.";
                return 1;
            fi
            log_info "State dirty, calling DSH callee '$DSH'"
            local ret;
            DSH_$DSH 0 "$line"; ret=$?
            if [ $ret == 0 ]; then
                store_state '' false;
                log_info "Dirty state cleared by DSH callee '$DSH', no retry needed."
            elif [ $ret == 1 ]; then
                log_error "Can not clear the dirty state: DSH callee '$DSH' returned non-zero code $ret."
                return 1;
            elif [ $ret == 2 ]; then
                store_state '' false;
                log_info "Dirty state cleared by DSH callee '$DSH', will retry last query."
                continue
            fi
        else
            if ! apply_ech_modes "$line"; then return 1; fi
            apply_dsh "$line";

            if [[ "$line" =~ $regex_empty_query ]]; then
                BACKUP_ECH_MODES=(); BACKUP_DSH=''; # Clear it for global scoping
                store_state $((++i)) false;
                continue;
            fi
            store_state $i true;

            line=$(substitute_vars "$line")

            do_query_with_error_code_handling $QUERIES_FILE $i "$line"

            local ret=$?
            if ((ret == 1 )); then # error unhandled
                log_error "Query error unhandled."
                return 1;
            elif ((ret == 2)); then # Query ignored on error
                echo "$line" >> $ignore_file
                log_info "Query ignored on exit code $code. Please retry manually: $line"
            fi

            restore_ech_modes;
            restore_dsh;

            store_state $((++i)) false;
        fi
    done
}

function run()
{
    if ! [ -f "$QUERIES_FILE" ]; then log_error "File does not exist $QUERIES_FILE"; return 1; fi
    if [ -f $IGNORE_FILE ]; then log_error "File '$IGNORE_FILE' already exists, will not overwrite."; return 1; fi

    lock_file_100_or_exit;

    readarray -t lines < $QUERIES_FILE
    N=${#lines[@]}

    local ret
    execute_queries; ret=$?

    unlock_file_100;
    if [ $ret == 0 ]; then log_info "Done with '$QUERIES_FILE'."; fi
    return $ret;
}

function set_vars()
{
    local tmp=$(mktmp);
    set -- "${SET_VARS[@]}";
    while (($# > 0)); do
        if [[ "$1" =~ ^([a-zA-Z][a-zA-Z0-9_]+)'='.+$ ]]; then
            if ! [[ " ${state_variables[*]} " =~ " ${BASH_REMATCH[1]} " ]]; then
                log_error "Unknown state variable: ${BASH_REMATCH[1]}"
                return 1;
            fi
            echo "declare -gx $1" >> $tmp
        else
            log_error "Not an variable assignment: $1";
            return 1;
        fi
        shift
    done
    flock -x $STATE_FILE cat $tmp >> $STATE_FILE.override
    rm -rf $tmp;
}

declare -ga CHC_FLAGS=()

# Set '--name=value' flags for clickhouse-client
function set_chc_params()
{
    local override=${1:-'false'}; shift;
    local arg name value prefix regex='^([0-9]+[KMGTP])i?B?$';
    for arg; do
        if [[ ! "$arg" =~ ^- ]]; then log_error "[set_chc_params] Argument to pass to clickhouse-client should start with '-' or '--'."; exit 1; fi
        if [[ "$arg" =~ '=' ]]; then # has value
            name=${arg%%=*}; value=${arg#*=};
            [[ $value =~ $regex ]] && value=$(numfmt --from=iec --to=none ${BASH_REMATCH[1]}) || :;
            prefix="$name=";
            arg="$name=$value";
        else
            prefix="$arg";
        fi
        local i=$(
            i=0;
            for x in ${CHC_FLAGS[@]}; do if [[ "$x" =~ ^"$prefix" ]]; then echo $i; break; fi; ((++i)); done
        )
        if [ -n "$i" ]; then
            if [ "$override" == true ]; then
                unset "CHC_FLAGS[$i]";
            else
                continue;
            fi
        fi
        CHC_FLAGS=( "${CHC_FLAGS[@]}" "$arg" );
    done;
}

set_chc_params false --receive_timeout=3600 --lock_acquire_timeout=3600

function usage()
{
    echo -e "Usage:  $(basename $0)  <queries file>  [options]..."
    sed -n '/^# ARGUMENT BEGIN/,/^# ARGUMENT END/p' $0 | sed -re '/^#/d; /^ {8}[^#]/d'|awk -F'#' '{printf "%-24s %s\n",$1,$2}'
}

CLICKHOUSE_RETRIES=${CLICKHOUSE_RETRIES:-3}
CLICKHOUSE_RETRY_TIMEOUT=${CLICKHOUSE_RETRY_TIMEOUT:-7200}
CLICKHOUSE_RETRY_INTERVAL=${CLICKHOUSE_RETRY_INTERVAL:-10}
CLICKHOUSE_MAX_CUMULATIVE_MEMORY_ERRORS=${CLICKHOUSE_MAX_CUMULATIVE_MEMORY_ERRORS:-0}

SHOULD_CONTINUE_ON_STATE=false;

while [ $# != 0 ] ; do case $1 in
# ARGUMENT BEGIN
    --pod) # ClickHouse server POD
        CLICKHOUSE_POD=$2
        SERVER_PODS=("$2")
        if ! $KUBECTL get pod $CLICKHOUSE_POD >/dev/null; then log_error "POD not found: $CLICKHOUSE_POD"; exit 1; fi
        shift 2;;
    -f|--file) # File containing one-line queries to execute.
        # See also --generator and --templated-generator options.
        QUERIES_FILE=$2;
        STATE_FILE="$QUERIES_FILE.state"
        IGNORE_FILE="$QUERIES_FILE.ignore"
        if should_continue_on_state; then load_state; SHOULD_CONTINUE_ON_STATE=true; fi
        shift 2;;
    --set)
        shift;
        SET_VARS=( "$@" ); set --;
        set_vars;
        break;;
    --insert-select-threads) # Max threads for INSERT SELECT query.
        # This sets ClickHouse setting `max_insert_threads` and `max_threads` to a same value.
        if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then log_error "Value of --insert_select_threads should be a positive integer. Got '$2'"; exit 1; fi
        set_chc_params true --max_threads=$2 --max_insert_threads=$2;
        shift 2;;
    --threads) # Set all `thread` related settings to the same value.
        # `max_threads`, `max_insert_threads`, `max_threads_for_indexes`, `max_final_threads`, `max_download_threads`, `backup_threads`, `restore_threads`, `async_insert_threads`.
        if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then log_error "Value of --threads should be a positive integer. Got '$2'"; exit 1; fi
        set_chc_params true --max_threads=$2 --max_insert_threads=$2 --max_threads_for_indexes=$2 --max_final_threads=$2 \
            --max_download_threads=$2 --backup_threads=$2 --restore_threads=$2 --async_insert_threads=$2;
        shift 2;;
    --chc) # A single string containing flags to pass to clickhouse-client.
        # Flags with value should be directly connected by '=' sign.
        # e.g. --chc "--echo -n --max_threads=4".
        # Can be specified multiple times.
        set_chc_params true $2;
        shift 2;;
    --retry) # Max times to retry for a failed query, if it's retryable.
        # Some kind of errors may be retried more times than specified by this parameter. For example
        # when encountering TOO_MANY_PARTS, the query will be retried almost infinitely.
        # For MEMORY_LIMIT_EXCEEDED, also check the parameter `--max_cumulative_memory_errors`.
        CLICKHOUSE_RETRIES=$2;
        shift 2;;
    --retry-timeout) # Max time spent on doing the same retries, to break infinity retry loop (it's possible).
        CLICKHOUSE_RETRY_TIMEOUT=$2;
        shift 2;;
    --retry-interval) # Retry interval
        CLICKHOUSE_RETRY_INTERVAL=$2;
        shift 2;;
    --max-cumulative-memory-errors) # During consecutive query retries, if MEMORY_LIMIT_EXCEEDED
        # keeps occuring, that indicates server memory usage too high, we shall stop. Also for INSERT queries,
        # encountering error MEMORY_LIMIT_EXCEEDED means some partial data being inserted, so to avoid repeatedly
        # inserting dirty partial data, we shall stop for manual check and cleanup.
        CLICKHOUSE_MAX_CUMULATIVE_MEMORY_ERRORS=$2;
        shift 2;;
    --ech) # Error code handling specification.
        # For example: --ech '* infinite_retry' --ech '36 exit'
        # Can be used multiple times.
        apply_ech_modes "-- CODE $2";
        shift 2;;
    --dsh) # Dirty state handling function.
        # For example: --dsh func_xyz
        apply_dsh "-- DIRTY call $2";
        shift 2;;
    --log-level) # Also write logs to the specified file.
        LOG_LEVEL=$2;
        if [ -z "${LOG_LEVELS[$LOG_LEVEL]}" ]; then echo "Unknown log level $LOG_LEVEL, should be one of ${!LOG_LEVELS[@]}"; exit 1; fi
        shift 2;;
    -h|--help) # This help text.
        usage;
        exit 0;;
    -g|--gen|--generator) # Generate queries to run by another query (or queries) from the specified file.
        # The generated queries is output to --file.
        # Note:
        #   Flags --generator/--templated-generator should be the last command line parameter.
        if [ -z "$QUERIES_FILE" ]; then log_error "Flag --file should be specified before --generator."; exit 1; fi
        if [ $SHOULD_CONTINUE_ON_STATE == false ]; then
            generate "$2";
        fi
        set --; break;
        shift 2;;
    --tg|--tgen|--templated-generator) # Generate queries to run by template.
        # Actions:
        # 1) templates
        # 2) args
        # 3) preview
        # 4) gen <generator_name> <argument_assignments>
        # The generated queries is output to --file.
        # Note:
        #   Flags --generator/--templated-generator should be the last command line parameter.
        if [ -z "$QUERIES_FILE" ]; then log_error "Flag --file should be specified before --templated-generator."; exit 1; fi
        shift;
        if [ $SHOULD_CONTINUE_ON_STATE == false ]; then
            generate_from_template "$@"
        fi
        set --; break;
        ;;
# ARGUMENT END
    *)
        usage; exit 1;
esac; done

# Get server PODs if not already.
if [[ ${#SERVER_PODS[@]} == 0 || -z "${SERVER_PODS[0]}" ]]; then
    if ! get_server_pods; then exit $?; fi
fi

if [ -z "$QUERIES_FILE" ]; then log_error "Specify a file containing single-line queries as --file <queries_file>."; exit 1; fi
if [ ! -f "$QUERIES_FILE" ]; then log_error "File does not exist: $QUERIES_FILE"; exit 1; fi

run "$QUERIES_FILE"
