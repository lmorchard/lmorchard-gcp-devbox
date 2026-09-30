# Pre-Bake Custom VM Image with gcloud Native Tooling Implementation Plan

**Goal:** Pre-bake static dependencies into a `devbox-base` GCP compute image family using native gcloud tooling to reduce VM bootstrap time from 3-4 minutes to under 30 seconds, while automatically falling back to stock Ubuntu when no custom image exists.

**Approach:**
- Dedicated `scripts/bake.sh` installs all static toolchains (base packages, Docker CE, Tailscale, GitHub CLI, Node, Go, agent CLIs, Wideboi, and idle watchdog) and signals completion via guest attribute `devbox/bake-status`.
- `startup.sh` guards static installs with binary presence checks (`command -v`), skipping them on pre-baked images while remaining fully functional on stock Ubuntu.
- `Makefile` adds `make bake-image`, `make clean-images`, `make list-images`, and auto-detects `devbox-base` image family for `make up`.

**Tech stack:** Bash, GNU Make, Google Cloud CLI (`gcloud compute`).

---

## Phase 1: Dedicated Builder Script (`scripts/bake.sh`)

Create `scripts/bake.sh` to install all static dependencies and configure the base image on a temporary builder instance.

**Files:**
- Create: `scripts/bake.sh`

**Key changes:**
- Installs base apt tools (`build-essential`, `tmux`, `zsh`, `jq`, `unzip`, `ripgrep`, `fd-find`, `htop`, etc.).
- Configures developer user `${DEV_USER}` (defaults to `lmorchard`), adds to `sudo` and `docker` groups, and sets NOPASSWD sudoers.
- Installs Docker CE, CLI, and plugins.
- Installs Tailscale package.
- Installs GitHub CLI (`gh`).
- Installs Node.js 20.x and Go compiler (1.23.1).
- Installs Agent CLIs (`@anthropic-ai/claude-code`, `@openai/codex`, `opencode`).
- Installs Wideboi binary to `/usr/local/bin/wideboi`.
- Installs idle watchdog script `/usr/local/bin/devbox-idle-watchdog` and systemd units `/etc/systemd/system/devbox-idle-watchdog.{service,timer}`.
- Cleans apt caches and `/tmp` before shutdown.
- Reports guest attribute `devbox/bake-status` to `complete` (or `error`).

```bash
set_bake_status() {
  local status="$1"
  curl -s -X PUT --data "${status}" \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/devbox/bake-status" 2>/dev/null || true
}
```

**Verification — automated:**
- [x] `bash -n scripts/bake.sh` passes without syntax errors — **verified with exit 0**
- [x] File has executable permissions (`chmod +x scripts/bake.sh`) — **verified (mode 0755)**

**Verification — manual:**
- [x] Inspect `scripts/bake.sh` to verify all static toolchains match `startup.sh` — **verified: user, docker, tailscale, gh, node, go, agent CLIs, wideboi, idle watchdog, apt cache clean**

---

## Phase 2: Presence Guards in `startup.sh` for Fast Boot

Refactor `startup.sh` so static tool installations are skipped when the binaries already exist.

**Files:**
- Modify: `startup.sh`

**Key changes:**
- Guard base package installation with `if ! command -v git >/dev/null 2>&1 || ! command -v zsh >/dev/null 2>&1; then ... fi`.
- Guard Docker installation with `if ! command -v docker >/dev/null 2>&1; then ... fi`.
- Guard Tailscale package installation with `if ! command -v tailscale >/dev/null 2>&1; then ... fi`.
- Guard GitHub CLI installation (already guarded with `command -v gh`).
- Guard Node.js and Go compiler installs (already guarded with `command -v node` and `command -v go`).
- Guard Agent CLIs with `command -v claude`, `command -v codex`, `command -v opencode`.
- Guard Wideboi binary install with `if [[ ! -x /usr/local/bin/wideboi ]]; then ... fi`.
- Guard devbox-idle-watchdog script and systemd units creation if `/usr/local/bin/devbox-idle-watchdog` already exists.
- Retain all runtime/ephemeral steps: Secret Manager fetching, authorized_keys, dotfiles, workspace cloning, wideboi user service startup, watchdog timer activation, and `tailscale up`.

**Verification — automated:**
- [x] `bash -n startup.sh` passes without syntax errors — **verified with exit 0**

**Verification — manual:**
- [x] Review diff to confirm all ephemeral steps run unconditionally and only static installs are guarded — **verified: secrets, authorized_keys, gh auth, dotfiles, workspace repos, wideboi user service, watchdog timer, tailscale up run unconditionally**

---

## Phase 3: Image Auto-Detection, Builder Target & Pruning in `Makefile`

Add image auto-detection, `make bake-image`, `make list-images`, and `make clean-images` to `Makefile`.

**Files:**
- Modify: `Makefile`
- Modify: `.gitignore` — ensure `.worktrees/` is tracked in gitignore

**Key changes:**
- Auto-detect `devbox-base` family in `$(PROJECT_ID)`.
- If found and `USE_CUSTOM_IMAGE != false`, default `IMAGE_FAMILY = devbox-base` and `IMAGE_PROJECT = $(PROJECT_ID)`.
- Fall back to `ubuntu-2404-lts-amd64` / `ubuntu-os-cloud`.
- Target `bake-image`:
  - Spins up `devbox-builder` VM.
  - Monitors `devbox/bake-status` guest attribute.
  - Stops VM, creates timestamped image under `devbox-base` family, and cleans up builder VM.
- Target `list-images`:
  - Formats and displays all images under `devbox-base` family.
- Target `clean-images`:
  - Lists older images in `devbox-base` family and deletes all except the most recent.
- Update `help` target to document new commands.

```makefile
CUSTOM_IMAGE_EXISTS := $(shell gcloud compute images describe-from-family devbox-base --project=$(PROJECT_ID) --format="value(name)" 2>/dev/null)
```

**Verification — automated:**
- [x] `make -n up` expands cleanly — **verified: expands with auto-detection of devbox-base and fallback to ubuntu-2404-lts-amd64**
- [x] `make -n bake-image` expands cleanly — **verified: expands builder VM launch, status polling, stop, image creation, and cleanup**
- [x] `make -n list-images` expands cleanly — **verified: runs gcloud compute images list formatted table**
- [x] `make -n clean-images` expands cleanly — **verified: prunes older images while keeping latest**

**Verification — manual:**
- [x] Run `make help` and verify new commands are documented — **verified: help output displays make bake-image, make list-images, make clean-images**

---

## Phase 4: Verification and Review

End-to-end verification of scripts and Makefile logic.

**Files:**
- Modify: `docs/dev-sessions/2026-09-29-2250-issue-9-prebaked-image/notes.md`

**Verification — automated:**
- [x] `bash -n scripts/bake.sh` — **verified with exit 0**
- [x] `bash -n startup.sh` — **verified with exit 0**
- [x] `make -n help up bake-image list-images clean-images` — **verified with exit 0**

**Verification — manual:**
- [x] Inspect git diff across all modified files — **verified all diffs clean and scoped**
