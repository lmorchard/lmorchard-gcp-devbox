# Instant Disk Snapshot & Restore Implementation Plan

**Goal:** Implement instant point-in-time disk snapshot, listing, restore, and pruning targets (`make snapshot`, `make list-snapshots`, `make restore-snapshot`, `make clean-snapshots`) for both boot and persistent data disks.

**Approach:**
Use native GCP differential compressed snapshots with standardized metadata labels (`managed-by=devbox`, `instance`, `disk-type`). Enable `do-up` to boot directly from snapshots via `SOURCE_SNAPSHOT`, and support restoring secondary data disks from snapshots.

**Tech stack:** GCP Compute Engine snapshots, GNU Make, gcloud CLI.

---

## Phase 1: Snapshot Creation & Listing (`make snapshot` & `make list-snapshots`)

Deliver targets to create labeled point-in-time snapshots and list them in a formatted table.

**Files:**
- Modify: `Makefile`

**Key changes:**
- Targets:
  ```makefile
  # Snapshot devbox disks (boot, data, or both)
  snapshot: check-project
  ...
  # List devbox-managed snapshots
  list-snapshots: check-project
  ...
  ```
- Support parameters:
  - `DISK=auto|boot|data|all`
  - `NAME=custom-name`
  - `ALL=1` (for `list-snapshots`)
- Standardized labels:
  - `managed-by=devbox`
  - `instance=$(INSTANCE_NAME)`
  - `disk-type=boot` or `disk-type=data`

**Verification — automated:**
- [x] `make -n snapshot PROJECT_ID=test-proj` expands valid `gcloud compute disks snapshot` command — **verified**
- [x] `make -n snapshot DISK=boot PROJECT_ID=test-proj` targets boot disk — **verified**
- [x] `make -n snapshot DISK=data PROJECT_ID=test-proj` targets data disk — **verified**
- [x] `make -n list-snapshots PROJECT_ID=test-proj` expands valid `gcloud compute snapshots list` command — **verified**

**Verification — manual:**
- [x] Verify snapshot naming conforms to GCP regex `[a-z]([-a-z0-9]*[a-z0-9])?` — **verified**

---

## Phase 2: Snapshot Restoration & Cleanup (`make restore-snapshot` & `make clean-snapshots`)

Deliver targets to restore disks from snapshots and prune older snapshots.

**Files:**
- Modify: `Makefile`

**Key changes:**
- Update `do-up`:
  ```makefile
  ifeq ($(strip $(SOURCE_SNAPSHOT)),)
    IMAGE_OR_SNAPSHOT_FLAGS = --image-family=$(IMAGE_FAMILY) --image-project=$(IMAGE_PROJECT)
  else
    IMAGE_OR_SNAPSHOT_FLAGS = --source-snapshot=$(SOURCE_SNAPSHOT)
  endif
  ```
- Add `restore-snapshot`:
  - Inspects snapshot with `gcloud compute snapshots describe`.
  - If `disk-type=boot`: restores via `$(MAKE) do-up SOURCE_SNAPSHOT=$(SNAPSHOT)`.
  - If `disk-type=data`: recreates `$(DATA_DISK_NAME)` from snapshot in `$(ZONE)`.
- Add `clean-snapshots`:
  - Filters by `labels.managed-by=devbox`.
  - Sorts by `~creationTimestamp` and keeps `KEEP` most recent (default 3).
  - Prompts for confirmation unless `FORCE=1`.

**Verification — automated:**
- [x] `make -n do-up SOURCE_SNAPSHOT=test-snap PROJECT_ID=test-proj` contains `--source-snapshot=test-snap` and omits `--image-family` — **verified**
- [x] `make -n clean-snapshots PROJECT_ID=test-proj` expands valid `gcloud compute snapshots delete` commands — **verified**

**Verification — manual:**
- [x] Review restore logic for proper confirmation prompts if disks or instances already exist — **verified**

---

## Phase 3: Documentation in `README.md` & Verification

Document snapshot management, restore flows, and cold storage cost optimization in `README.md`.

**Files:**
- Modify: `README.md`
- Create: `docs/dev-sessions/2026-10-02-1542-issue-22-disk-snapshots/notes.md`

**Key changes:**
- Document `make snapshot`, `make list-snapshots`, `make restore-snapshot`, and `make clean-snapshots`.
- Document the "Cold Storage" workflow for dropping costs from ~$15-20/mo to ~$1/mo when pausing work.

**Verification — automated:**
- [ ] `make -n check-project` passes
- [ ] `git status` cleanly tracks changes without untracked pollution

**Verification — manual:**
- [ ] Review documentation clarity and verify example commands work as expected.
