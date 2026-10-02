# Session Notes: Issue 22 Instant Disk Snapshots & Restore

## Context
- Issue: https://github.com/lmorchard/lmorchard-gcp-devbox/issues/22
- Branch / Worktree: `.worktrees/issue-22-disk-snapshots` (branch: `issue-22-disk-snapshots`)

## Key Decisions & Findings
- GCP differential compressed snapshots cost ~$0.026/GB/mo (less than 1/3 of persistent disk cost).
- Tagging snapshots with labels `managed-by=devbox`, `instance=$(INSTANCE_NAME)`, and `disk-type=boot|data` allows automated separation between boot and data disks during restore and pruning.
- Boot disk restores integrate directly into `do-up` via `--source-snapshot`, keeping network, service account, and guest metadata uniform.

## Implementation Summary
- `Makefile`:
  - Added `snapshot` target supporting `DISK=auto|boot|data|all` and custom `NAME`.
  - Added `list-snapshots` displaying formatted table with source disk, size, compressed storage, and timestamp.
  - Added `SOURCE_SNAPSHOT` integration to `do-up` using `--source-snapshot` for boot restores.
  - Added `restore-snapshot` with automated detection of boot vs data disk snapshots and overwrite safety checks.
  - Added `clean-snapshots` target to prune older snapshots while preserving `KEEP` most recent (default: 3).
- `README.md`:
  - Documented snapshot, listing, restore, and pruning commands.
  - Documented the near-$0.00 cold storage workflow.
