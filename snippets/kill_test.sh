# 2. kill group
# 1. spread in redistribute mode

function pid_descendants()
{
    local include_parent=${1:-true}; shift
    local pids="${*:-$BASHPID}"
    [ $include_parent == true ] && echo $pids;
    ps -eo pid,ppid | awk -v pids="$pids" '
        BEGIN {  n = split(pids, arr); for (i=1; i<=n; i++) descendants[arr[i]]=1 }
        {
            if ($2 in descendants) {
                descendants[$1]=1
                print $1
            }
        }
    '
}

(
    echo $$:$BASHPID;
    (
        echo $$:$BASHPID;
        (
            echo "$$:$BASHPID sleeping"
            sleep 1
            echo "$$:$BASHPID sleep exit"
        ) &
        kill -s SIGTERM -- -$BASHPID; echo xyz; wait
    ) &
    echo job: $!;
    echo Has jobs $(jobs -p);

    ps -f --forest
    echo -------
    pid_descendants false
    echo -------
    pid_descendants true
    wait
)


