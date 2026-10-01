#!/usr/bin/env bash
#
# sync-secrets-to-vm.sh: Sync secrets directly to an active running VM.
# Called by 'make sync-secrets'.
#
set -euo pipefail

TARGET_HOST="$1"
DEV_USER="$2"
PROJECT_ID="$3"

echo "==> Fetching latest secrets from GCP Secret Manager in ${PROJECT_ID}..."

get_secret() {
  local secret_name="$1"
  gcloud secrets versions access latest --secret="${secret_name}" --project="${PROJECT_ID}" 2>/dev/null || true
}

DEV_HOME="/home/${DEV_USER}"
TMP_SYNC=$(mktemp -d)
trap 'rm -rf "${TMP_SYNC}"' EXIT

mkdir -p "${TMP_SYNC}/profile.d" "${TMP_SYNC}/opencode" "${TMP_SYNC}/claude" "${TMP_SYNC}/ssh"

# 1. Environment variables (agent-env.sh)
cat <<'EOF' > "${TMP_SYNC}/profile.d/agent-env.sh"
# Added by devbox startup / sync-secrets
export PATH="$HOME/.local/bin:$HOME/bin:$HOME/.opencode/bin:/usr/local/go/bin:$PATH"
EOF

ANTHROPIC_KEY=$(get_secret "anthropic-api-key")
OPENAI_KEY=$(get_secret "openai-api-key")
if [[ -n "${ANTHROPIC_KEY}" ]]; then
  echo "export ANTHROPIC_API_KEY=\"${ANTHROPIC_KEY}\"" >> "${TMP_SYNC}/profile.d/agent-env.sh"
fi
if [[ -n "${OPENAI_KEY}" ]]; then
  echo "export OPENAI_API_KEY=\"${OPENAI_KEY}\"" >> "${TMP_SYNC}/profile.d/agent-env.sh"
fi

# 2. Vertex credentials
VERTEX_SA_JSON=$(get_secret "vertex-sa-key-json")
if [[ -n "${VERTEX_SA_JSON}" ]]; then
  echo "${VERTEX_SA_JSON}" > "${TMP_SYNC}/opencode/vertex-sa-key.json"
  chmod 600 "${TMP_SYNC}/opencode/vertex-sa-key.json"

  VERTEX_PRJ=$(get_secret "vertex-project-id")
  VERTEX_LOC=$(get_secret "vertex-location")
  VERTEX_PRJ="${VERTEX_PRJ:-${PROJECT_ID}}"
  VERTEX_LOC="${VERTEX_LOC:-global}"
  cat <<EOF >> "${TMP_SYNC}/profile.d/agent-env.sh"
export GOOGLE_APPLICATION_CREDENTIALS="\$HOME/.config/opencode/vertex-sa-key.json"
export GOOGLE_CLOUD_PROJECT="${VERTEX_PRJ}"
export GOOGLE_VERTEX_LOCATION="${VERTEX_LOC}"
EOF
fi

# 3. Opencode config
OPENCODE_CONFIG=$(get_secret "opencode-config-jsonc")
if [[ -n "${OPENCODE_CONFIG}" ]]; then
  echo "${OPENCODE_CONFIG}" > "${TMP_SYNC}/opencode/opencode.jsonc"
fi

# 4. Claude credentials
CLAUDE_JSON=$(get_secret "claude-credentials-json")
if [[ -n "${CLAUDE_JSON}" ]]; then
  echo "${CLAUDE_JSON}" > "${TMP_SYNC}/claude/.credentials.json"
  chmod 600 "${TMP_SYNC}/claude/.credentials.json"
fi

# 5. SSH Public Key
SSH_PUBKEY=$(get_secret "devbox-ssh-pubkey")
if [[ -n "${SSH_PUBKEY}" ]]; then
  echo "${SSH_PUBKEY}" > "${TMP_SYNC}/ssh/authorized_keys"
  chmod 600 "${TMP_SYNC}/ssh/authorized_keys"
fi

# 6. GitHub PAT
GH_PAT=$(get_secret "github-pat")

echo "==> Transferring files to ${TARGET_HOST}..."
BUNDLE_PATH="/tmp/devbox-sync-$$.tar.gz"
tar --no-xattrs -C "${TMP_SYNC}" -czf "${BUNDLE_PATH}" .
scp -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null "${BUNDLE_PATH}" "${DEV_USER}@${TARGET_HOST}:/tmp/secrets-bundle.tar.gz"
rm -f "${BUNDLE_PATH}"

echo "==> Applying secrets on ${TARGET_HOST}..."
ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null "${DEV_USER}@${TARGET_HOST}" "bash -s" <<REMOTE_SCRIPT
set -euo pipefail

TMP_EXTRACT=\$(mktemp -d)
tar -C "\${TMP_EXTRACT}" -xzf /tmp/secrets-bundle.tar.gz
rm -f /tmp/secrets-bundle.tar.gz

# 1. Update agent-env.sh
mkdir -p "${DEV_HOME}/.profile.d"
cp "\${TMP_EXTRACT}/profile.d/agent-env.sh" "${DEV_HOME}/.profile.d/agent-env.sh"
# Re-add AUTO_STOP_HOURS from instance metadata, as startup.sh does
AUTO_STOP_HOURS=\$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/auto-stop-hours" 2>/dev/null || true)
AUTO_STOP_HOURS="\${AUTO_STOP_HOURS:-2}"
if [[ "\${AUTO_STOP_HOURS}" -gt 0 ]]; then
  echo "export AUTO_STOP_HOURS=\"\${AUTO_STOP_HOURS}\"" >> "${DEV_HOME}/.profile.d/agent-env.sh"
fi

# 2. Update Opencode files
if [[ -f "\${TMP_EXTRACT}/opencode/vertex-sa-key.json" ]]; then
  mkdir -p "${DEV_HOME}/.config/opencode"
  install -m 0600 "\${TMP_EXTRACT}/opencode/vertex-sa-key.json" "${DEV_HOME}/.config/opencode/vertex-sa-key.json"
fi
if [[ -f "\${TMP_EXTRACT}/opencode/opencode.jsonc" ]]; then
  mkdir -p "${DEV_HOME}/.config/opencode"
  cp "\${TMP_EXTRACT}/opencode/opencode.jsonc" "${DEV_HOME}/.config/opencode/opencode.jsonc"
fi

# 3. Update Claude credentials
if [[ -f "\${TMP_EXTRACT}/claude/.credentials.json" ]]; then
  mkdir -p "${DEV_HOME}/.dotfiles/.claude"
  install -m 0600 "\${TMP_EXTRACT}/claude/.credentials.json" "${DEV_HOME}/.dotfiles/.claude/.credentials.json"
fi

# 4. Update authorized_keys
if [[ -f "\${TMP_EXTRACT}/ssh/authorized_keys" ]]; then
  mkdir -p "${DEV_HOME}/.ssh"
  cat "\${TMP_EXTRACT}/ssh/authorized_keys" >> "${DEV_HOME}/.ssh/authorized_keys"
  sort -u "${DEV_HOME}/.ssh/authorized_keys" -o "${DEV_HOME}/.ssh/authorized_keys"
  chmod 0600 "${DEV_HOME}/.ssh/authorized_keys"
fi

rm -rf "\${TMP_EXTRACT}"

# 5. Authenticate gh if token is available
if [[ -n "${GH_PAT}" ]]; then
  echo "${GH_PAT}" | gh auth login --with-token 2>/dev/null || true
  gh auth setup-git 2>/dev/null || true
fi

# Restart wideboi service to pick up any updated EnvironmentFile / tokens
systemctl --user daemon-reload || true
systemctl --user restart wideboi.service || true
echo "==> Secrets applied and Wideboi service refreshed on host!"
REMOTE_SCRIPT
