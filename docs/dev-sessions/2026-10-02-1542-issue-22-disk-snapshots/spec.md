# Instant Disk Snapshot & Restore Targets Spec

**Goal:** Enable lightweight, point-in-time disk snapshot and restore targets (`make snapshot`, `make list-snapshots`, `make restore-snapshot`, `make clean-snapshots`) for both ephemeral boot disks and persistent data disks, providing safety checkpoints and low-cost cold storage ($0.026/GB/mo).

**Source:** https://github.com/lmorchard/lmorchard-gcp-devbox/issues/22

## Current state
- The devbox supports ephemeral boot disks and optional persistent secondary data disks (`devbox-data`) (`Makefile:20-37`).
- While `make stop` pauses compute billing, persistent disks continue to incur full disk rates (~$0.10/GB/month).
- Tearing down an ephemeral VM destroys all boot disk modifications, kernel tweaks, or uncommitted files if a persistent disk is not enabled.
- There is currently no mechanism to freeze a point-in-time disk snapshot before risky work or to archive a workspace into GCP differential compressed cold storage (~$0.026/GB/month).

## Desired end state
Four new Makefile targets:
1. `make snapshot [NAME=custom-name] [DISK=auto|boot|data|all]`:
   - Takes differential compressed GCE snapshots of the specified disk(s).
   - If `DISK=auto` (default): snapshots `DATA_DISK_NAME` if attached; otherwise snapshots the boot disk `INSTANCE_NAME`.
   - Labels all created snapshots with `managed-by=devbox`, `instance=$(INSTANCE_NAME)`, `disk-type=boot|data`.
2. `make list-snapshots [ALL=1]`:
   - Displays a formatted table of snapshots (`name`, `sourceDisk`, `diskSizeGb`, `storageBytes`, `creationTimestamp`, `status`) filtered by `labels.managed-by=devbox` (or all project snapshots if `ALL=1`).
3. `make restore-snapshot SNAPSHOT=<snapshot-name>`:
   - Inspects the snapshot's metadata / labels:
     - If `disk-type=boot`: recreates the devbox instance booting directly from the snapshot via `--source-snapshot`. Prompts if an instance with that name is currently running.
     - If `disk-type=data`: recreates the secondary persistent data disk from `--source-snapshot` in `ZONE`. Prompts if `DATA_DISK_NAME` already exists.
4. `make clean-snapshots [KEEP=3] [FORCE=1]`:
   - Prunes older devbox-managed snapshots, keeping the `KEEP` most recent (default: 3). Prompts for confirmation unless `FORCE=1`.

## Design decisions
- **Decision:** Label snapshots with `managed-by=devbox` and `disk-type=boot|data`.
  - **Why:** Allows devbox commands (`list-snapshots`, `clean-snapshots`) to safely isolate and manage devbox snapshots without touching unrelated project disks, and allows `restore-snapshot` to auto-detect whether it is restoring a boot disk or a secondary data disk.
  - **Rejected:** Unlabeled snapshots (would require parsing naming strings or risk pruning external disks).

- **Decision:** Integrate boot snapshot restore directly into `do-up` via `SOURCE_SNAPSHOT`.
  - **Why:** Keeps `gcloud compute instances create` flags (network, service account, startup metadata, data disk attachment) uniform whether booting from an image or a snapshot.
  - **Rejected:** Separate duplicated `instance create` commands in Makefile for snapshot restores.

- **Decision:** Support `DISK=auto` defaulting to secondary data disk if enabled/attached, else boot disk.
  - **Why:** In persistent disk mode, user state lives on `DATA_DISK_NAME`. In ephemeral mode, user state lives on the boot disk. `DISK=auto` does what the user expects while still allowing explicit `DISK=boot` or `DISK=data`.

## Patterns to follow
- Pattern from `list-images` / `clean-images` (`Makefile:312-344`) for table formatting and timestamp-sorted pruning.
- Pattern from `ensure-data-disk` (`Makefile:211-229`) for disk creation and zone validation.
- Pattern from `delete-data-disk` (`Makefile:651-675`) for user confirmation prompts.

## What we're NOT doing
- We are NOT implementing scheduled/cron snapshot policies in this session (manual snapshot targets first).
- We are NOT uploading snapshot blobs outside GCP (native GCE snapshots are differential and multi-region resilient).
- We are NOT mutating running VM processes during snapshotting (GCE snapshots are non-disruptive).

## Open questions
- *Question:* Should `make snapshot` without arguments snapshot both disks if both boot and data disks are active?
  - *Default answer:* When `DISK=auto`, if both disks are present, snapshotting `DATA_DISK_NAME` is the default because it contains all user data, but `DISK=all` will snapshot both.
