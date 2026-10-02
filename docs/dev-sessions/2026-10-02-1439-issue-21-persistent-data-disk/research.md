# Codebase Research: Persistent Data Disk for Home & Docker

## Current Lifecycle & Architecture

### Disk & VM Creation
- `Makefile:20-21`: Default boot disk configuration is `BOOT_DISK_SIZE ?= 100GB`, `BOOT_DISK_TYPE ?= pd-balanced`.
- `Makefile:345-358`: `do-up` invokes `gcloud compute instances create $(INSTANCE_NAME)` with:
  - `--boot-disk-size=$(BOOT_DISK_SIZE)`
  - `--boot-disk-type=$(BOOT_DISK_TYPE)`
  - `--boot-disk-auto-delete`
  - All storage (`/`, `/home/${DEV_USER}`, `/var/lib/docker`) lives on this single ephemeral boot disk.
- `Makefile:581-588`: `make down` runs `gcloud compute instances delete $(INSTANCE_NAME) ... --quiet`. Because `--boot-disk-auto-delete` is specified, the boot disk and all state within it are permanently destroyed.

### User Account Setup & Permissions
- `startup.sh:10-12`: Resolves `DEV_USER` from metadata attribute `dev-user` (default `lmorchard`), `DEV_HOME="/home/${DEV_USER}"`.
- `startup.sh:84-93`: Creates user `DEV_USER` if not present (`useradd -m -s /bin/zsh "${DEV_USER}"`), adds to `sudo` group, enables linger.
- In current running VM, `id` shows `uid=1001(lmorchard) gid=1002(lmorchard)` because the `ubuntu` user (UID 1000) was pre-created in the base cloud image.
- `startup.sh:146-148`: Adds `DEV_USER` to `docker` group and enables/starts Docker service.

### Tooling & Secrets Placement
- `startup.sh:157-165`: Appends `devbox-ssh-pubkey` to `${DEV_HOME}/.ssh/authorized_keys`.
- `startup.sh:319-346`: Sets up `.dotfiles` and `.oh-my-zsh`. Skips if `${DEV_HOME}/.dotfiles` already exists (`if [[ ! -d "${DEV_HOME}/.dotfiles" ]]`).
- `startup.sh:349-418`: Writes `.credentials.json` into `${DEV_HOME}/.claude` and `${DEV_HOME}/.dotfiles/.claude`, writes `agent-env.sh` into `${DEV_HOME}/.profile.d/agent-env.sh`.
- `startup.sh:426-491`: Sets up `${DEV_HOME}/devel`, clones repos listed in `REPOS_LIST` if target dir does not exist (`if [[ ! -d "${target_dir}" ]]`), runs setup hooks on fresh clones.
- `startup.sh:500-539`: Configures Wideboi systemd user service in `${DEV_HOME}/.config/systemd/user/wideboi.service`.

### GCE Persistent Disk Attachment Conventions
- GCE disks attached with `--disk=name=${DISK_NAME},device-name=${DEVICE_NAME},mode=rw,auto-delete=no` are symlinked by the guest OS at `/dev/disk/by-id/google-${DEVICE_NAME}`.
- Linux bind mounts (`mount --bind <src> <dest>`) allow subdirectories on a single ext4 persistent disk to be mapped to `/home/${DEV_USER}` and `/var/lib/docker`.

## Constraints & Gotchas Identified

1. **Mount Order in `startup.sh`:**
   - Persistent disk formatting and mount must happen early in `booting` stage.
   - `/mnt/disks/${DATA_DISK_NAME}/docker` must be bind-mounted to `/var/lib/docker` before `systemctl enable --now docker` (line 148).
   - `/mnt/disks/${DATA_DISK_NAME}/home` must be bind-mounted to `/home/${DEV_USER}` before `useradd`, SSH pubkey injection, dotfiles clone, and secret writing.

2. **UID/GID Determinism Across VM Recreations:**
   - If an existing `/mnt/disks/${DATA_DISK_NAME}/home` exists, its directory ownership determines the required UID and GID for `DEV_USER`.
   - `startup.sh` should check `stat -c '%u:%g' /mnt/disks/${DATA_DISK_NAME}/home` and ensure `DEV_USER` has matching UID/GID (creating with `--uid`/`--gid` or adjusting with `usermod`/`groupmod`).

3. **Disk Lifecycle:**
   - Disk must survive `make down` (detaches from VM, remains in zone).
   - `make up` attaches existing disk if present, or creates a new one if it doesn't exist yet.
   - `make destroy-infra` should prompt/clean up the persistent disk.
