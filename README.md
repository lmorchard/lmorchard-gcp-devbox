# lmorchard-gcp-devbox

A lightweight, 100% ephemeral yet reproducible development VM in Google Cloud Platform (GCP) for running [wideboi](https://github.com/lmorchard/wideboi), Claude Code, Opencode, and Codex in detached sessions.

Accessed securely via **Tailscale** (no public IP, no firewall ports opened). Disposing the VM drops your GCP billing to literal **$0.00**.

## Architecture & Features

- **Disposable & Recreatable**: Run `make up` to launch and bootstrap in ~2 minutes; run `make down` when finished.
- **Tailscale SSH & Web Access**: Automatically registers on your tailnet with hostname `wideboi-sandbox` and Tailscale SSH enabled.
- **Wideboi Background Server**: Configured as a persistent systemd user service (`loginctl enable-linger` enabled) with websocket web UI exposed on port 8080 over Tailscale.
- **Dotfiles & Shell**: Automatically clones and links [lmorchard/dotfiles](https://github.com/lmorchard/dotfiles) with oh-my-zsh and zsh shell.
- **Secrets Management**: Pulls Tailscale auth keys, GitHub PAT, and agent keys securely on boot from GCP Secret Manager via instance service account.
- **Docker CE**: Configured and enabled on boot, with the non-root developer user added to the `docker` group.
- **Google Cloud & Evaluation Toolchain**: Pre-installed `gcloud` CLI, `kubectl`, `gke-gcloud-auth-plugin`, `kind`, Terraform 1.15.2, Argo CLI 4.1.4, `yq`, Node.js 22.16.0, and Python dev tooling.
- **Workspace Auto-Setup**: Automatically runs `script/setup`, `setup.sh`, or `make setup` in cloned workspace repos.
- **Rolling Wideboi**: Automatically pulls the latest Linux amd64 rolling release binary directly from GitHub.

## Prerequisites

1. `gcloud` CLI installed and authenticated (`gcloud auth login`).
2. A GCP project set as active:
   ```bash
   gcloud config set project <YOUR_PROJECT_ID>
   ```
3. A Tailscale account.

## Setup & Usage

### 1. Configuration & Secrets

1. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```
2. Fill in your project ID, Tailscale auth key, GitHub PAT, and any agent keys in `.env`.
3. (Optional) Define repositories to pre-clone:
   Copy `workspace/repos.txt.example` to `workspace/repos.txt` and list the repos you want cloned to `~/devel/`:
   ```text
   lmorchard/wideboi
   my-org/my-project
   ```
   To associate a `.env` file with a repo, put it in `workspace/envs/<repo-name>.env` (e.g. `workspace/envs/wideboi.env`). It will automatically be copied into `~/devel/wideboi/.env` on boot! All `.env` files in this directory are gitignored.

4. Upload the secrets to GCP Secret Manager:
   ```bash
   make init-secrets
   ```
   (Note: `make up` also runs this automatically).

### 2. Launch the VM
```bash
make up
```
This creates the service account with required IAM roles and spins up an `e2-standard-4` Ubuntu 24.04 instance.

### 3. Connect

- **SSH (via Tailscale SSH)**:
  ```bash
  make ssh
  # or directly:
  ssh lmorchard@wideboi-sandbox
  ```
- **Wideboi Web UI**:
  ```bash
  make web
  # or open in browser:
  http://wideboi-sandbox:8080
  ```
- **Hot-Upgrade Wideboi**:
  ```bash
  make upgrade-wideboi
  ```
  Pulls the latest rolling build from GitHub and runs `wideboi upgrade-server` in-place without closing panes or interrupting active agent sessions.
- **Live Secret Syncing**:
  ```bash
  make sync-secrets
  ```
  Pushes updated values from `.env` (API keys, GitHub PAT, Tailscale keys, config files) to GCP Secret Manager and applies them directly to the active running VM without requiring a reboot.
- **View Startup Progress**:
  ```bash
  make logs
  ```

- **Automated Idle Auto-Stop**:
  The VM runs a systemd idle watchdog (`devbox-idle-watchdog`) checking:
  - Active interactive SSH logins
  - Connected Wideboi web or terminal clients
  - Active child processes under agents (`claude`, `opencode`, `codex`)
  - Recent file writes in agent session and history directories
  - CPU load thresholds
  If the machine is completely inactive for `AUTO_STOP_HOURS` (default: 2 hours), it calls `systemctl poweroff` to stop compute and IP billing while preserving disk state. Set `AUTO_STOP_HOURS=0` in `.env` to disable.

### 4. Stopping / Teardown

- **Pause VM (Temporary stop, disk remains, compute billing stops)**:
  ```bash
  make stop
  make start
  ```

- **Resize VM (In-place or Pre-launch)**:
  ```bash
  # Quick presets:
  make resize-low    # e2-standard-4 (4 vCPU, 16 GB RAM)
  make resize-med    # e2-standard-8 (8 vCPU, 32 GB RAM) - default
  make resize-high   # e2-standard-16 (16 vCPU, 64 GB RAM)

  # Custom machine type:
  make resize TYPE=c3d-standard-16
  ```
  *(Updates `.env`. If the VM is currently running, it cleanly stops the instance, sets the new machine type, and restarts it with Tailscale reconnection).*

- **Destroy VM (Drops running costs to $0.00)**:
  ```bash
  make down
  ```

- **Complete Project Cleanup (Tears down VM, VPC network, subnet, and runner service account)**:
  ```bash
  make destroy-infra
  ```

## Configuration

Copy `.env.example` to `.env` (which is gitignored) to customize any settings:
```bash
cp .env.example .env
```
Example `.env`:
```bash
PROJECT_ID=my-sandbox-project
ZONE=us-central1-a
MACHINE_TYPE_LOW=e2-standard-4
MACHINE_TYPE_MED=e2-standard-8
MACHINE_TYPE_HIGH=e2-standard-16
MACHINE_TYPE=e2-standard-8
BOOT_DISK_SIZE=50GB
DEV_USER=lmorchard
TAILSCALE_HOSTNAME=wideboi-sandbox
```
