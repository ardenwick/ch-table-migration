#!/bin/bash
# Re-open stdin from /dev/null so bash 4.x doesn't read the script via fd 0 — any subprocess that
# reads from stdin (like "echo snippet | bash --norc --noprofile") would otherwise advance the
# script's read position and cause bash to skip subsequent commands.
exec </dev/null
# Tests for --remote-bastion-server / --remote-namespace / --remote-shards /
# --remote-replica / --remote-k8s-label (discover_remote_hosts).
#
# Run ON root@10.65.153.16 from the repo root:
#
#   ssh root@10.65.153.16 'bash /data/repo/ch-table-migration/snippets/remote_hosts-discovery-test.sh'
#
# Target cluster topology (namespace 'ck', chi-datalake):
#   shard 0 replica 0 -> 10.65.153.107   shard 0 replica 1 -> 10.65.153.102
#   shard 1 replica 0 -> 10.65.153.106   shard 1 replica 1 -> 10.65.153.103
#   shard 2 replica 0 -> 10.65.153.104   shard 2 replica 1 -> 10.65.153.105

cd /data/repo/ch-table-migration || exit 1

# Bootstrap KUBECONFIG from the login shell if not already set.  The same-cluster
# discovery path runs 'bash --norc --noprofile' locally, which skips .bashrc and
# therefore misses any KUBECONFIG assignment there.
: "${KUBECONFIG:=$(bash -lc 'echo $KUBECONFIG' 2>/dev/null)}"
export KUBECONFIG

# Clear kubectl-response caches so prior runs don't affect results.
rm -rf .crc/cache/ 2>/dev/null

BASTION=root@10.65.153.16
BASE="./ch-raw-copier send -u root -d /tmp/discovery-test --db datalake --no-cache"
J="-J $BASTION"

PASS=0; FAIL=0

ok()   { ((++PASS)); printf '  PASS  %s\n' "$1"; }
fail() { ((++FAIL)); printf '  FAIL  %s\n' "$1"; [ -n "$2" ] && printf '        %s\n' "$2"; }

# Run command; capture combined stdout+stderr with ANSI stripped in $output, exit code in $RUN_RC.
run() {
    local raw
    raw=$(bash -c "$*" </dev/null 2>&1)
    RUN_RC=$?
    output=$(printf '%s' "$raw" | sed 's/\x1b\[[0-9;]*m//g')
}

# Extract "N" from "Discovered N remote host(s): …"
n_hosts()  { printf '%s' "$output" | grep -oP 'Discovered \K\d+(?= remote)'; }
# Sorted comma-joined IPs from the Discovered line.
ip_list()  { printf '%s' "$output" | grep -oP 'Discovered [0-9]+ remote host[s]?: \K.*' | tr ',' '\n' | sort | paste -sd,; }
# True if the Discovered line appears at all.
discovered() { printf '%s' "$output" | grep -qE 'Discovered [0-9]+ remote host'; }

# ---------------------------------------------------------------------------
echo "=== Happy-path discovery ==="

run "$BASE $J"
if discovered && [ "$(n_hosts)" -eq 3 ]; then
    ok "bastion auto-detect namespace → 3 replica-0 hosts"
else
    fail "bastion auto-detect namespace → 3 replica-0 hosts" "n=$(n_hosts) rc=$RUN_RC"
fi

run "$BASE $J --ns2 ck"
if discovered && [ "$(n_hosts)" -eq 3 ]; then
    ok "bastion + explicit --ns2 ck → 3 hosts"
else
    fail "bastion + explicit --ns2 ck → 3 hosts" "n=$(n_hosts) rc=$RUN_RC"
fi

run "$BASE --ns2 ck"
if discovered && [ "$(n_hosts)" -eq 3 ]; then
    ok "same-cluster --ns2 only (no bastion) → 3 hosts"
else
    fail "same-cluster --ns2 only (no bastion) → 3 hosts" "n=$(n_hosts) rc=$RUN_RC"
fi

# ---------------------------------------------------------------------------
echo "=== Shard filtering ==="

run "$BASE $J --remote-shards 1"
if discovered && [ "$(n_hosts)" -eq 1 ] && [ "$(ip_list)" = "10.65.153.106" ]; then
    ok "--remote-shards 1 → 10.65.153.106"
else
    fail "--remote-shards 1 → 1 host" "got: $(ip_list)"
fi

run "$BASE $J --remote-shards 0-1"
if discovered && [ "$(n_hosts)" -eq 2 ] && [ "$(ip_list)" = "10.65.153.106,10.65.153.107" ]; then
    ok "--remote-shards 0-1 (range) → 106,107"
else
    fail "--remote-shards 0-1 → 2 hosts" "got: $(ip_list)"
fi

run "$BASE $J --remote-shards 0,2"
if discovered && [ "$(n_hosts)" -eq 2 ] && [ "$(ip_list)" = "10.65.153.104,10.65.153.107" ]; then
    ok "--remote-shards 0,2 (disjoint) → 104,107"
else
    fail "--remote-shards 0,2 → 2 hosts" "got: $(ip_list)"
fi

# ---------------------------------------------------------------------------
echo "=== Replica filtering ==="

run "$BASE $J --remote-replica 1"
if discovered && [ "$(n_hosts)" -eq 3 ] && [ "$(ip_list)" = "10.65.153.102,10.65.153.103,10.65.153.105" ]; then
    ok "--remote-replica 1 → 3 alt hosts (102,103,105)"
else
    fail "--remote-replica 1 → 3 hosts" "got: $(ip_list)"
fi

run "$BASE $J --remote-shards 1 --remote-replica 1"
if discovered && [ "$(n_hosts)" -eq 1 ] && [ "$(ip_list)" = "10.65.153.103" ]; then
    ok "--remote-shards 1 --remote-replica 1 → 10.65.153.103"
else
    fail "--remote-shards 1 --remote-replica 1" "got: $(ip_list)"
fi

# ---------------------------------------------------------------------------
echo "=== Error cases ==="

run "$BASE $J --remote-shards 99"
if [ $RUN_RC -ne 0 ] && echo "$output" | grep -q "No remote ClickHouse server PODs matched"; then
    ok "--remote-shards 99 (no match) → exit 1 + pod_regex error"
else
    fail "--remote-shards 99 should fail with pod_regex error" "rc=$RUN_RC"
fi

run "$BASE $J --remote-k8s-label nope.x/nope"
if [ $RUN_RC -ne 0 ] && echo "$output" | grep -q "Not found any ClickHouse server PODs"; then
    ok "--remote-k8s-label nope → exit 1 + not-found error"
else
    fail "--remote-k8s-label nope should fail" "rc=$RUN_RC"
fi

run "$BASE -H 1.2.3.4 --ns2 ck"
if [ $RUN_RC -ne 0 ] && echo "$output" | grep -q "must NOT be combined"; then
    ok "--hosts + --ns2 → exit 1 (mutually exclusive)"
else
    fail "--hosts + --ns2 should be rejected" "rc=$RUN_RC"
fi

run "$BASE -H 1.2.3.4 $J"
if [ $RUN_RC -ne 0 ] && echo "$output" | grep -q "must NOT be combined"; then
    ok "--hosts + -J → exit 1 (mutually exclusive)"
else
    fail "--hosts + -J should be rejected" "rc=$RUN_RC"
fi

run "./ch-raw-copier send $J -d /tmp/discovery-test --db datalake"
if [ $RUN_RC -ne 0 ] && echo "$output" | grep -q "Missing SSH user name"; then
    ok "missing --user → exit 1"
else
    fail "missing --user should fail" "rc=$RUN_RC"
fi

# ---------------------------------------------------------------------------
echo
printf 'Results: %d passed, %d failed\n' $PASS $FAIL
[ $FAIL -eq 0 ]
