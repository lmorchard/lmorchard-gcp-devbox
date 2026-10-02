# Session Notes: Issue 21 Persistent Data Disk

## Context
- Issue: https://github.com/lmorchard/lmorchard-gcp-devbox/issues/21
- Branch / Worktree: `.worktrees/issue-21-persistent-data-disk` (branch: `issue-21-persistent-data-disk`)

## Key Decisions & Findings
- Preserving all of `$HOME` rather than just `~/devel` ensures agent state (`~/.claude`, `~/.local/share/opencode`, `~/.codex`), shell history, tool caches, and dotfiles customizations survive VM teardown.
- Single persistent disk partitioned into `/mnt/disks/devbox-data/home` and `/mnt/disks/devbox-data/docker` via bind mounts.
- Dynamic UID/GID alignment detects numeric ownership of the existing persistent home directory to guarantee permissions never break across OS rebuilds.
