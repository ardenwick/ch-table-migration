declare -gx SSH_USER=root SSH_PORT=22 SSH="${SSH:-ssh} -oGSSAPIAuthentication=no -oStrictHostKeyChecking=no"
declare -gx KUBECTL=${KUBECTL:-'kubectl -n ck'}
function remote_bash() { local host=$1; shift; eval $SSH -T $SSH_USER@$host bash --norc --noprofile "$@" 2> >(grep -v '^Warning: Permanently added' >&2); }

# Setup SSH public key authentication for all hosts
nodes=$($KUBECTL get nodes -o custom-columns=':.status.addresses[0].address')
for n in $nodes; do (echo $n; echo "yes | ssh-keygen -t rsa -b 2048 -q -N '' -f ~/.ssh/id_rsa" | remote_bash $n); done
keys=$(for n in $nodes; do (echo -e "\n# $n"; echo "cat ~/.ssh/id_rsa.pub" | remote_bash $n); done | tee /dev/stderr)
for n in $nodes; do (echo $n; echo "echo \"$keys\" >> ~/.ssh/authorized_keys" | remote_bash $n) done

# Drop caches
for n in $nodes; do (echo "sync; echo 3 > /proc/sys/vm/drop_caches" | remote_bash $n) & done; wait

# Clean up remote directories
for n in $nodes; do (echo "{ rm -rvf /data/crc/; rm -rvf /data/crc/; } |& grep 'removed directory'" | remote_bash $n); done

# Check process tree
printf "%*s\n" $COLUMNS | tr ' ' '-'; ps -ef --forest | grep -w rsync_with_record -C 10 --color=always | cut -c 1-$COLUMNS

# Backup
export CLICKHOUSE_USER=root CLICKHOUSE_PASSWORD=default
./ch-raw-copier send    --ns=ck -H dmoc-fefcfe0c0979,dmoc-fefcfe059923 -d /data/crc/dump2025115_1/ -u admin --db=system --cond="partition LIKE '%2026-10%'" -v --redist --patch-rc -j5

# Restore
export CLICKHOUSE_USER=root CLICKHOUSE_PASSWORD=default
./ch-raw-copier restore --ns=ck -d /data/crc/dump2025115_1/ -u admin --db=system -v --clear-detached -j10 --ddl --views --dictionaries --functions
