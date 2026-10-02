# Persistent Secondary Data Disk for Devbox Spec

**Goal:** Enable an optional persistent secondary data disk (`devbox-data`) preserving all of `$HOME` and `/var/lib/docker` across VM teardowns and rebuilds, allowing instant workspace resumption and $0.00 compute billing on `make down`.

**Source:** https://github.com/lmorchard/lmorchard-gcp-devbox/issues/21

## Current state
- The devbox VM is created with a single root boot disk (`--boot-disk-auto-delete`) (`Makefile:351-353`).
- On `make down`, `gcloud compute instances delete` destroys the instance and its boot disk (`Makefile:581-588`).
- All state — including uncommitted git changes, warm Docker image layers, agent sessions (`~/.claude`, `~/.local/share/opencode`, `~/.codex`), shell history (`.zsh_history`), and tool build caches — is deleted upon teardown.
- Bringing up a new VM requires 5–10 minutes to pull heavy container images and re-clone repositories (`startup.sh:121-149`, `426-491`).

## Desired end state
- When `PERSISTENT_DATA_DISK=true` is set in `.env` (defaulting to `false` for backwards compatibility):
  - A persistent GCE disk (`DATA_DISK_NAME`, default `devbox-data`) of configurable size (`DATA_DISK_SIZE`, default `150GB`) and type (`DATA_DISK_TYPE`, default `pd-balanced`) is created if it does not already exist in `ZONE`.
  - On `make up`, the disk is attached to the instance with `auto-delete=no` and `device-name=$(DATA_DISK_NAME)`.
  - On instance boot, `startup.sh`:
    1. Waits for `/dev/disk/by-id/google-${DATA_DISK_NAME}` to appear.
    2. Formats the disk with `ext4` if unformatted.
    3. Mounts it at `/mnt/disks/${DATA_DISK_NAME}` with `discard,defaults,nofail`.
    4. Creates top-level subdirectories `/mnt/disks/${DATA_DISK_NAME}/home` and `/mnt/disks/${DATA_DISK_NAME}/docker`.
    5. Bind-mounts `/mnt/disks/${DATA_DISK_NAME}/docker` -> `/var/lib/docker` before Docker daemon starts.
    6. Inspects existing UID/GID of `/mnt/disks/${DATA_DISK_NAME}/home` and ensures `DEV_USER` matches the numeric UID/GID on the disk.
    7. Bind-mounts `/mnt/disks/${DATA_DISK_NAME}/home` -> `/home/${DEV_USER}` before dotfiles, secrets, and shell initialization.
    8. Persists all three mounts in `/etc/fstab`.
  - On `make down`, the VM is deleted, but the persistent disk detaches cleanly and remains in GCP.
  - On `make destroy-infra`, the user is prompted (or warned) before the persistent disk is deleted.
  - A new helper target `make delete-data-disk` allows explicit deletion of the persistent disk when desired.

## Design decisions
- **Decision:** Store both `$HOME` and `/var/lib/docker` on subdirectories of a single persistent disk (`/mnt/disks/devbox-data/home` and `/mnt/disks/devbox-data/docker`) via bind mounts.
  - **Why:** Preserving all of `$HOME` (instead of just `~/devel`) preserves Claude Code sessions, Opencode state, Codex state, shell history, dotfiles customizations, and tool build caches (`~/.npm`, `~/.cache`, `~/go`, `~/.terraform.d`). Using a single disk avoids paying for multiple minimum disk sizes and keeps snapshotting consolidated to a single volume.
  - **Rejected:** Separate disks for Docker vs Home (more complex, higher minimum cost, requires managing two volumes).
  - **Rejected:** Preserving only `~/devel` (causes friction by wiping agent sessions, dotfiles, and shell state).

- **Decision:** Align `DEV_USER` UID/GID dynamically to the disk's existing numeric UID/GID on subsequent mounts.
  - **Why:** Base cloud images or builder images may create default users (`ubuntu`) in different orders, leading to UID shifts (1000 vs 1001). Inspecting `stat -c '%u:%g'` from `/mnt/disks/${DATA_DISK_NAME}/home` ensures permissions on persistent files never break across OS rebuilds.
  - **Rejected:** Hardcoding a static UID (e.g. 1001) without verification (fails if an image assigns that UID to a system account or existing user).

- **Decision:** Retain `PERSISTENT_DATA_DISK=false` as default, enabling via `.env`.
  - **Why:** Ensures backwards compatibility and preserves the zero-cost pure-ephemeral behavior by default unless explicitly opted in.

## Patterns to follow
- Metadata parameter extraction: `startup.sh:10-12` (`curl -s -H "Metadata-Flavor: Google" ...`).
- Network and Service Account existence checks: `Makefile:150-192` (`ensure-network`, `ensure-sa`). Follow this pattern for `ensure-data-disk`.
- Idempotent tool & directory setup: `startup.sh:319-346` (dotfiles skip check), `startup.sh:441-470` (repo clone skip check).
- Secrets synchronization: `startup.sh:349-418` (secrets are refreshed on each boot even if home directory is warm).

## What we're NOT doing
- We are NOT implementing GCP snapshots and restore in this session (that is Issue #22, which will build directly on top of this disk).
- We are NOT mounting separate disks for `~/devel` vs `/var/lib/docker`.
- We are NOT running automated Docker prune daemons in this change (handled separately if disk capacity issues arise).
- We are NOT mutating or modifying the currently running active VM in this session.

## Open questions
- *Question:* Should `make down` print the persistent disk status and monthly cost reminder when `PERSISTENT_DATA_DISK=true`?
  - *Default answer:* Yes, `make down` should inform the user that the persistent data disk was retained and remains available in the zone, along with `make delete-data-disk` instructions if they wish to destroy it.
