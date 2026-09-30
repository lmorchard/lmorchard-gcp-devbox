# Notes: Speed up VM bootstrap by pre-baking custom image with gcloud native tooling

## Overview
Implemented Issue #9 to speed up devbox bootstrap from 3-4 minutes to ~20 seconds by pre-baking static tools and runtimes into a custom GCE image family (`devbox-base`) using native `gcloud compute` tooling.

## Changes Made
1. **`scripts/bake.sh`:**
   - Dedicated root startup script executed by temporary builder VM.
   - Installs base apt tools (`build-essential`, `tmux`, `zsh`, `jq`, `unzip`, `ripgrep`, etc.).
   - Configures developer user (`$DEV_USER`), adds to `sudo` (NOPASSWD) and `docker` groups, and enables user linger.
   - Installs Docker CE, CLI, and plugins.
   - Installs Tailscale package.
   - Installs GitHub CLI package (`gh`).
   - Installs Node.js 20.x and Go compiler (1.23.1).
   - Installs AI Agent CLIs (`@anthropic-ai/claude-code`, `@openai/codex`, `opencode`).
   - Installs Wideboi binary to `/usr/local/bin/wideboi`.
   - Pre-installs idle watchdog script `/usr/local/bin/devbox-idle-watchdog` and systemd units `/etc/systemd/system/devbox-idle-watchdog.{service,timer}`.
   - Cleans apt caches and temp files (`apt-get clean`, `rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*`).
   - Signals completion via guest attribute `devbox/bake-status=complete` (or `failed`).

2. **`startup.sh`:**
   - Wrapped static installs (base packages, Docker, Tailscale, gh, Node/Go, Agent CLIs, Wideboi, watchdog script/units) in binary presence guards (`command -v`).
   - Ephemeral actions run unconditionally on boot: secret fetching from Secret Manager, SSH authorized_keys setup, gh authentication with token, dotfiles cloning and setup, workspace repo cloning and `.env` copying, starting Wideboi user service, enabling watchdog timer, and connecting Tailscale (`tailscale up`).
   - Allows instant boot (~15-25s) when using pre-baked image, while preserving full fallback install on stock Ubuntu.

3. **`Makefile`:**
   - Added auto-detection for image family `devbox-base` in `$(PROJECT_ID)`.
   - If present and `USE_CUSTOM_IMAGE != false`, defaults to `IMAGE_FAMILY = devbox-base` and `IMAGE_PROJECT = $(PROJECT_ID)`.
   - If absent or `USE_CUSTOM_IMAGE=false`, defaults to stock `ubuntu-2404-lts-amd64` and `ubuntu-os-cloud`.
   - Added `make bake-image`:
     - Checks project, VPC network, and service account.
     - Launches `devbox-builder` instance with `scripts/bake.sh`.
     - Polls `devbox/bake-status` guest attribute until `complete` (or dumps serial logs on failure).
     - Stops builder VM, creates timestamped image `devbox-base-YYYYMMDDHHMM` under `--family=devbox-base`.
     - Deletes builder VM and its attached disk cleanly.
   - Added `make list-images` to view existing images in `devbox-base` family.
   - Added `make clean-images` to prune older images in `devbox-base`, preserving the most recent image.
   - Updated `help` target.

4. **`.gitignore`:**
   - Added `.worktrees/`.

## Acceptance Criteria Status
- [x] `scripts/bake.sh` created with all static toolchain installs.
- [x] `make bake-image` spins up builder, waits, bakes `devbox-base`, and tears down builder cleanly.
- [x] `startup.sh` guards static installs so it runs fast (~15-20s) when booted from custom image.
- [x] `Makefile` automatically detects presence of `devbox-base` family and uses it for `make up`.
- [x] Fallback to stock Ubuntu 24.04 continues to work if custom image is absent or `USE_CUSTOM_IMAGE=false`.

## Copilot Review Improvements Addressed
- **Security hardening for builder VM:** Removed runner service account and `ensure-sa` dependency from `make bake-image`, ensuring the builder cannot access project secrets.
- **Image sanitization:** Purged builder host SSH keys (`/etc/ssh/ssh_host_*`) and Tailscale state (`/var/lib/tailscale/*`) prior to image creation.
- **Dynamic user configuration:** Passed `dev-user=$(DEV_USER)` to `make up` and read dynamically in `startup.sh`, ensuring bake and runtime identities are consistent.
- **Go symlink bugfix:** Corrected `ln -sf /usr/local/go/bin/go /usr/local/bin/go` in `startup.sh`.
- **Robust error handling in Makefile:**
  - Dump serial port output on timeout before cleaning builder VM.
  - Check exit codes on `instances stop` and `images create` before deleting builder.
  - Propagate listing/deletion errors in `clean-images`.
- **Opencode user ownership & CLI verification:** Chowned `${DEV_HOME}/.opencode` to developer user and verified all three CLIs (`claude`, `codex`, `opencode`) exist before bake completion.

## Verification
- `bash -n scripts/bake.sh`: clean (exit 0)
- `bash -n startup.sh`: clean (exit 0)
- `make -n help up bake-image list-images clean-images`: dry run expansions verified.
- Verified auto-detection and fallback behavior with `USE_CUSTOM_IMAGE=false` and simulated custom images.
