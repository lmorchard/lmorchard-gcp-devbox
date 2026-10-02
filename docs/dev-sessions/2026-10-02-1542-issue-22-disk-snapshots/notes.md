# Session Notes: Issue 22 Instant Disk Snapshots & Restore

## Context
- Issue: https://github.com/lmorchard/lmorchard-gcp-devbox/issues/22
- Branch / Worktree: `.worktrees/issue-22-disk-snapshots` (branch: `issue-22-disk-snapshots`)

## Key Decisions & Findings
- GCP differential compressed snapshots cost ~$0.026/GB/mo (less than 1/3 of persistent disk cost).
- Tagging snapshots with labels `managed-by=devbox`, `instance=$(INSTANCE_NAME)`, and `disk-type=boot|data` allows automated separation between boot and data disks during restore and pruning.
- Boot disk restores integrate directly into `do-up` via `--source-snapshot`, keeping network, service account, and guest metadata uniform.
