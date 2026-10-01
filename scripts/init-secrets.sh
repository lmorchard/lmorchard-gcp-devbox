#!/usr/bin/env bash
#
# init-secrets.sh: Create Secret Manager entries in your GCP project.
# Run this once on your local machine before spinning up your first VM.
#
# If SECRETS_CHANGED_FILE is set, that file is created when any secret is
# created or updated (used by 'make update' to skip no-op VM syncs).
#
# A local cache of value hashes (.secrets-cache/, gitignored) lets unchanged
# secrets skip Secret Manager entirely. Set FORCE=1 to ignore the cache and
# compare every secret against Secret Manager (e.g. after editing one there).
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

CACHE_DIR="${REPO_DIR}/.secrets-cache/${PROJECT_ID}"

mark_changed() {
  if [[ -n "${SECRETS_CHANGED_FILE:-}" ]]; then
    touch "${SECRETS_CHANGED_FILE}"
  fi
}

value_hash() {
  printf "%s" "$1" | shasum -a 256 | cut -d' ' -f1
}

is_cached() {
  [[ -f "${CACHE_DIR}/$1" && "$(cat "${CACHE_DIR}/$1")" == "$(value_hash "$2")" ]]
}

record_cached() {
  mkdir -p "${CACHE_DIR}"
  value_hash "$2" > "${CACHE_DIR}/$1"
}

# Phase 1 collects secrets and messages; phase 2 (below) syncs them.
declare -a QUEUE_NAMES=() QUEUE_VALUES=() QUEUE_NOTES=()
PENDING_NOTE=""

note() {
  PENDING_NOTE="$1"
}

store_secret() {
  QUEUE_NAMES+=("$1")
  QUEUE_VALUES+=("${2:-}")
  QUEUE_NOTES+=("${PENDING_NOTE}")
  PENDING_NOTE=""
}

sync_secret() {
  local name="$1"
  local val="$2"

  # If not defined in .env, silently skip (no console prompt)
  if [[ -z "${val}" ]]; then
    echo "  [SKIP] '${name}' not defined in .env; skipping."
    return
  fi

  if is_cached "${name}" "${val}"; then
    echo "  [OK] Secret '${name}' unchanged since last sync."
    return
  fi

  if gcloud secrets describe "${name}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    # Check if latest version already has the exact same content
    local current_val
    current_val=$(gcloud secrets versions access latest --secret="${name}" --project="${PROJECT_ID}" 2>/dev/null || true)
    if [[ "${current_val}" == "${val}" ]]; then
      echo "  [OK] Secret '${name}' is already up-to-date."
      record_cached "${name}" "${val}"
      return
    fi
    echo "  [UPDATING] Secret '${name}' changed; adding new version..."
    printf "%s" "${val}" | gcloud secrets versions add "${name}" \
      --project="${PROJECT_ID}" \
      --data-file=- >/dev/null
    echo "  [UPDATED] Secret '${name}' updated."
    record_cached "${name}" "${val}"
    mark_changed
  else
    echo "  [CREATING] Secret '${name}'..."
    printf "%s" "${val}" | gcloud secrets create "${name}" \
      --project="${PROJECT_ID}" \
      --data-file=- \
      --replication-policy="automatic" >/dev/null
    echo "  [CREATED] Secret '${name}' created."
    record_cached "${name}" "${val}"
    mark_changed
  fi
}

# 1. Tailscale Auth Key
store_secret "tailscale-auth-key" "${TAILSCALE_AUTH_KEY:-}" "Tailscale auth key (must be reusable; recommend ephemeral)"

# 2. GitHub PAT
store_secret "github-pat" "${GITHUB_PAT:-}" "GitHub Personal Access Token (PAT) with repo/workflow scope"

# 3. Claude Credentials JSON
CLAUDE_CREDS_FILE="${CLAUDE_CREDS_PATH:-${HOME}/.claude/.credentials.json}"
if [[ -f "${CLAUDE_CREDS_FILE}" ]]; then
  note "Found Claude credentials file at ${CLAUDE_CREDS_FILE}"
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
  note "Found Vertex service account key at ${VERTEX_KEY_FILE}"
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
  note "Found local SSH public key at ${PUBKEY_FILE}"
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
  note "Found Opencode config at ${OPENCODE_CONFIG_FILE}"
  OPENCODE_CONTENT=$(cat "${OPENCODE_CONFIG_FILE}")
  store_secret "opencode-config-jsonc" "${OPENCODE_CONTENT}" "Opencode config (opencode.jsonc)"
else
  store_secret "opencode-config-jsonc" "" "Opencode config (opencode.jsonc)"
fi

# 9. Workspace repos and their .env files
REPOS_FILE="${REPO_DIR}/workspace/repos.txt"
if [[ -f "${REPOS_FILE}" ]]; then
  note "Found workspace repos list at ${REPOS_FILE}"
  REPOS_CONTENT=$(cat "${REPOS_FILE}")
  store_secret "workspace-repos-list" "${REPOS_CONTENT}" "List of repos to clone in ~/devel"
else
  store_secret "workspace-repos-list" "" "List of repos to clone in ~/devel"
fi

# Package workspace/envs/*.env into a single tar.gz bundle for Secret Manager
ENVS_DIR="${REPO_DIR}/workspace/envs"
if compgen -G "${ENVS_DIR}/*.env" >/dev/null; then
  note "Found repo .env files in ${ENVS_DIR}; packaging..."
  # Build a reproducible archive (no xattrs, no gzip timestamp) so unchanged
  # files produce identical bytes and don't trigger a new secret version.
  ENVS_ARCHIVE=$(COPYFILE_DISABLE=1 tar -C "${ENVS_DIR}" --no-xattrs --no-mac-metadata --format ustar -cf - $(cd "${ENVS_DIR}" && ls *.env) | gzip -n | base64)
  store_secret "workspace-repo-envs-b64" "${ENVS_ARCHIVE}" "Base64 tar.gz of repo .env files"
else
  store_secret "workspace-repo-envs-b64" "" "Base64 tar.gz of repo .env files"
fi

# Phase 2: skip Secret Manager entirely if every value matches the cache
all_cached=1
if [[ -z "${FORCE:-}" ]]; then
  for i in "${!QUEUE_NAMES[@]}"; do
    val="${QUEUE_VALUES[$i]}"
    if [[ -n "${val}" ]] && ! is_cached "${QUEUE_NAMES[$i]}" "${val}"; then
      all_cached=0
      break
    fi
  done
else
  all_cached=0
  rm -rf "${CACHE_DIR}"
fi

if [[ "${all_cached}" -eq 1 ]]; then
  echo "==> Secrets unchanged since last sync to ${PROJECT_ID}; skipping Secret Manager. (FORCE=1 to recheck)"
  exit 0
fi

echo "==> Configuring secrets in project: ${PROJECT_ID}"

# Enable Secret Manager API
echo "==> Ensuring secretmanager.googleapis.com is enabled..."
gcloud services enable secretmanager.googleapis.com --project="${PROJECT_ID}"

for i in "${!QUEUE_NAMES[@]}"; do
  if [[ -n "${QUEUE_NOTES[$i]}" ]]; then
    echo ""
    echo "${QUEUE_NOTES[$i]}"
  fi
  sync_secret "${QUEUE_NAMES[$i]}" "${QUEUE_VALUES[$i]}"
done

echo ""
echo "==> Secret setup complete."
