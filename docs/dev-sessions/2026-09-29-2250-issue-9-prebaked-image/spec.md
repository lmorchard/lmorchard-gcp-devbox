# Pre-Bake Custom VM Image with gcloud Native Tooling Spec

**Goal:** Speed up VM bootstrap from 3-4 minutes to under 30 seconds by pre-baking static dependencies into a `devbox-base` GCE image family using native gcloud tooling, while automatically falling back to stock Ubuntu 24.04 when no custom image is available.

**Source:** GitHub Issue #9 (https://github.com/lmorchard/lmorchard-gcp-devbox/issues/9)

## Current state
- `Makefile:126-149` (`make up`) launches an ephemeral VM directly from `ubuntu-2404-lts-amd64` in `ubuntu-os-cloud`.
- Every boot runs `startup.sh:30-174`, downloading and installing base apt packages, Docker CE, Tailscale, GitHub CLI, Node.js 20, Go 1.23, Claude Code, Codex, Opencode, and Wideboi from the internet.
- Total bootstrap takes ~3-4 minutes every time an instance is launched before Tailscale connects and services become ready.
- Static installs in `startup.sh` lack consistent presence guards (e.g. `@anthropic-ai/claude-code`, `@openai/codex`, `wideboi`, `tailscale` packages are installed unconditionally).

## Desired end state
1. **Dedicated bake script (`scripts/bake.sh`):**
   - Runs as root on a builder VM.
   - Installs all static prerequisites:
     - Developer user (`$DEV_USER`, defaults to `lmorchard`), sudoers NOPASSWD, linger.
     - Base packages (`apt-transport-https`, `ca-certificates`, `curl`, `gnupg`, `git`, `build-essential`, `tmux`, `zsh`, `jq`, `unzip`, `ripgrep`, `fd-find`, `htop`).
     - Docker CE, CLI, plugins, and adds `$DEV_USER` to `docker` group.
     - Tailscale package.
     - GitHub CLI package (`gh`).
     - Node.js LTS (20.x) and Go compiler (1.23.1).
     - Agent CLIs (`@anthropic-ai/claude-code`, `@openai/codex`, `opencode`).
     - Wideboi binary (`/usr/local/bin/wideboi`).
     - Idle watchdog script (`/usr/local/bin/devbox-idle-watchdog`) and systemd unit files (`devbox-idle-watchdog.service`, `devbox-idle-watchdog.timer`).
   - Cleans apt caches (`apt-get clean`, `rm -rf /var/lib/apt/lists/*`) and temporary directories.
   - Sets guest attribute `devbox/bake-status` to `complete` (or `failed`).

2. **Builder Lifecycle Target (`make bake-image`):**
   - Runs `check-project`, `ensure-network`.
   - Provisions a temporary builder VM (`devbox-builder`) in `$(ZONE)` using `ubuntu-2404-lts-amd64` and `scripts/bake.sh`.
   - Waits and tracks progress via guest attribute `devbox/bake-status` (and streams serial output on failure / timeout).
   - Once complete:
     - Stops the builder VM (`gcloud compute instances stop devbox-builder`).
     - Creates image `devbox-base-YYYYMMDDHHMM` with `--family=devbox-base` and `--source-disk=devbox-builder`.
     - Deletes the builder VM and its attached disk (`gcloud compute instances delete devbox-builder`).

3. **Fallback and Auto-Detection in `Makefile`:**
   - Detects if an image in family `devbox-base` exists in `$(PROJECT_ID)`.
   - If found and `USE_CUSTOM_IMAGE != false`, defaults `IMAGE_FAMILY` to `devbox-base` and `IMAGE_PROJECT` to `$(PROJECT_ID)`.
   - If no custom image exists or `USE_CUSTOM_IMAGE=false`, defaults to `ubuntu-2404-lts-amd64` and `ubuntu-os-cloud`.
   - Allows explicit overrides of `IMAGE_FAMILY` and `IMAGE_PROJECT`.

4. **Fast Startup in `startup.sh`:**
   - Adds presence guards around static tools (`docker`, `tailscale`, `node`, `go`, `claude`, `codex`, `opencode`, `wideboi`, `gh`, base packages).
   - When booted from a custom image, static installations are skipped, reducing `startup.sh` time to ~15-25 seconds (fetching secrets, configuring dotfiles, cloning workspace repos, starting Wideboi service, connecting Tailscale).
   - When booted from the stock Ubuntu image, the script completes all installations as before.

5. **Image Pruning Target (`make clean-images`):**
   - Lists all images in `devbox-base` family and deletes older images while keeping the latest image intact.

## Design decisions
- **Decision:** Use native `gcloud` VM creation + image creation rather than Packer or HashiCorp tools.
  - **Why:** Avoids external dependencies and keeps the developer experience pure Makefile + gcloud, consistent with the rest of this repo.
  - **Rejected:** Packer (unnecessary extra dependency/configuration for a single VM template).
- **Decision:** Use Google Guest Attributes (`devbox/bake-status`) for lifecycle handshake.
  - **Why:** Guest attributes are already used by `startup.sh` (`devbox/stage`) and allow clean programmatic polling from the host Makefile without requiring SSH or public network connectivity.
  - **Rejected:** Polling serial port output regex (less robust, prone to timing/buffering issues).
- **Decision:** Pre-install idle watchdog script and systemd units in the image, but enable/start the timer in `startup.sh`.
  - **Why:** Watchdog behavior depends on runtime metadata (`auto-stop-hours`), but the static unit and script files can be baked ahead of time.
  - **Rejected:** Creating units on every boot from scratch.
- **Decision:** Prune keeps the latest image in `devbox-base` family.
  - **Why:** Safe image management to prevent unbounded GCP storage costs while preventing accidental deletion of the active image.
  - **Rejected:** Deleting all images indiscriminately or requiring manual cloud console deletion.

## Patterns to follow
- Network & project checks: `Makefile:55-59` (`check-project`), `Makefile:82-110` (`ensure-network`).
- Guest attribute polling: `Makefile:151-182` (`wait-ready`).
- Guest attribute updating in bash: `startup.sh:22-28` (`set_stage`).
- Idle watchdog script: `scripts/devbox-idle-watchdog.sh`.

## What we're NOT doing
- We are NOT modifying the devcontainer configurations within workspace repositories.
- We are NOT baking secrets or credentials into the custom image (secrets remain strictly ephemeral via GCP Secret Manager fetched at boot).
- We are NOT changing the ephemeral VM behavior regarding workspace repos or dotfiles (dotfiles and repos are always freshly cloned at boot).
- We are NOT introducing Packer or third-party image-building frameworks.

## Open questions
- None. (Builder architecture, image naming, auto-detection logic, and acceptance criteria are fully specified).
