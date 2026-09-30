#!/usr/bin/env bash
#
# startup.sh: GCP Compute Engine metadata startup script.
# Runs as root on instance boot. Installs dependencies, configures
# user account, fetches secrets, mounts Tailscale, sets up dotfiles,
# installs agent CLIs, and launches Wideboi as a user service.
#
set -euo pipefail

DEV_USER=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/dev-user" 2>/dev/null || echo "lmorchard")
DEV_USER="${DEV_USER:-lmorchard}"
DEV_HOME="/home/${DEV_USER}"
LOG_FILE="/var/log/startup-script.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "================================================================"
echo "Starting Devbox Bootstrap: $(date -u)"
echo "================================================================"

export DEBIAN_FRONTEND=noninteractive

# Helper to report progress to instance guest attributes
set_stage() {
  local stage="$1"
  echo "==> STAGE: ${stage}"
  curl -s -X PUT --data "${stage}" \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/devbox/stage" 2>/dev/null || true
}

set_stage "booting"

TAILSCALE_HOSTNAME=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/tailscale-hostname" 2>/dev/null || true)
if [[ -z "${TAILSCALE_HOSTNAME}" ]]; then
  TAILSCALE_HOSTNAME=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/name" 2>/dev/null || echo "wideboi-sandbox")
fi
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-wideboi-sandbox}"

# 1. Base packages
if ! command -v git >/dev/null 2>&1 || ! command -v zsh >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
  set_stage "installing-base-packages"
  echo "==> [1/9] Installing base apt packages..."
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
else
  echo "==> [1/9] Base apt packages already installed."
fi

# 2. Ensure user exists with zsh shell and sudo rights
echo "==> [2/9] Configuring user '${DEV_USER}'..."
if ! id -u "${DEV_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/zsh "${DEV_USER}"
fi
usermod -aG sudo "${DEV_USER}"
if [[ ! -f "/etc/sudoers.d/90-${DEV_USER}" ]]; then
  echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${DEV_USER}"
  chmod 0440 "/etc/sudoers.d/90-${DEV_USER}"
fi

# Enable systemd user lingering so user services/tmux stay alive after logout
loginctl enable-linger "${DEV_USER}"

# 3. Google Cloud CLI, GKE Auth Plugin, & Kubectl
if ! command -v gcloud >/dev/null 2>&1 || ! command -v kubectl >/dev/null 2>&1 || ! command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
  set_stage "installing-gcloud-and-k8s"
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
else
  echo "==> Google Cloud CLI, GKE Auth Plugin, and Kubectl already installed."
fi

# Configure default gcloud project for dev user if available
GCP_PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id" 2>/dev/null || true)
if [[ -n "${GCP_PROJECT_ID}" ]]; then
  sudo -u "${DEV_USER}" gcloud config set project "${GCP_PROJECT_ID}" 2>/dev/null || true
fi

# 4. Docker Installation
if ! command -v docker >/dev/null 2>&1; then
  set_stage "installing-docker"
  echo "==> Installing Docker CE..."
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
else
  echo "==> Docker CE already installed."
fi

# Ensure docker group exists and user is added
groupadd -f docker
usermod -aG docker "${DEV_USER}"
systemctl enable --now docker

# 4. Helper to fetch secrets from Secret Manager
get_secret() {
  local secret_name="$1"
  gcloud secrets versions access latest --secret="${secret_name}" 2>/dev/null || true
}

# 3b. Install SSH public key if provided
SSH_PUBKEY=$(get_secret "devbox-ssh-pubkey")
if [[ -n "${SSH_PUBKEY}" ]]; then
  echo "==> Configuring authorized_keys for '${DEV_USER}'..."
  mkdir -p "${DEV_HOME}/.ssh"
  echo "${SSH_PUBKEY}" >> "${DEV_HOME}/.ssh/authorized_keys"
  chmod 700 "${DEV_HOME}/.ssh"
  chmod 600 "${DEV_HOME}/.ssh/authorized_keys"
  chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.ssh"
fi

# 4. Tailscale Setup
if ! command -v tailscale >/dev/null 2>&1; then
  set_stage "installing-tailscale"
  echo "==> [3/9] Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "==> [3/9] Tailscale package already installed."
fi
systemctl enable --now tailscaled

TS_AUTHKEY=$(get_secret "tailscale-auth-key")

# 5. GitHub CLI & Auth
if ! command -v gh >/dev/null 2>&1; then
  set_stage "installing-github-cli"
  echo "==> [4/9] Installing GitHub CLI..."
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  apt-get update -y
  apt-get install -y gh
fi

GH_PAT=$(get_secret "github-pat")
if [[ -n "${GH_PAT}" ]]; then
  echo "==> Authenticating gh CLI..."
  echo "${GH_PAT}" | sudo -u "${DEV_USER}" gh auth login --with-token || true
  sudo -u "${DEV_USER}" gh auth setup-git || true
fi

# 6. Install Node.js & Go
NODE_TARGET_VERSION="22.16.0"
NODE_CURRENT_VERSION=""
if command -v node >/dev/null 2>&1; then
  NODE_CURRENT_VERSION=$(node -v | sed 's/^v//')
fi
if [[ "${NODE_CURRENT_VERSION}" != "${NODE_TARGET_VERSION}" ]] || ! command -v go >/dev/null 2>&1; then
  set_stage "installing-node-and-go"
  echo "==> [5/9] Installing Node.js ${NODE_TARGET_VERSION} and Go..."
  # Pin Node.js to 22.16.0 (required by local Argo proofs & CI)
  if [[ "${NODE_CURRENT_VERSION}" != "${NODE_TARGET_VERSION}" ]]; then
    curl -fsSL "https://nodejs.org/dist/v${NODE_TARGET_VERSION}/node-v${NODE_TARGET_VERSION}-linux-x64.tar.xz" -o /tmp/node.tar.xz
    tar -C /usr/local --strip-components=1 -xJf /tmp/node.tar.xz
    rm -f /tmp/node.tar.xz
  fi

  # Go (latest stable via snap or tarball)
  if ! command -v go >/dev/null 2>&1; then
    GO_VERSION="1.23.1"
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  fi
else
  echo "==> [5/9] Node.js and Go already installed."
fi

# 7. Install Agent Toolchains (Claude Code, Opencode, Codex)
if ! command -v claude >/dev/null 2>&1 || ! command -v codex >/dev/null 2>&1 || ! command -v opencode >/dev/null 2>&1; then
  set_stage "installing-agent-clis"
  echo "==> [6/9] Installing Agent CLIs..."
  # Claude Code CLI
  if ! command -v claude >/dev/null 2>&1; then
    npm install -g @anthropic-ai/claude-code || true
  fi

  # Codex CLI
  if ! command -v codex >/dev/null 2>&1; then
    npm install -g @openai/codex || true
  fi

  # Opencode CLI (official installer)
  if ! command -v opencode >/dev/null 2>&1; then
    HOME="${DEV_HOME}" SHELL="/bin/zsh" curl -fsSL https://opencode.ai/install | HOME="${DEV_HOME}" SHELL="/bin/zsh" bash || true
    if [[ -f "${DEV_HOME}/.opencode/bin/opencode" ]]; then
      install -m 0755 "${DEV_HOME}/.opencode/bin/opencode" /usr/local/bin/opencode
    elif [[ -f "/root/.opencode/bin/opencode" ]]; then
      install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode
    fi
  fi
else
  echo "==> [6/9] Agent CLIs already installed."
fi

# 8. Install Wideboi (latest rolling release)
if [[ ! -x /usr/local/bin/wideboi ]]; then
  set_stage "installing-wideboi"
  echo "==> [7/9] Downloading and installing Wideboi rolling release..."
  WIDEBOI_RELEASE_URL="https://github.com/lmorchard/wideboi/releases/download/rolling/wideboi_rolling_linux_amd64.tar.gz"
  mkdir -p /tmp/wideboi-install
  curl -fsSL "${WIDEBOI_RELEASE_URL}" -o /tmp/wideboi-install/wideboi.tar.gz
  tar -C /tmp/wideboi-install -xzf /tmp/wideboi-install/wideboi.tar.gz
  install -m 0755 /tmp/wideboi-install/wideboi /usr/local/bin/wideboi
  rm -rf /tmp/wideboi-install
else
  echo "==> [7/9] Wideboi already installed."
fi

# 8b. Install Cloud & Evaluation Tools (Terraform 1.15.2, Argo CLI 4.1.4, yq, fuzzfetch)
if ! command -v terraform >/dev/null 2>&1; then
  set_stage "installing-terraform"
  echo "==> Installing Terraform 1.15.2..."
  TERRAFORM_VERSION="1.15.2"
  curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip
  unzip -q -o /tmp/terraform.zip -d /usr/local/bin
  rm -f /tmp/terraform.zip
  chmod 0755 /usr/local/bin/terraform
fi

if ! command -v argo >/dev/null 2>&1; then
  set_stage "installing-argo-cli"
  echo "==> Installing Argo CLI 4.1.4..."
  ARGO_VERSION="v4.1.4"
  curl -fsSL "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/argo-linux-amd64.gz" -o /tmp/argo.gz
  gunzip -f /tmp/argo.gz
  install -m 0755 /tmp/argo /usr/local/bin/argo
  rm -f /tmp/argo
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "==> Installing yq..."
  curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq
  chmod 0755 /usr/local/bin/yq
fi

if ! command -v kind >/dev/null 2>&1; then
  set_stage "installing-kind"
  echo "==> Installing kind..."
  KIND_VERSION="v0.33.0"
  curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" -o /tmp/kind
  install -m 0755 /tmp/kind /usr/local/bin/kind
  rm -f /tmp/kind
fi

if ! command -v fuzzfetch >/dev/null 2>&1; then
  echo "==> Installing python evaluation tools (fuzzfetch, pytest, pyyaml)..."
  pip install --break-system-packages pytest PyYAML fuzzfetch || true
fi

# 9. Set up User Dotfiles and Shell
set_stage "setting-up-dotfiles"
echo "==> [8/9] Setting up dotfiles and user environment..."
sudo -u "${DEV_USER}" bash -c "
  set -e
  # Clone oh-my-zsh if missing
  if [[ ! -d \"${DEV_HOME}/.oh-my-zsh\" ]]; then
    git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git \"${DEV_HOME}/.oh-my-zsh\"
  fi

  # Clone dotfiles repo
  if [[ ! -d \"${DEV_HOME}/.dotfiles\" ]]; then
    git clone https://github.com/lmorchard/dotfiles.git \"${DEV_HOME}/.dotfiles\"
  fi

  # Run dotfiles setup
  if [[ -x \"${DEV_HOME}/.dotfiles/script/setup\" ]]; then
    \"${DEV_HOME}/.dotfiles/script/setup\" || true
  fi

  # Ensure git uses gh credential helper for github.com, overriding any stale vscode helper
  git config --global credential.https://github.com.helper \"\"
  git config --global --add credential.https://github.com.helper \"!gh auth git-credential\"

  # Ensure user bin dirs exist in PATH
  mkdir -p \"${DEV_HOME}/bin\" \"${DEV_HOME}/.local/bin\"
"

# Inject API keys or Claude creds if present in Secret Manager
CLAUDE_JSON=$(get_secret "claude-credentials-json")
if [[ -n "${CLAUDE_JSON}" ]]; then
  # Note: ~/.claude is a symlink to ~/.dotfiles/.claude
  mkdir -p "${DEV_HOME}/.dotfiles/.claude"
  echo "${CLAUDE_JSON}" > "${DEV_HOME}/.dotfiles/.claude/.credentials.json"
  chmod 600 "${DEV_HOME}/.dotfiles/.claude/.credentials.json"
  chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.dotfiles/.claude"
fi

# Inject Opencode configuration if present
OPENCODE_CONFIG=$(get_secret "opencode-config-jsonc")
if [[ -n "${OPENCODE_CONFIG}" ]]; then
  mkdir -p "${DEV_HOME}/.config/opencode"
  echo "${OPENCODE_CONFIG}" > "${DEV_HOME}/.config/opencode/opencode.jsonc"
  chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.config/opencode"
fi

# Inject Vertex SA key for Opencode if present
VERTEX_SA_JSON=$(get_secret "vertex-sa-key-json")
if [[ -n "${VERTEX_SA_JSON}" ]]; then
  mkdir -p "${DEV_HOME}/.config/opencode"
  echo "${VERTEX_SA_JSON}" > "${DEV_HOME}/.config/opencode/vertex-sa-key.json"
  chmod 600 "${DEV_HOME}/.config/opencode/vertex-sa-key.json"
  chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.config/opencode"
fi

ANTHROPIC_KEY=$(get_secret "anthropic-api-key")
OPENAI_KEY=$(get_secret "openai-api-key")

# Write environment secrets into /home/lmorchard/.profile.d/agent-env.sh
mkdir -p "${DEV_HOME}/.profile.d"
cat <<'EOF' > "${DEV_HOME}/.profile.d/agent-env.sh"
# Added by devbox startup
export PATH="$HOME/.local/bin:$HOME/bin:$HOME/.opencode/bin:/usr/local/go/bin:/snap/bin:$PATH"
EOF

if [[ -n "${ANTHROPIC_KEY}" ]]; then
  echo "export ANTHROPIC_API_KEY=\"${ANTHROPIC_KEY}\"" >> "${DEV_HOME}/.profile.d/agent-env.sh"
fi
if [[ -n "${OPENAI_KEY}" ]]; then
  echo "export OPENAI_API_KEY=\"${OPENAI_KEY}\"" >> "${DEV_HOME}/.profile.d/agent-env.sh"
fi

# If vertex key was placed, configure Opencode Vertex environment variables
if [[ -n "${VERTEX_SA_JSON}" ]]; then
  VERTEX_PRJ=$(get_secret "vertex-project-id")
  VERTEX_LOC=$(get_secret "vertex-location")
  VERTEX_PRJ="${VERTEX_PRJ:-$(gcloud config get-value project 2>/dev/null || true)}"
  VERTEX_LOC="${VERTEX_LOC:-global}"
  cat <<EOF >> "${DEV_HOME}/.profile.d/agent-env.sh"
export GOOGLE_APPLICATION_CREDENTIALS="\$HOME/.config/opencode/vertex-sa-key.json"
export GOOGLE_CLOUD_PROJECT="${VERTEX_PRJ}"
export GOOGLE_VERTEX_LOCATION="${VERTEX_LOC}"
EOF
fi
chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.profile.d"

# Ensure zshrc sources .profile.d and sets convenience aliases
if ! grep -q "agent-env.sh" "${DEV_HOME}/.zshrc" 2>/dev/null; then
  echo '[ -f "$HOME/.profile.d/agent-env.sh" ] && source "$HOME/.profile.d/agent-env.sh"' >> "${DEV_HOME}/.zshrc"
fi

# 10. Clone Workspace Repos and copy environment files
set_stage "cloning-workspace-repos"
echo "==> Setting up workspace repositories under ${DEV_HOME}/devel..."
sudo -u "${DEV_USER}" mkdir -p "${DEV_HOME}/devel"

REPOS_LIST=$(get_secret "workspace-repos-list")
ENVS_B64=$(get_secret "workspace-repo-envs-b64")

# Extract repo .env files to a staging directory if present
if [[ -n "${ENVS_B64}" ]]; then
  TMP_ENVS="/tmp/repo-envs"
  mkdir -p "${TMP_ENVS}"
  echo "${ENVS_B64}" | base64 -d | tar -C "${TMP_ENVS}" -xzf -
fi

CLONE_WARNINGS=""
if [[ -n "${REPOS_LIST}" ]]; then
  while IFS= read -r line || [[ -n "${line}" ]]; do
    # Trim whitespace and skip comments/blank lines
    repo=$(echo "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ -z "${repo}" || "${repo}" =~ ^# ]] && continue

    repo_name=$(basename "${repo}" .git)
    target_dir="${DEV_HOME}/devel/${repo_name}"

    if [[ ! -d "${target_dir}" ]]; then
      echo "  -> Cloning ${repo} into ${target_dir}..."
      # If repo is "owner/repo", format as https://github.com/owner/repo.git
      if [[ ! "${repo}" =~ ^https?:// ]] && [[ ! "${repo}" =~ ^git@ ]]; then
        repo="https://github.com/${repo}.git"
      fi
      CLONE_OUTPUT=$(sudo -u "${DEV_USER}" git clone "${repo}" "${target_dir}" 2>&1) || {
        echo "  [WARN] Failed to clone ${repo}:"
        echo "${CLONE_OUTPUT}"
        if echo "${CLONE_OUTPUT}" | grep -q "SAML SSO"; then
          CLONE_WARNINGS="${CLONE_WARNINGS}Failed to clone ${repo_name} (GitHub SAML SSO authorization required). "
        else
          CLONE_WARNINGS="${CLONE_WARNINGS}Failed to clone ${repo_name}. "
        fi
        continue
      }
    fi

    # Check if a matching .env exists in staging
    if [[ -d "/tmp/repo-envs" && -f "/tmp/repo-envs/${repo_name}.env" && -d "${target_dir}" ]]; then
      echo "  -> Copying ${repo_name}.env to ${target_dir}/.env"
      install -m 0600 -o "${DEV_USER}" -g "${DEV_USER}" "/tmp/repo-envs/${repo_name}.env" "${target_dir}/.env"
    fi

    # Run optional per-repo setup hook if present (script/setup, setup.sh, or make setup)
    if [[ -d "${target_dir}" ]]; then
      if [[ -x "${target_dir}/script/setup" ]]; then
        echo "  -> Running ${repo_name} script/setup..."
        sudo -u "${DEV_USER}" bash -c "cd '${target_dir}' && ./script/setup" || echo "  [WARN] ${repo_name} script/setup failed."
      elif [[ -f "${target_dir}/setup.sh" ]]; then
        echo "  -> Running ${repo_name} setup.sh..."
        sudo -u "${DEV_USER}" bash -c "cd '${target_dir}' && bash setup.sh" || echo "  [WARN] ${repo_name} setup.sh failed."
      elif [[ -f "${target_dir}/Makefile" ]] && grep -qE '^[[:space:]]*setup:' "${target_dir}/Makefile" 2>/dev/null; then
        echo "  -> Running 'make setup' in ${repo_name}..."
        sudo -u "${DEV_USER}" bash -c "cd '${target_dir}' && make setup" || echo "  [WARN] 'make setup' in ${repo_name} failed."
      fi
    fi
  done <<< "${REPOS_LIST}"
  rm -rf /tmp/repo-envs 2>/dev/null || true
fi

# Record clone warnings in guest attributes if any occurred
if [[ -n "${CLONE_WARNINGS}" ]]; then
  curl -s -X PUT --data "${CLONE_WARNINGS}" \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/devbox/warnings" 2>/dev/null || true
fi

# 11. Configure and start Wideboi as a systemd user service
set_stage "starting-wideboi-service"
echo "==> Configuring Wideboi systemd user service..."
USER_SYSTEMD_DIR="${DEV_HOME}/.config/systemd/user"
mkdir -p "${USER_SYSTEMD_DIR}"

WIDEBOI_TOKEN=$(get_secret "wideboi-token")
WIDEBOI_EXEC="/usr/local/bin/wideboi --websocket 0.0.0.0:8080 --disable-tls"
if [[ -n "${WIDEBOI_TOKEN}" ]]; then
  WIDEBOI_EXEC="${WIDEBOI_EXEC} --websocket-token ${WIDEBOI_TOKEN}"
fi
WIDEBOI_EXEC="${WIDEBOI_EXEC} server"

cat <<EOF > "${USER_SYSTEMD_DIR}/wideboi.service"
[Unit]
Description=Wideboi Server
After=network.target

[Service]
Type=simple
WorkingDirectory=%h
ExecStart=${WIDEBOI_EXEC}
Restart=always
RestartSec=5
EnvironmentFile=-%h/.profile.d/agent-env.sh
Environment="PATH=%h/.local/bin:%h/bin:%h/.opencode/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin"

[Install]
WantedBy=default.target
EOF

chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.config"

# Start the user service via systemctl user mode
USER_UID=$(id -u "${DEV_USER}")
export XDG_RUNTIME_DIR="/run/user/${USER_UID}"
sudo -u "${DEV_USER}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" systemctl --user daemon-reload || true
sudo -u "${DEV_USER}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" systemctl --user enable --now wideboi.service || true

# 12. Configure idle auto-stop watchdog
set_stage "configuring-idle-watchdog"
echo "==> Configuring idle watchdog..."
AUTO_STOP_HOURS=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/auto-stop-hours" 2>/dev/null || echo "2")
AUTO_STOP_HOURS="${AUTO_STOP_HOURS:-2}"

if [[ "${AUTO_STOP_HOURS}" -gt 0 ]]; then
  echo "export AUTO_STOP_HOURS=\"${AUTO_STOP_HOURS}\"" >> "${DEV_HOME}/.profile.d/agent-env.sh"

  if [[ ! -x /usr/local/bin/devbox-idle-watchdog ]]; then
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
  fi

  if [[ ! -f /etc/systemd/system/devbox-idle-watchdog.service ]]; then
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
  fi

  systemctl daemon-reload
  systemctl enable --now devbox-idle-watchdog.timer
  echo "==> Idle watchdog timer enabled (timeout: ${AUTO_STOP_HOURS}h)."
else
  echo "==> Idle watchdog disabled (AUTO_STOP_HOURS=${AUTO_STOP_HOURS})."
fi

# 13. Connect Tailscale at the very end of startup
set_stage "connecting-tailscale"
echo "==> Connecting Tailscale (signals ready)..."
if [[ -n "${TS_AUTHKEY}" ]]; then
  TS_BACKEND_STATE=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true)
  if [[ "${TS_BACKEND_STATE}" == "Running" ]]; then
    echo "==> Tailscale is already connected and running."
    tailscale up --hostname="${TAILSCALE_HOSTNAME}" --accept-routes
  else
    echo "==> Tailscale backend state is '${TS_BACKEND_STATE:-not running}'. Resetting local state for clean authentication..."
    # If the previous ephemeral node was culled by Tailscale while stopped,
    # /var/lib/tailscale holds a stale node key that prevents re-authentication.
    # Wiping state and restarting tailscaled ensures a clean ephemeral registration.
    tailscale logout 2>/dev/null || true
    systemctl stop tailscaled
    rm -rf /var/lib/tailscale/*
    systemctl start tailscaled
    sleep 2

    if ! tailscale up \
      --authkey="${TS_AUTHKEY}" \
      --hostname="${TAILSCALE_HOSTNAME}" \
      --reset \
      --accept-routes; then
      echo "==> [ERROR] Failed to authenticate Tailscale with provided auth key."
      set_stage "ready-tailscale-failed"
      exit 1
    fi
  fi
  echo "==> Tailscale connected."
  set_stage "ready"
else
  echo "==> [WARN] No tailscale-auth-key secret found. Tailscale installed but not logged in."
  set_stage "ready-no-tailscale"
fi

echo "================================================================"
echo "Devbox Bootstrap Finished: $(date -u)"
echo "Wideboi service status:"
sudo -u "${DEV_USER}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" systemctl --user status wideboi.service --no-pager || true
echo "================================================================"
