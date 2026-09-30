#!/usr/bin/env bash
#
# bake.sh: Builder script for pre-baking devbox-base GCE image.
# Runs as root on a temporary builder VM.
# Installs base OS packages, Docker CE, Tailscale, GitHub CLI,
# Node.js LTS, Go compiler, AI agent CLIs, Wideboi binary,
# and idle watchdog units.
#
set -euo pipefail

LOG_FILE="/var/log/bake-script.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "================================================================"
echo "Starting Devbox Image Bake: $(date -u)"
echo "================================================================"

export DEBIAN_FRONTEND=noninteractive

# Helper to report status and stage progress to instance guest attributes
set_bake_status() {
  local status="$1"
  echo "==> BAKE STATUS: ${status}"
  curl -s -X PUT --data "${status}" \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/devbox/bake-status" 2>/dev/null || true
}

set_bake_stage() {
  local stage="$1"
  echo "==> BAKE STAGE: ${stage}"
  curl -s -X PUT --data "${stage}" \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/devbox/bake-stage" 2>/dev/null || true
}

trap 'set_bake_status "failed"' ERR

set_bake_status "running"

# Determine target developer user
DEV_USER=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/dev-user" 2>/dev/null || echo "lmorchard")
DEV_USER="${DEV_USER:-lmorchard}"
DEV_HOME="/home/${DEV_USER}"

# 1. Base packages
set_bake_stage "installing-base-packages"
echo "==> [1/10] Installing base apt packages..."
apt-get update -y
apt-get install -y --no-install-recommends \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  git \
  build-essential \
  tmux \
  zsh \
  jq \
  unzip \
  ripgrep \
  fd-find \
  htop \
  xz-utils \
  python3-pip \
  python3-venv \
  yamllint

# 2. Configure developer user
set_bake_stage "configuring-user"
echo "==> [2/10] Configuring user '${DEV_USER}'..."
if ! id -u "${DEV_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/zsh "${DEV_USER}"
fi
usermod -aG sudo "${DEV_USER}"
echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${DEV_USER}"
chmod 0440 "/etc/sudoers.d/90-${DEV_USER}"
loginctl enable-linger "${DEV_USER}"

# 3. Docker Installation
set_bake_stage "installing-docker"
echo "==> [3/10] Installing Docker CE..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y --no-install-recommends \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

groupadd -f docker
usermod -aG docker "${DEV_USER}"
systemctl enable docker

# 4. Google Cloud CLI, GKE Auth Plugin, & Kubectl
if ! command -v gcloud >/dev/null 2>&1 || ! command -v kubectl >/dev/null 2>&1 || ! command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
  set_bake_stage "installing-gcloud-and-k8s"
  echo "==> Installing Google Cloud CLI, GKE Auth Plugin, and Kubectl..."
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/cloud.google.gpg ]]; then
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg
    chmod a+r /etc/apt/keyrings/cloud.google.gpg
  fi
  if [[ ! -f /etc/apt/sources.list.d/google-cloud-sdk.list ]]; then
    echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null
  fi
  apt-get update -y
  apt-get install -y google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin kubectl
fi

# 5. Tailscale package installation
set_bake_stage "installing-tailscale"
echo "==> [4/10] Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable tailscaled

# 5. GitHub CLI
set_bake_stage "installing-github-cli"
echo "==> [5/10] Installing GitHub CLI..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt-get update -y
apt-get install -y gh

# 6. Install Node.js 22.16.0 & Go
set_bake_stage "installing-node-and-go"
echo "==> [6/10] Installing Node.js 22.16.0 and Go..."
NODE_TARGET_VERSION="22.16.0"
curl -fsSL "https://nodejs.org/dist/v${NODE_TARGET_VERSION}/node-v${NODE_TARGET_VERSION}-linux-x64.tar.xz" -o /tmp/node.tar.xz
tar -C /usr/local --strip-components=1 -xJf /tmp/node.tar.xz
rm -f /tmp/node.tar.xz

GO_VERSION="1.23.1"
curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
tar -C /usr/local -xzf /tmp/go.tar.gz
rm -f /tmp/go.tar.gz
ln -sf /usr/local/go/bin/go /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# 7. Install Agent Toolchains (Claude Code, Codex, Opencode)
set_bake_stage "installing-agent-clis"
echo "==> [7/10] Installing Agent CLIs..."
mkdir -p /usr/local/lib/node_modules
chown -R "${DEV_USER}:${DEV_USER}" /usr/local/lib/node_modules /usr/local/bin
sudo -u "${DEV_USER}" npm install -g @anthropic-ai/claude-code
sudo -u "${DEV_USER}" npm install -g @openai/codex

HOME="${DEV_HOME}" SHELL="/bin/zsh" curl -fsSL https://opencode.ai/install | HOME="${DEV_HOME}" SHELL="/bin/zsh" bash || true
if [[ -f "${DEV_HOME}/.opencode/bin/opencode" ]]; then
  install -m 0755 "${DEV_HOME}/.opencode/bin/opencode" /usr/local/bin/opencode
elif [[ -f "/root/.opencode/bin/opencode" ]]; then
  install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode
fi

# Ensure user owns their ~/.opencode files
if [[ -d "${DEV_HOME}/.opencode" ]]; then
  chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.opencode"
fi

# Verify critical CLIs are installed
if ! command -v claude >/dev/null 2>&1 || ! command -v codex >/dev/null 2>&1 || ! command -v opencode >/dev/null 2>&1; then
  echo "❌ Error: One or more agent CLIs failed to install."
  command -v claude || echo "  - Missing: claude"
  command -v codex || echo "  - Missing: codex"
  command -v opencode || echo "  - Missing: opencode"
  exit 1
fi

# 8. Install Wideboi binary
set_bake_stage "installing-wideboi"
echo "==> [8/10] Installing Wideboi rolling release..."
WIDEBOI_RELEASE_URL="https://github.com/lmorchard/wideboi/releases/download/rolling/wideboi_rolling_linux_amd64.tar.gz"
mkdir -p /tmp/wideboi-install
curl -fsSL "${WIDEBOI_RELEASE_URL}" -o /tmp/wideboi-install/wideboi.tar.gz
tar -C /tmp/wideboi-install -xzf /tmp/wideboi-install/wideboi.tar.gz
install -m 0755 /tmp/wideboi-install/wideboi /usr/local/bin/wideboi
rm -rf /tmp/wideboi-install

# 8b. Install Cloud & Evaluation Tools (Terraform 1.15.2, Argo CLI 4.1.4, yq, fuzzfetch)
set_bake_stage "installing-eval-tools"
echo "==> Installing Terraform 1.15.2..."
TERRAFORM_VERSION="1.15.2"
curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip
unzip -q -o /tmp/terraform.zip -d /usr/local/bin
rm -f /tmp/terraform.zip
chmod 0755 /usr/local/bin/terraform

echo "==> Installing Argo CLI 4.1.4..."
ARGO_VERSION="v4.1.4"
curl -fsSL "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/argo-linux-amd64.gz" -o /tmp/argo.gz
gunzip -f /tmp/argo.gz
install -m 0755 /tmp/argo /usr/local/bin/argo
rm -f /tmp/argo

echo "==> Installing yq..."
curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq
chmod 0755 /usr/local/bin/yq

echo "==> Installing kind..."
KIND_VERSION="v0.33.0"
curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" -o /tmp/kind
install -m 0755 /tmp/kind /usr/local/bin/kind
rm -f /tmp/kind

echo "==> Installing python evaluation tools (fuzzfetch, pytest, pyyaml)..."
pip install --break-system-packages pytest PyYAML fuzzfetch || true

# 9. Install idle watchdog script and systemd units
set_bake_stage "installing-idle-watchdog"
echo "==> [9/10] Installing idle watchdog script and units..."
cat <<'EOF' > /usr/local/bin/devbox-idle-watchdog
#!/usr/bin/env bash
set -euo pipefail

DEV_USER="${DEV_USER:-lmorchard}"
DEV_HOME="/home/${DEV_USER}"
STATE_FILE="/var/run/devbox-idle-state"

export HOME="${DEV_HOME}"

if [[ -f "${DEV_HOME}/.profile.d/agent-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "${DEV_HOME}/.profile.d/agent-env.sh"
fi

AUTO_STOP_HOURS="${AUTO_STOP_HOURS:-2}"

if [[ "${AUTO_STOP_HOURS}" -le 0 ]]; then
  exit 0
fi

IDLE_LIMIT_SECONDS=$(( AUTO_STOP_HOURS * 3600 ))
NOW=$(date +%s)

log() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [devbox-idle-watchdog] $*"
  logger -t devbox-idle-watchdog "$*"
}

is_active=0
active_reasons=()

# 1. Interactive SSH logins
if who | grep -q 'pts/'; then
  is_active=1
  active_reasons+=("interactive-ssh-session")
fi

# 2 & 3. Wideboi status
DEV_UID=$(id -u "${DEV_USER}" 2>/dev/null || echo 1000)
WB_SOCK="/tmp/wideboi-${DEV_UID}/default.sock"

if [[ -S "${WB_SOCK}" ]] && command -v wideboi >/dev/null 2>&1; then
  WB_CLIENTS=$(sudo -u "${DEV_USER}" wideboi -s "${WB_SOCK}" status --traffic --json 2>/dev/null | jq -r '.clients | length' 2>/dev/null || echo 0)
  if [[ "${WB_CLIENTS}" -gt 0 ]]; then
    is_active=1
    active_reasons+=("wideboi-clients-connected:${WB_CLIENTS}")
  fi

  WB_WORKING_PANES=$(sudo -u "${DEV_USER}" wideboi -s "${WB_SOCK}" status --json 2>/dev/null | jq -r '[.pane_statuses[] | select(. == "working")] | length' 2>/dev/null || echo 0)
  if [[ "${WB_WORKING_PANES}" -gt 0 ]]; then
    is_active=1
    active_reasons+=("wideboi-panes-working:${WB_WORKING_PANES}")
  fi
fi

# 4. Agent child processes
AGENT_PIDS=$(pgrep -u "${DEV_USER}" -f 'claude|opencode|codex' 2>/dev/null || true)
if [[ -n "${AGENT_PIDS}" ]]; then
  for apid in ${AGENT_PIDS}; do
    CHILD_COUNT=$(pgrep -P "${apid}" 2>/dev/null | wc -l || true)
    CHILD_COUNT=$(echo "${CHILD_COUNT}" | tr -d ' ')
    if [[ -n "${CHILD_COUNT}" && "${CHILD_COUNT}" -gt 0 ]]; then
      CHILDREN_NAMES=$(pgrep -P "${apid}" -a 2>/dev/null | head -n 3 | tr '\n' '; ' || true)
      is_active=1
      active_reasons+=("agent-children-active:[${CHILDREN_NAMES}]")
      break
    fi
  done
fi

# 5. Recent file writes in agent directories
AGENT_DIRS=(
  "${DEV_HOME}/.claude/sessions"
  "${DEV_HOME}/.claude/history.jsonl"
  "${DEV_HOME}/.codex/sessions"
  "${DEV_HOME}/.local/share/opencode"
)

for adir in "${AGENT_DIRS[@]}"; do
  if [[ -e "${adir}" ]]; then
    RECENT_MODS=$(find "${adir}" -maxdepth 2 -mmin -15 2>/dev/null | head -n 1)
    if [[ -n "${RECENT_MODS}" ]]; then
      is_active=1
      active_reasons+=("recent-agent-file-writes:${adir}")
      break
    fi
  fi
done

# 6. CPU load
LOAD_1MIN=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0.0")
LOAD_INT=$(echo "${LOAD_1MIN}" | awk '{print int($1 * 100)}')
if [[ "${LOAD_INT}" -ge 50 ]]; then
  is_active=1
  active_reasons+=("cpu-load:${LOAD_1MIN}")
fi

# Evaluate
if [[ "${is_active}" -eq 1 ]]; then
  echo "${NOW}" > "${STATE_FILE}"
  log "System ACTIVE: ${active_reasons[*]} (resetting idle timer)"
  exit 0
fi

if [[ ! -f "${STATE_FILE}" ]]; then
  echo "${NOW}" > "${STATE_FILE}"
  log "System IDLE detected. Initialized idle timer."
  exit 0
fi

LAST_ACTIVE=$(cat "${STATE_FILE}" 2>/dev/null || echo "${NOW}")
IDLE_SECONDS=$(( NOW - LAST_ACTIVE ))
IDLE_HOURS_FORMAT=$(awk -v s="${IDLE_SECONDS}" 'BEGIN {printf "%.1f", s / 3600}')

log "System IDLE for ${IDLE_SECONDS}s (~${IDLE_HOURS_FORMAT}h / limit: ${AUTO_STOP_HOURS}h)"

if [[ "${IDLE_SECONDS}" -ge "${IDLE_LIMIT_SECONDS}" ]]; then
  log "🚨 IDLE LIMIT REACHED (${IDLE_HOURS_FORMAT}h >= ${AUTO_STOP_HOURS}h). Powering off instance..."
  rm -f "${STATE_FILE}"
  sync
  systemctl poweroff
fi
EOF

chmod 0755 /usr/local/bin/devbox-idle-watchdog

cat <<'EOF' > /etc/systemd/system/devbox-idle-watchdog.service
[Unit]
Description=Devbox Idle Auto-Stop Watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/devbox-idle-watchdog
StandardOutput=journal
StandardError=journal
EOF

cat <<'EOF' > /etc/systemd/system/devbox-idle-watchdog.timer
[Unit]
Description=Run Devbox Idle Watchdog periodically
After=network.target

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

# 10. Clean host keys, Tailscale state, apt caches, and temp files to keep image clean and small
set_bake_stage "cleaning-caches"
echo "==> [10/10] Cleaning caches, SSH host keys, Tailscale state, and temporary files..."
rm -f /etc/ssh/ssh_host_*
rm -rf /var/lib/tailscale/*
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/*

echo "================================================================"
echo "Devbox Image Bake Finished Successfully: $(date -u)"
echo "================================================================"

set_bake_stage "complete"
set_bake_status "complete"
