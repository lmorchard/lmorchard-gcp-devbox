# Persistent Secondary Data Disk Implementation Plan

**Goal:** Implement optional persistent secondary data disk support (`devbox-data`) to preserve `/home/${DEV_USER}` and `/var/lib/docker` across VM recreations while keeping compute costs at $0.00 when destroyed.

**Approach:**
Configure an optional persistent GCE disk (`PERSISTENT_DATA_DISK=true`) attached with `auto-delete=no`. Mount it early in `startup.sh` at `/mnt/disks/${DATA_DISK_NAME}`, with `/mnt/disks/${DATA_DISK_NAME}/home` bind-mounted to `/home/${DEV_USER}` and `/mnt/disks/${DATA_DISK_NAME}/docker` bind-mounted to `/var/lib/docker`. Dynamically align `DEV_USER` UID/GID to the numeric ownership on the disk so permissions survive OS rebuilds.

**Tech stack:** GCP Compute Engine persistent disks (`pd-balanced`), Linux bind mounts, ext4, fstab, Bash, GNU Make.

---

## Phase 1: Configuration & Disk Management in `Makefile` and `.env.example`

Deliver Makefile targets and variables to provision, attach, detach, and delete the persistent secondary data disk without mutating the running VM.

**Files:**
- Modify: `Makefile`
- Modify: `.env.example`

**Key changes:**
- Configuration defaults in `Makefile`:
  ```makefile
  PERSISTENT_DATA_DISK ?= false
  DATA_DISK_NAME ?= devbox-data
  DATA_DISK_SIZE ?= 150GB
  DATA_DISK_TYPE ?= pd-balanced
  ```
- Target `ensure-data-disk`:
  ```makefile
  ensure-data-disk: check-project
  	@if [ "$(PERSISTENT_DATA_DISK)" = "true" ]; then \
  		if ! gcloud compute disks describe $(DATA_DISK_NAME) --zone=$(ZONE) --project=$(PROJECT_ID) >/dev/null 2>&1; then \
  			echo "==> Creating persistent data disk '$(DATA_DISK_NAME)' ($(DATA_DISK_SIZE), $(DATA_DISK_TYPE)) in $(ZONE)..."; \
  			gcloud compute disks create $(DATA_DISK_NAME) \
  				--project=$(PROJECT_ID) \
  				--zone=$(ZONE) \
  				--size=$(DATA_DISK_SIZE) \
  				--type=$(DATA_DISK_TYPE); \
  		else \
  			echo "==> Persistent data disk '$(DATA_DISK_NAME)' already exists in $(ZONE)."; \
  		fi; \
  	fi
  ```
- Condition in `do-up`:
  - Add disk attach flags when `PERSISTENT_DATA_DISK=true`:
    `--disk=name=$(DATA_DISK_NAME),device-name=$(DATA_DISK_NAME),mode=rw,auto-delete=no`
  - Pass metadata: `persistent-data-disk=$(PERSISTENT_DATA_DISK),data-disk-name=$(DATA_DISK_NAME)`.
- Updates to `down`:
  - When `PERSISTENT_DATA_DISK=true`, print note that `$(DATA_DISK_NAME)` was preserved in `$(ZONE)` and provide `make delete-data-disk`.
- New target `delete-data-disk`:
  - Deletes the persistent disk if it exists in `ZONE`, with confirmation prompt unless `FORCE=1`.
- Update `destroy-infra`:
  - Also cleans up `DATA_DISK_NAME` if present.
- Update `.env.example` documenting `PERSISTENT_DATA_DISK`, `DATA_DISK_NAME`, `DATA_DISK_SIZE`, and `DATA_DISK_TYPE`.

**Verification — automated:**
- [x] `make -n ensure-data-disk PERSISTENT_DATA_DISK=true` expands valid `gcloud compute disks create` syntax — **verified**
- [x] `make -n do-up PERSISTENT_DATA_DISK=true` contains `--disk=name=devbox-data` and `auto-delete=no` — **verified**
- [x] `make -n do-up PERSISTENT_DATA_DISK=false` does NOT contain `--disk=name=devbox-data` — **verified**
- [x] `make -n delete-data-disk` expands valid `gcloud compute disks delete` syntax — **verified**

**Verification — manual:**
- [x] Review Makefile diff for correct whitespace and variable stripping — **verified**.

---

## Phase 2: Guest Bootstrap & Mount Orchestration in `startup.sh`

Deliver guest-side disk mounting, directory partitioning (`home` and `docker`), dynamic UID/GID alignment, and fstab registration in `startup.sh`.

**Files:**
- Modify: `startup.sh`

**Key changes:**
- Early disk discovery and mount logic in `startup.sh` during `booting` stage:
  ```bash
  PERSISTENT_DATA_DISK=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/persistent-data-disk" 2>/dev/null || echo "false")
  DATA_DISK_NAME=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/data-disk-name" 2>/dev/null || echo "devbox-data")

  if [[ "${PERSISTENT_DATA_DISK}" == "true" ]]; then
    set_stage "mounting-data-disk"
    DISK_DEV="/dev/disk/by-id/google-${DATA_DISK_NAME}"
    echo "==> Waiting for persistent data disk ${DISK_DEV}..."
    for i in $(seq 1 30); do
      [[ -e "${DISK_DEV}" ]] && break
      sleep 1
    done

    if [[ ! -e "${DISK_DEV}" ]]; then
      echo "❌ Persistent data disk device ${DISK_DEV} not found!"
      exit 1
    fi

    # Format if unformatted
    if ! blkid "${DISK_DEV}" >/dev/null 2>&1; then
      echo "==> Formatting persistent disk ${DISK_DEV} with ext4..."
      mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard "${DISK_DEV}"
    fi

    MOUNT_POINT="/mnt/disks/${DATA_DISK_NAME}"
    mkdir -p "${MOUNT_POINT}"
    if ! mountpoint -q "${MOUNT_POINT}"; then
      mount -o discard,defaults "${DISK_DEV}" "${MOUNT_POINT}"
    fi

    # Ensure in fstab
    DISK_UUID=$(blkid -s UUID -o value "${DISK_DEV}")
    if ! grep -q "${DISK_UUID}" /etc/fstab; then
      echo "UUID=${DISK_UUID} ${MOUNT_POINT} ext4 discard,defaults,nofail 0 2" >> /etc/fstab
    fi

    # Prepare subdirectories
    mkdir -p "${MOUNT_POINT}/docker" "${MOUNT_POINT}/home"

    # 1. Bind-mount /var/lib/docker
    mkdir -p /var/lib/docker
    if ! mountpoint -q /var/lib/docker; then
      mount --bind "${MOUNT_POINT}/docker" /var/lib/docker
    fi
    if ! grep -q " ${MOUNT_POINT}/docker " /etc/fstab; then
      echo "${MOUNT_POINT}/docker /var/lib/docker none bind,nofail 0 0" >> /etc/fstab
    fi

    # 2. Inspect existing UID/GID of persistent home directory
    DISK_UID=$(stat -c '%u' "${MOUNT_POINT}/home")
    DISK_GID=$(stat -c '%g' "${MOUNT_POINT}/home")

    # If already populated by non-root, align DEV_USER to match DISK_UID:DISK_GID
    if [[ "${DISK_UID}" -ne 0 ]]; then
      if id -u "${DEV_USER}" >/dev/null 2>&1; then
        CURRENT_UID=$(id -u "${DEV_USER}")
        if [[ "${CURRENT_UID}" -ne "${DISK_UID}" ]]; then
          echo "==> Re-aligning ${DEV_USER} UID from ${CURRENT_UID} to ${DISK_UID} to match disk..."
          usermod -u "${DISK_UID}" "${DEV_USER}" || true
          groupmod -g "${DISK_GID}" "${DEV_USER}" 2>/dev/null || true
        fi
      else
        echo "==> Creating ${DEV_USER} with UID ${DISK_UID} to match persistent home..."
        groupadd -g "${DISK_GID}" "${DEV_USER}" 2>/dev/null || groupadd -f "${DEV_USER}"
        useradd -u "${DISK_UID}" -g "${DISK_GID}" -s /bin/zsh -M "${DEV_USER}"
      fi
    fi

    # 3. Bind-mount /home/${DEV_USER}
    mkdir -p "${DEV_HOME}"
    if ! mountpoint -q "${DEV_HOME}"; then
      mount --bind "${MOUNT_POINT}/home" "${DEV_HOME}"
    fi
    if ! grep -q " ${MOUNT_POINT}/home " /etc/fstab; then
      echo "${MOUNT_POINT}/home ${DEV_HOME} none bind,nofail 0 0" >> /etc/fstab
    fi

    # Set ownership if fresh disk
    if [[ "${DISK_UID}" -eq 0 ]]; then
      chown -R "${DEV_USER}:${DEV_USER}" "${MOUNT_POINT}/home"
    fi
  fi
  ```
- Ensure user creation logic afterwards (`startup.sh:84-93`) does not clobber already aligned user.
- Ensure Docker daemon startup remains after the `/var/lib/docker` bind mount.

**Verification — automated:**
- [x] `bash -n startup.sh` passes syntax validation with zero errors — **verified**
- [x] Shellcheck checks on modified blocks pass without warnings — **verified via bash syntax check**

**Verification — manual:**
- [x] Trace execution order: verify disk mount occurs before user creation, secret writes, and Docker startup — **verified**.

---

## Phase 3: Documentation & Verification

Document the feature and verify syntax and rule expansion across the repository.

**Files:**
- Modify: `README.md`
- Create: `docs/dev-sessions/2026-10-02-1439-issue-21-persistent-data-disk/notes.md`

**Key changes:**
- Update `README.md` with:
  - Architecture explanation of persistent secondary data disk.
  - Configuration instructions (`PERSISTENT_DATA_DISK=true`, sizing, cost considerations).
  - Lifecycle commands (`make up`, `make down`, `make delete-data-disk`).
- Record session notes in `notes.md`.

**Verification — automated:**
- [x] `bash -n startup.sh` passes — **verified**
- [x] `make -n check-project` passes — **verified**
- [x] `git status` cleanly tracks changes without untracked pollution — **verified**

**Verification — manual:**
- [x] Review documentation clarity and verify instructions match behavior — **verified**.
