# Codebase Research: Instant Disk Snapshot & Restore Targets

## Current Lifecycle & Architecture

### Disk Architecture in Repo
- Ephemeral boot disk:
  - Created in `do-up` (`Makefile:377-402`) using `--image-family=$(IMAGE_FAMILY)` and `--boot-disk-auto-delete`.
  - Destroyed in `down` (`Makefile:621-638`).
- Persistent secondary data disk (added in PR #33):
  - Created in `ensure-data-disk` (`Makefile:211-229`).
  - Attached in `do-up` (`Makefile:389`) with `auto-delete=no`.
  - Detached and preserved on `down`.
  - Can be deleted explicitly via `delete-data-disk` (`Makefile:651-675`).

### GCE Snapshot Mechanics
1. **Creation:**
   - `gcloud compute disks snapshot DISK_NAME --snapshot-names=NAME --zone=ZONE --project=PROJECT_ID --labels=KEY=VAL`
   - GCE snapshots are differential and compressed at the block level (~$0.026/GB/mo).
   - Can be taken while disk is attached and instance is RUNNING without unmounting.
   - Naming constraints: lowercase letters, numbers, and hyphens; 1-63 chars; starts with a letter.
2. **Restoring Boot Disk:**
   - `gcloud compute instances create` accepts `--source-snapshot=SNAPSHOT_NAME` as an alternative to `--image-family`/`--image-project`.
   - Creating an instance directly from `--source-snapshot` provisions a boot disk containing the exact filesystem state captured in the snapshot.
3. **Restoring Secondary Data Disk:**
   - `gcloud compute disks create DISK_NAME --source-snapshot=SNAPSHOT_NAME --zone=ZONE --type=TYPE`
   - Creates a persistent disk pre-populated with the exact snapshot blocks.
4. **Metadata & Inspection:**
   - `gcloud compute snapshots describe SNAPSHOT_NAME` returns `sourceDisk`, `diskSizeGb`, `storageBytes`, `creationTimestamp`, and labels.
   - Using label `--labels=managed-by=devbox,instance=INSTANCE_NAME,disk-type=boot|data` allows precise filtering with `--filter="labels.managed-by=devbox"`.
5. **Pruning:**
   - Older snapshots can be pruned using `gcloud compute snapshots list --filter=... --sort-by="~creationTimestamp"` similar to `clean-images` in `Makefile:321-344`.

## Constraints & Gotchas Identified

1. **Snapshot Source Differentiation:**
   - A snapshot can be of a boot disk or a secondary data disk.
   - Restoring a boot disk requires launching a VM with `--source-snapshot`.
   - Restoring a data disk requires creating `DATA_DISK_NAME` from `--source-snapshot`.
   - Tagging snapshots with label `disk-type=boot` or `disk-type=data` allows `make restore-snapshot` to automatically determine whether to restore as a boot disk or a data disk!

2. **Snapshot Collision & Naming:**
   - Custom names provided via `make snapshot NAME=foo` must conform to GCP naming rules. Sanitizing to lowercase/hyphens avoids gcloud CLI errors.
   - Default naming convention: `devbox-$(INSTANCE_NAME)-$(DISK_TYPE)-$(TIMESTAMP)`.

3. **Protection against overwriting active disks:**
   - When restoring a data disk snapshot, if `DATA_DISK_NAME` already exists in `ZONE`, `restore-snapshot` must warn and prompt before replacing it.
   - When restoring a boot disk snapshot, if `INSTANCE_NAME` is currently running, `restore-snapshot` must prompt to stop/down the existing VM first.
