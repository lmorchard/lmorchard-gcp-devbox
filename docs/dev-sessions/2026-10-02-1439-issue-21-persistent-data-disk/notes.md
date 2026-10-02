# Session Notes: Issue 21 Persistent Data Disk

## Context
- Issue: https://github.com/lmorchard/lmorchard-gcp-devbox/issues/21
- Branch / Worktree: `.worktrees/issue-21-persistent-data-disk` (branch: `issue-21-persistent-data-disk`)

## Key Decisions & Findings
- Preserving all of `$HOME` rather than just `~/devel` ensures agent state (`~/.claude`, `~/.local/share/opencode`, `~/.codex`), shell history, tool caches, and dotfiles customizations survive VM teardown.
- Single persistent disk partitioned into `/mnt/disks/devbox-data/home` and `/mnt/disks/devbox-data/docker` via bind mounts.
- Dynamic UID/GID alignment detects numeric ownership of the existing persistent home directory to guarantee permissions never break across OS rebuilds.

## Implementation Summary
- `Makefile` & `.env.example`:
  - Added `PERSISTENT_DATA_DISK`, `DATA_DISK_NAME`, `DATA_DISK_SIZE`, `DATA_DISK_TYPE`.
  - Added `ensure-data-disk` to provision disk in `ZONE` prior to VM launch when enabled.
  - Attached disk via `DATA_DISK_FLAGS` with `mode=rw,auto-delete=no`.
  - Passed `persistent-data-disk` and `data-disk-name` metadata attributes to guest instance.
  - Updated `down` to notify user of retained data disk and remind them of `$0.00` compute billing.
  - Added `delete-data-disk` target with confirmation prompt (or `FORCE=1`).
  - Integrated `delete-data-disk` into `destroy-infra`.
- `startup.sh`:
  - Added stage `mounting-data-disk` early in boot process.
  - Auto-formats disk with `ext4` if unformatted and mounts to `/mnt/disks/${DATA_DISK_NAME}`.
  - Bind-mounts `/mnt/disks/${DATA_DISK_NAME}/docker` to `/var/lib/docker` before Docker daemon starts.
  - Inspects existing numeric UID/GID of `/mnt/disks/${DATA_DISK_NAME}/home` and aligns `DEV_USER` dynamically.
  - Bind-mounts `/mnt/disks/${DATA_DISK_NAME}/home` to `/home/${DEV_USER}`.
  - Records mounts in `/etc/fstab`.
  - Guards `authorized_keys` against duplicate key appending.
- `README.md`:
  - Documented persistent data disk architecture, configuration options, and lifecycle commands.
- `scripts/migrate-to-data-disk.sh` & `make migrate-to-data-disk`:
  - Hot-attaches persistent data disk to running devbox VM without rebooting.
  - Takes a safety snapshot of the boot disk prior to data copying.
  - Formats and mounts data disk at `/mnt/disks/${DATA_DISK_NAME}`.
  - Non-destructively rsyncs `/home/${DEV_USER}` (and optional Docker) to the persistent disk.
  - Leaves the running workspace completely unmutated and operational.
