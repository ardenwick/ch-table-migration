# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

This repo ships two self-contained Bash executables that share a similar internal style but are independent programs:

- `ch-raw-copier` — copies raw ClickHouse data parts (and DDL/access entities) between Kubernetes-hosted ClickHouse clusters via SSH+rsync. (~3300 lines, the focus of this guide.)
- `ch-table-migration` — orchestrates in-place table-structure migrations (PARTITION BY / ORDER BY / TTL changes) on a live cluster using a Merge-table trampoline. Procedure is described in `docs/ch-table-migration.wiki.md` / `docs/上手指南.md`.

Both are single-file bash scripts intentionally — no source/include split. Edits go directly into the script you're targeting; there is no build step that produces them.

Other artifacts:
- `for_each_line2.sh` — standalone helper used by `ch-table-migration` to parallelise per-row work; bundled into the release tarball.
- `datalake-commands.sh` — a long list of canned `init` invocations for production tables, not a library.
- `snippets/` — copy-paste recipes (`copy` is the full migration walkthrough for one table, `scratch.sh` has SSH-key bootstrap + invocation examples for `ch-raw-copier`).
- `assets/` — diagrams referenced by `docs/`.
- `build_artifacts.sh` — packages a release tarball. Reads version from `git describe` + short SHA.
- `.crc/cache/` and `/tmp/crc/<TASK_SIGNATURE>/` — runtime caches for `ch-raw-copier` (gitignored).

## Running and testing

There are no unit tests and no lint config. Both tools are exercised by running them against a live (or test) ClickHouse cluster on Kubernetes.

```bash
# show full help (parsed from #>>> ARGUMENT BEGIN/END comment blocks in the script itself)
./ch-raw-copier --help
./ch-table-migration --help

# build a release tarball
./build_artifacts.sh
```

The recipe in `snippets/scratch.sh` shows the typical bootstrap for `ch-raw-copier`: setting up SSH keypairs across all Kubernetes nodes, then a representative `send` / `restore` pair. `snippets/copy` shows the analogous end-to-end recipe for `ch-table-migration`.

When iterating on changes, the practical loop is: edit the script, run it with `--log-level debug` or `-V` against a small test database/table on a real cluster. Use `--dry` where supported (note: `ch-raw-copier --dry` is documented as "Not implemented").

`kill_test.sh` is an ad-hoc test of process-group kill behaviour — run it directly to verify trap/wait semantics; it is not a regression test.

## `ch-raw-copier` architecture

The script has **four user-facing commands** (see `usage()` and the `case $COMMAND` block near the bottom): `send`, `restore`, `report`, `relay`.

The same script binary runs in two distinct modes:

1. **Master mode** — invoked by the user with `WORKER_MODE` unset. Parses args, talks to Kubernetes (`kubectl exec` into ClickHouse pods via `kube_chc_query` / `kube_ch`), discovers pods/disks/hostpaths, then dispatches work to remote nodes.
2. **Worker mode** — re-invoked over SSH on each Kubernetes *node* (not pod) with `WORKER_MODE=<name>` set in the shell env. The dispatch mechanism is `call_remote_worker()`: it concatenates a serialized-variables prologue with the entire script body and pipes it into `ssh ... bash --norc --noprofile`. The early block near the bottom — `if [ -n "$WORKER_MODE" ]; then worker; exit $?; fi` — runs *before* CLI parsing, so workers never see the user's argv. The `worker()` function then dispatches to `${WORKER_MODE}_worker` (e.g. `send_worker`, `restore_worker`, `report_worker`, `p2p_worker`, `spread_worker`, `restore_access_worker`, `collect_create_queries_worker`, `gather_directories_and_table_names_in_base_worker`, `launder_detached_for_base_worker`).

Variable serialization between master and worker is done with `variables_declaration` (emits `declare -g …` lines) over the `common_variables` array. When adding a flag that must reach workers, add it to `common_variables` near the bottom *and* declare it explicitly inside the `call_remote_worker` argument when scope requires (e.g. `POD`, `DISK_DIR`).

### Data flow within a `send`

`send()` → checks cluster readiness, consistency, partitions → optionally `freeze_partitions` → calls `p2p()` then `spread()`:

- **`p2p`**: pairs each chosen local pod with one remote host in order. Extra local pods are either round-robined (default) or redistributed (`--redistribute`).
- **`spread`**: only runs with `--redistribute`; takes the remainder pods (where `N % M != 0`) and fan-outs their data across *all* remote hosts, partitioning by `hash(partition_id) % M`. The branch matrix is documented inline in the `--redistribute` help text and is the single source of truth for that behavior.

Both call `call_remote_worker $node {p2p,spread}` which ends up invoking `send_worker` (since `p2p_worker` and `spread_worker` are aliases for `send_worker`). `send_worker` enumerates data parts (`enumerate_parts`), batches them (`RSYNC_BATCH_SIZE`, default 500), and runs `rsync_with_record` per batch with per-pod stats files at `$TMPDIR/stats.$pod`.

### `relay`

Unlike the other commands, `relay` runs purely on the local host — it re-sends data from a previously-received `--directory` to a new set of remote hosts, reusing the same `send_worker` function but without going through Kubernetes pod discovery. The p2p/spread branching mirrors `send`.

### `restore`

Master discovers tables/databases per source-subdirectory by dispatching `gather_directories_and_table_names_in_base_worker` to each node, then optionally restores DDL / access entities / functions / dictionaries / views (`collect_create_queries_worker`, `restore_access_worker`), then dispatches `restore_node` (which itself dispatches `restore_worker` and `launder_detached_for_base_worker`) to perform `mv`/`rsync` from `$BASE_DIR/<pod>` into the pod's disk hostpath, followed by `ATTACH PARTITION`. `--best-effort` enables the rescue loop that prunes broken parts on intersection / checksum / permission errors.

### Concurrency and lifecycle primitives

- `wait_pids_patiently` — used everywhere instead of bare `wait`. Logs which job is still running each interval; the second/third args are matched-up PID and name lists.
- `trap_kill_group` / `trap_restore_kill_group` — installed in `send`/`restore`/`report`/`relay` to ensure SIGINT/SIGTERM propagate to the entire process group. Critical when the master is killed: descendants on local + remote hosts must die too. `exit_when_orphaned` (started inside `worker()`) handles the inverse — a remote worker whose master died via broken SSH pipe.
- `disable_signals` / `restore_signals` — used inside critical sections of state I/O (see `store()` in `ch-table-migration`) so that a Ctrl-C while persisting state does not corrupt the state file. Queued signals are replayed afterward.
- `lock_file` / `flock` patterns — used for the per-pod stats file (`$RSYNC_STATS_FILE.lock`) and the on-disk cache. `relay` re-uses these locks to skip subdirectories that another invocation is already streaming.
- `init_cache` / `read_cache` / `write_cache` (under `.crc/cache/`) — short-lived caches of kubectl/clickhouse responses, keyed by `TASK_SIGNATURE` (sha1 of `$SSH_USER $BASE_DIR`). `--no-cache` bypasses.
- `create_and_enter_cgroup` — used inside workers when `--io <bandwidth>` is set; throttles the rsync via cgroup v2 io.max. Creating the cgroup requires the remote SSH user to have root-level permissions on that node.

### Logging convention

Common to both scripts: log functions `log_trace`/`log_debug`/`log_info`/`log_notify`/`log_warn`/`log_error`/`log_fatal` write to FDs 11/12 (preserved copies of stdout/stderr at script start). This lets internal redirections (e.g. capturing the output of a subshell) coexist with logging. `LOG_LEVEL` (env or `--log-level`) gates by priority; colors come from `LOG_COLORS`. In `ch-raw-copier`, `redefine_logger_for_host()` adds the pod/host marker once `POD`/`HOSTNAME` are known — call this at the start of any new worker function. `ch-table-migration` has analogous `log_state_*` variants that include the current state name.

## `ch-table-migration` architecture (in brief)

A persistent state machine. Each task lives in its own directory containing `config`, `state`, `state.override`, plus state-specific files. A systemd service (`chtm_<name>.service`) is created per task by the `create` command; the service simply re-invokes the script in `walk` mode against that task directory.

Key concepts (cross-reference `docs/ch-table-migration.wiki.md`):

- **State**: a function pair `s_<Name>` (forward) and `r_<Name>` (revert), optionally `c_<Name>` (clean a dirty state). `walk_state_unlocked` chooses which to call based on `$REVERT` / `$DIRTY`.
- **Procedure**: an ordered list of states. The pre-defined arrays are `states_full`, `states_full_no_stop_ttl`, `states_simple`, `states_simplest`, `states_lazy`, `states_copy`, `states_copy_simple`. The `Rearrange` state auto-picks one based on row count.
- **Chameleon / DT tables**: `CHAMELEON` is the original table after the `SwapTables` swap (it holds existing data behind a new name); `DT` is the destination table that data gets copied into; `MERGE` is a transient Merge-engine table the distributed view points at during the migration so reads keep working.
- **State variables** are all enumerated in the `state_variables` array (around line 275). Configurable ones are prefixed `STATE_<StateName>_…`. The `vars` command prints them.

When adding a new state: define `s_<Name>` (required), `r_<Name>` (required for any state in a revertable procedure), insert the name into the relevant `states_*` arrays, and add any new persisted variables to `state_variables`.

## Argument parsing convention (both scripts)

Both scripts use a self-describing CLI: `usage()` and `normalize_opts()` `sed`-parse the script source between `#>>> ARGUMENT BEGIN/END`, `#>>> COMMAND ARGUMENT BEGIN/END`, and `#>>> FLAG ARGUMENT BEGIN/END` markers to derive the getopt spec and help text from the inline `case` block. When adding a new flag, place it inside those markers and follow the comment convention:

- `--flag) #: Help text starts here…` (with `#:` immediately after `)` for value-taking flags) — `normalize_opts` reads the `#:` to know it needs an argument; `usage()` reads the trailing text as help.
- `--flag) # Help text…` (with `#` alone) for boolean flags.
- Multi-line help: continuation lines are 12-space-indented `# …` lines.

Do not break this convention; help output and getopt parsing both depend on it.

## Things to know before editing

- Worker functions execute on remote SSH targets where the local environment does NOT carry over — every variable they need must be explicitly exported via `variables_declaration` in the `call_remote_worker` call, or added to `common_variables`. Symptoms of forgetting this are silent empty values inside the worker.
- Many helpers are exported with `declare -fx` (the line near the bottom of `ch-raw-copier`: `declare -fx $(compgen -A function | grep -wv …)`). The grep `-wv` exclusion list is the set of top-level entry points that should *not* be re-exported (`p2p`, `spread`, `restore`, `send`, `report`, `worker`). New top-level entry points should be added to that exclusion.
- `set -e` is used inside subshells `({ … })` for atomic units of work in `send`/`restore`/`relay`; do not mix it with deliberate non-zero returns without `|| :`.
- The cache at `.crc/cache/` is keyed by `TASK_SIGNATURE` (sha1 of `$SSH_USER` + `$BASE_DIR`). Two runs with the same user+directory share the cache; passing `--no-cache` skips reads but still writes.
- `for_each_line2.sh` is included verbatim in the release tarball by `build_artifacts.sh`; keep it in sync with what `ch-table-migration` expects to find next to it on the target host.
