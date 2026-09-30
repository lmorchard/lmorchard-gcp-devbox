# Research: Speed up VM bootstrap by pre-baking custom image with gcloud native tooling

## 1. Existing VM Provisioning and Bootstrap Flow
- `Makefile:126-149`: The `up` target runs `gcloud compute instances create $(INSTANCE_NAME)` with `--image-family=$(IMAGE_FAMILY)` and `--image-project=$(IMAGE_PROJECT)`, passing `metadata-from-file=startup-script=startup.sh`.
- `Makefile:12-13`: `IMAGE_FAMILY` defaults to `ubuntu-2404-lts-amd64` and `IMAGE_PROJECT` defaults to `ubuntu-os-cloud`.
- `Makefile:151-182`: `wait-ready` polls `gcloud compute instances get-guest-attributes $(INSTANCE_NAME) ... --query-path="devbox/stage"` until it equals `ready`.
- `startup.sh:22-28`: `set_stage` writes progress to guest attribute `devbox/stage`.

## 2. Startup Script Tasks & Latency Breakdown
In `startup.sh`:
- Lines 30-48: Base apt packages (`apt-get update`, `build-essential`, `tmux`, `zsh`, `jq`, `ripgrep`, etc.) - ~30-45s.
- Lines 49-60: User creation (`$DEV_USER`), sudoers, linger.
- Lines 62-85: Docker CE repository and package installation - ~30-45s.
- Lines 104-108: Tailscale installation - ~15s.
- Lines 113-120: GitHub CLI repo & installation - ~10s.
- Lines 130-146: Node.js LTS and Go compiler tarball download/install - ~30-40s.
- Lines 149-164: Agent CLIs (`@anthropic-ai/claude-code`, `@openai/codex`, `opencode`) - ~40-60s.
- Lines 166-174: Wideboi binary download and install - ~5s.
- Lines 176-265: Dotfiles, secrets, and environment setup (Ephemeral/runtime).
- Lines 267-324: Workspace repository cloning (Ephemeral/runtime).
- Lines 326-363: Wideboi systemd user service setup & start (Ephemeral/runtime).
- Lines 365-531: Idle watchdog script & systemd unit setup & start.
- Lines 533-548: Tailscale connection (`tailscale up`) (Ephemeral/runtime).

## 3. Builder Lifecycle Requirements
To bake an image using native `gcloud`:
- Spin up builder instance `devbox-builder` in `$(ZONE)` on `$(NETWORK)` / `$(SUBNET)`.
- Use stock Ubuntu 24.04 as builder base: `--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud`.
- Pass `scripts/bake.sh` as `startup-script`.
- Enable guest attributes: `--metadata=enable-guest-attributes=TRUE`.
- Wait for guest attribute `devbox/bake-status` to report `complete` (or `error`).
- Stop instance: `gcloud compute instances stop devbox-builder --zone=$(ZONE) --quiet`.
- Create image from disk: `gcloud compute images create devbox-base-$(date) --project=$(PROJECT_ID) --source-disk=devbox-builder --source-disk-zone=$(ZONE) --family=devbox-base`.
- Delete builder instance + disk: `gcloud compute instances delete devbox-builder --zone=$(ZONE) --quiet`.

## 4. Image Fallback and Auto-Detection
In `Makefile`:
- Check if image in family `devbox-base` exists:
  `gcloud compute images describe-from-family devbox-base --project=$(PROJECT_ID) --format="value(name)"`
- If exists and `USE_CUSTOM_IMAGE != false`, default `IMAGE_FAMILY = devbox-base` and `IMAGE_PROJECT = $(PROJECT_ID)`.
- If absent or disabled, fall back to `ubuntu-2404-lts-amd64` and `ubuntu-os-cloud`.

## 5. Image Cleanup / Pruning
- Target `make list-images` or `make clean-images`:
  - List all images in `devbox-base` family.
  - Delete older images keeping the latest, or prompt/clean them up.

## 6. Guards in `startup.sh`
- Ensure each static package/tool check (`command -v docker`, `command -v node`, `command -v go`, `command -v claude`, `command -v opencode`, `command -v wideboi`, `command -v gh`, `command -v tailscale`) skips installation if already installed on the pre-baked image, while ensuring that booting from a bare Ubuntu image still installs everything required.
