---
name: remote-test
description: Mirror repo to remote host via rsync and execute commands via ssh. For testing ch-raw-copier/ch-table-migration on hosts with kubectl + ClickHouse cluster access.
---

# remote-test

Sync working tree to remote host at same absolute path, then run shell commands.

## Steps

1. **Confirm target.** Ask user for `<user>@<host>`, defaulting to `root@10.65.153.16` (Recommended).
2. **Resolve path.** Run `git rev-parse --show-toplevel` (don't hardcode).
3. **Sync:**
   ```bash
   rsync -aR --exclude='.git/' --exclude='.crc/' --exclude='/tmp/' <repo-abspath> <user>@<host>:/"
   ```
   - `-R` preserves absolute path; no trailing slash on `<repo-abspath>`
   - **Never** use `--delete` — keep remote caches
4. **Run command.** Use user args if provided, else propose sensible default (e.g. `bash -n ch-raw-copier`).
5. **Execute via ssh:**
   ```bash
   ssh -T <user>@<host> <<'EOF'
   cd <repo-abspath>
   <commands>
   EOF
   ```
   If `kubectl` missing, use `ssh -T host bash -lc '...'` for login shell.
6. **Report** exit code and stderr. If missing tooling, say so explicitly.

## Notes
- SSH key auth required — never feed passwords
- For repeated iteration, chain sync + run into single command
5. **Run.** Pipe commands to `ssh -T` from the repo root on the remote:

   ```bash
   echo 'cd <repo-abspath> && <commands>' | ssh -T <user>@<host>
   ```

   For multi-line scripts use a heredoc:

   ```bash
   ssh -T <user>@<host> <<'EOF'
   cd <repo-abspath>
   <commands>
   EOF
   ```

   Quote the heredoc terminator (`'EOF'`) so local shell variables don't expand before being sent.

6. **Report.** Echo back the remote exit code and any stderr the user should see. If the remote command failed because of missing tooling (`kubectl`, `jq`, `rsync`), say so explicitly rather than retrying.

## Notes

- SSH key auth is required — never feed passwords.
- The remote may have a different bashrc setup; if `kubectl` is missing under non-interactive shell, switch from `ssh -T host` to `ssh -T host bash -lc '...'` to pick up login PATH.
- For repeated iteration in one session, chain steps 3 + 5 into a single Bash invocation rather than asking again.
