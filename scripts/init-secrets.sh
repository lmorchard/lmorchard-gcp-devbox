#!/usr/bin/env bash
#
# init-secrets.sh: Create Secret Manager entries in your GCP project.
# Run this once on your local machine before spinning up your first VM.
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

# Load .env if present
if [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  source "${REPO_DIR}/.env"
  set +a
fi

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
if [[ -z "${PROJECT_ID}" ]]; then
  echo "Error: No GCP project set in 'gcloud config get-value project'." >&2
  exit 1
fi

echo "==> Configuring secrets in project: ${PROJECT_ID}"

# Enable Secret Manager API
echo "==> Ensuring secretmanager.googleapis.com is enabled..."
gcloud services enable secretmanager.googleapis.com --project="${PROJECT_ID}"

store_secret() {
  local name="$1"
  local env_val="${2:-}"
  local prompt_desc="$3"

  local val="${env_val}"

  # If not defined in .env, silently skip (no console prompt)
  if [[ -z "${val}" ]]; then
    echo "  [SKIP] '${name}' not defined in .env; skipping."
    return
  fi

  if gcloud secrets describe "${name}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    # Check if latest version already has the exact same content
    local current_val
    current_val=$(gcloud secrets versions access latest --secret="${name}" --project="${PROJECT_ID}" 2>/dev/null || true)
    if [[ "${current_val}" == "${val}" ]]; then
      echo "  [OK] Secret '${name}' is already up-to-date."
      return
    fi
    echo "  [UPDATING] Secret '${name}' changed; adding new version..."
    printf "%s" "${val}" | gcloud secrets versions add "${name}" \
      --project="${PROJECT_ID}" \
      --data-file=- >/dev/null
    echo "  [UPDATED] Secret '${name}' updated."
  else
    echo "  [CREATING] Secret '${name}'..."
    printf "%s" "${val}" | gcloud secrets create "${name}" \
      --project="${PROJECT_ID}" \
      --data-file=- \
      --replication-policy="automatic" >/dev/null
    echo "  [CREATED] Secret '${name}' created."
  fi
}

# 1. Tailscale Auth Key
store_secret "tailscale-auth-key" "${TAILSCALE_AUTH_KEY:-}" "Tailscale auth key (must be reusable; recommend ephemeral)"

# 2. GitHub PAT
store_secret "github-pat" "${GITHUB_PAT:-}" "GitHub Personal Access Token (PAT) with repo/workflow scope"

# 3. Claude Credentials JSON
CLAUDE_CREDS_FILE="${CLAUDE_CREDS_PATH:-${HOME}/.claude/.credentials.json}"
if [[ -f "${CLAUDE_CREDS_FILE}" ]]; then
  echo ""
  echo "Found Claude credentials file at ${CLAUDE_CREDS_FILE}"
  CLAUDE_JSON_CONTENT=$(cat "${CLAUDE_CREDS_FILE}")
  store_secret "claude-credentials-json" "${CLAUDE_JSON_CONTENT}" "Claude OAuth JSON credentials"
else
  store_secret "claude-credentials-json" "" "Claude OAuth JSON content"
fi

# 4. Agent API Keys (optional)
store_secret "anthropic-api-key" "${ANTHROPIC_API_KEY:-}" "Anthropic API Key"
store_secret "openai-api-key" "${OPENAI_API_KEY:-}" "OpenAI API Key"

# 5. Vertex Service Account Key & Project for Opencode (optional)
VERTEX_KEY_FILE="${VERTEX_SA_KEY_PATH:-${HOME}/.config/opencode/vertex-sa-key.json}"
if [[ -f "${VERTEX_KEY_FILE}" ]]; then
  echo ""
  echo "Found Vertex service account key at ${VERTEX_KEY_FILE}"
  VERTEX_KEY_CONTENT=$(cat "${VERTEX_KEY_FILE}")
  store_secret "vertex-sa-key-json" "${VERTEX_KEY_CONTENT}" "Vertex Service Account Key JSON for Opencode"
  store_secret "vertex-project-id" "${VERTEX_PROJECT_ID:-${PROJECT_ID}}" "Vertex Project ID"
  store_secret "vertex-location" "${VERTEX_LOCATION:-global}" "Vertex Location"
else
  store_secret "vertex-sa-key-json" "" "Vertex Service Account Key JSON for Opencode"
fi

# 6. Local SSH Public Key (for direct SSH access)
PUBKEY_FILE="${SSH_PUBKEY_PATH:-}"
if [[ -z "${PUBKEY_FILE}" ]]; then
  if [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
    PUBKEY_FILE="${HOME}/.ssh/id_ed25519.pub"
  elif [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
    PUBKEY_FILE="${HOME}/.ssh/id_rsa.pub"
  fi
fi

if [[ -n "${PUBKEY_FILE}" && -f "${PUBKEY_FILE}" ]]; then
  echo ""
  echo "Found local SSH public key at ${PUBKEY_FILE}"
  PUBKEY_CONTENT=$(cat "${PUBKEY_FILE}")
  store_secret "devbox-ssh-pubkey" "${PUBKEY_CONTENT}" "SSH public key for authorized_keys"
else
  store_secret "devbox-ssh-pubkey" "" "SSH public key for authorized_keys"
fi

# 7. Wideboi Web Token
store_secret "wideboi-token" "${WIDEBOI_TOKEN:-}" "Wideboi Web Client Token"

# 8. Opencode Config
OPENCODE_CONFIG_FILE="${OPENCODE_CONFIG_PATH:-${HOME}/.config/opencode/opencode.jsonc}"
if [[ -f "${OPENCODE_CONFIG_FILE}" ]]; then
  echo ""
  echo "Found Opencode config at ${OPENCODE_CONFIG_FILE}"
  OPENCODE_CONTENT=$(cat "${OPENCODE_CONFIG_FILE}")
  store_secret "opencode-config-jsonc" "${OPENCODE_CONTENT}" "Opencode config (opencode.jsonc)"
else
  store_secret "opencode-config-jsonc" "" "Opencode config (opencode.jsonc)"
fi

# 9. Workspace repos and their .env files
REPOS_FILE="${REPO_DIR}/workspace/repos.txt"
if [[ -f "${REPOS_FILE}" ]]; then
  echo ""
  echo "Found workspace repos list at ${REPOS_FILE}"
  REPOS_CONTENT=$(cat "${REPOS_FILE}")
  store_secret "workspace-repos-list" "${REPOS_CONTENT}" "List of repos to clone in ~/devel"
else
  store_secret "workspace-repos-list" "" "List of repos to clone in ~/devel"
fi

# Package workspace/envs/*.env into a single tar.gz bundle for Secret Manager
ENVS_DIR="${REPO_DIR}/workspace/envs"
if compgen -G "${ENVS_DIR}/*.env" >/dev/null; then
  echo ""
  echo "Found repo .env files in ${ENVS_DIR}; packaging..."
  ENVS_ARCHIVE=$(tar -C "${ENVS_DIR}" -czf - $(cd "${ENVS_DIR}" && ls *.env) | base64)
  store_secret "workspace-repo-envs-b64" "${ENVS_ARCHIVE}" "Base64 tar.gz of repo .env files"
else
  store_secret "workspace-repo-envs-b64" "" "Base64 tar.gz of repo .env files"
fi

echo ""
echo "==> Secret setup complete."
