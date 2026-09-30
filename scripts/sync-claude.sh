#!/usr/bin/env bash
#
# sync-claude.sh: Bidirectional sync of Claude Code context & project memories
# between the local development machine and the GCP devbox.
#
# Usage:
#   scripts/sync-claude.sh push [target_host] [dev_user]
#   scripts/sync-claude.sh pull [target_host] [dev_user]
#
set -euo pipefail

ACTION="${1:-push}"
TARGET_HOST="${2:-wideboi-sandbox}"
DEV_USER="${3:-lmorchard}"
DEV_HOME="/home/${DEV_USER}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null)

case "${ACTION}" in
  push)
    echo "==> Packaging Claude global context and project memories for ${TARGET_HOST}..."
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "${TMP_DIR}"' EXIT

    mkdir -p "${TMP_DIR}/projects"

    # 1. Global CLAUDE.md
    if [[ -f "${HOME}/.claude/CLAUDE.md" ]]; then
      cp "${HOME}/.claude/CLAUDE.md" "${TMP_DIR}/CLAUDE.md"
    fi

    # 2. Global journal.md
    if [[ -f "${HOME}/.claude/journal.md" ]]; then
      cp "${HOME}/.claude/journal.md" "${TMP_DIR}/journal.md"
    fi

    # 3. Project memories: match against workspace repos and known projects
    candidates=("pilo-evals-judge" "zoo-service" "wideboi" "ichabod" "lmorchard-agent-skills")
    if [[ -f "workspace/repos.txt" ]]; then
      while IFS= read -r line || [[ -n "${line}" ]]; do
        repo=$(echo "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ -z "${repo}" || "${repo}" =~ ^# ]] && continue
        candidates+=("$(basename "${repo}" .git)")
      done < "workspace/repos.txt"
    fi

    shopt -s nullglob
    seen=()
    for repo_name in "${candidates[@]}"; do
      [[ " ${seen[*]:-} " =~ " ${repo_name} " ]] && continue
      seen+=("${repo_name}")

      match=""
      for pdir in "${HOME}/.claude/projects"/*"-${repo_name}"; do
        if [[ -d "${pdir}/memory" ]]; then
          match="${pdir}"
          break
        fi
      done

      if [[ -n "${match}" ]]; then
        vm_project_dir="-home-${DEV_USER}-devel-${repo_name}"
        file_count=$(ls -1 "${match}/memory" 2>/dev/null | wc -l | tr -d ' ')
        echo "    -> Memory for '${repo_name}': ${file_count} files"
        mkdir -p "${TMP_DIR}/projects/${vm_project_dir}"
        cp -r "${match}/memory" "${TMP_DIR}/projects/${vm_project_dir}/"
      fi
    done
    shopt -u nullglob

    # 4. MCP Servers from ~/.claude.json
    if [[ -f "${HOME}/.claude.json" ]]; then
      node -e '
        const fs = require("fs");
        try {
          const cfg = JSON.parse(fs.readFileSync("'"${HOME}"'/.claude.json", "utf8"));
          if (cfg.mcpServers) {
            fs.writeFileSync("'"${TMP_DIR}"'/mcpServers.json", JSON.stringify(cfg.mcpServers, null, 2) + "\n");
          }
        } catch (_) {}
      ' 2>/dev/null || true
    fi

    BUNDLE="/tmp/claude-push-$$.tar.gz"
    tar --no-xattrs -C "${TMP_DIR}" -czf "${BUNDLE}" .

    echo "==> Transferring memories and context to ${TARGET_HOST}..."
    scp "${SSH_OPTS[@]}" "${BUNDLE}" "${DEV_USER}@${TARGET_HOST}:/tmp/claude-bundle.tar.gz"
    rm -f "${BUNDLE}"

    echo "==> Unpacking on ${TARGET_HOST}..."
    ssh "${SSH_OPTS[@]}" "${DEV_USER}@${TARGET_HOST}" "bash -s" <<REMOTE_SCRIPT
set -euo pipefail
mkdir -p "${DEV_HOME}/.claude/projects"

TMP_REMOTE=\$(mktemp -d)
tar -C "\${TMP_REMOTE}" -xzf /tmp/claude-bundle.tar.gz
rm -f /tmp/claude-bundle.tar.gz

# Sync CLAUDE.md
if [[ -f "\${TMP_REMOTE}/CLAUDE.md" ]]; then
  cp "\${TMP_REMOTE}/CLAUDE.md" "${DEV_HOME}/.claude/CLAUDE.md"
fi

# Sync journal.md (copy if absent)
if [[ -f "\${TMP_REMOTE}/journal.md" && ! -f "${DEV_HOME}/.claude/journal.md" ]]; then
  cp "\${TMP_REMOTE}/journal.md" "${DEV_HOME}/.claude/journal.md"
fi

# Sync project memories
if [[ -d "\${TMP_REMOTE}/projects" ]]; then
  for pdir in "\${TMP_REMOTE}/projects"/*; do
    if [[ -d "\${pdir}/memory" ]]; then
      pname=\$(basename "\${pdir}")
      mkdir -p "${DEV_HOME}/.claude/projects/\${pname}"
      cp -r "\${pdir}/memory" "${DEV_HOME}/.claude/projects/\${pname}/"
    fi
  done
fi

# Sync user MCP servers into ~/.claude.json
if [[ -f "\${TMP_REMOTE}/mcpServers.json" ]]; then
  node -e '
    const fs = require("fs");
    const p = "'"${DEV_HOME}"'/.claude.json";
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(p, "utf8")); } catch (_) {}
    const incoming = JSON.parse(fs.readFileSync("'"\${TMP_REMOTE}"'/mcpServers.json", "utf8"));
    cfg.mcpServers = Object.assign({}, cfg.mcpServers || {}, incoming);
    fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
  ' 2>/dev/null || true
fi

rm -rf "\${TMP_REMOTE}"
echo "==> Claude context and memories successfully pushed to devbox!"
REMOTE_SCRIPT
    ;;

  pull)
    echo "==> Pulling Claude memories and journal from ${TARGET_HOST}..."
    TMP_PULL=$(mktemp -d)
    trap 'rm -rf "${TMP_PULL}"' EXIT

    REMOTE_ARCHIVE="/tmp/claude-pull-$$.tar.gz"
    ssh "${SSH_OPTS[@]}" "${DEV_USER}@${TARGET_HOST}" "bash -s" <<REMOTE_SCRIPT
set -euo pipefail
TMP_PKG=\$(mktemp -d)
mkdir -p "\${TMP_PKG}/projects"

if [[ -f "${DEV_HOME}/.claude/journal.md" ]]; then
  cp "${DEV_HOME}/.claude/journal.md" "\${TMP_PKG}/journal.md"
fi

if [[ -d "${DEV_HOME}/.claude/projects" ]]; then
  for pdir in "${DEV_HOME}/.claude/projects"/*; do
    if [[ -d "\${pdir}/memory" ]]; then
      pname=\$(basename "\${pdir}")
      mkdir -p "\${TMP_PKG}/projects/\${pname}"
      cp -r "\${pdir}/memory" "\${TMP_PKG}/projects/\${pname}/"
    fi
  done
fi

tar --no-xattrs -C "\${TMP_PKG}" -czf "${REMOTE_ARCHIVE}" .
rm -rf "\${TMP_PKG}"
REMOTE_SCRIPT

    scp "${SSH_OPTS[@]}" "${DEV_USER}@${TARGET_HOST}:${REMOTE_ARCHIVE}" "${TMP_PULL}/claude-pulled.tar.gz"
    ssh "${SSH_OPTS[@]}" "${DEV_USER}@${TARGET_HOST}" "rm -f ${REMOTE_ARCHIVE}"

    tar -C "${TMP_PULL}" -xzf "${TMP_PULL}/claude-pulled.tar.gz"

    # Merge pulled memories into local projects
    shopt -s nullglob
    if [[ -d "${TMP_PULL}/projects" ]]; then
      for rdir in "${TMP_PULL}/projects"/*; do
        if [[ -d "${rdir}/memory" ]]; then
          rname=$(basename "${rdir}")
          repo_name="${rname##*-}"
          for candidate in pilo-evals-judge zoo-service wideboi ichabod lmorchard-agent-skills; do
            if [[ "${rname}" == *"-${candidate}" ]]; then
              repo_name="${candidate}"
              break
            fi
          done

          # Find matching local project directory
          local_pdir=""
          for lp in "${HOME}/.claude/projects"/*"-${repo_name}"; do
            if [[ -d "${lp}" ]]; then
              local_pdir="${lp}"
              break
            fi
          done

          if [[ -n "${local_pdir}" ]]; then
            file_count=$(ls -1 "${rdir}/memory" 2>/dev/null | wc -l | tr -d ' ')
            echo "    <- Merging ${file_count} memories for '${repo_name}' into ${local_pdir}/memory/..."
            mkdir -p "${local_pdir}/memory"
            cp -n "${rdir}/memory"/* "${local_pdir}/memory/" 2>/dev/null || true
            if [[ -f "${rdir}/memory/MEMORY.md" ]]; then
              cp "${rdir}/memory/MEMORY.md" "${local_pdir}/memory/MEMORY.md"
            fi
          fi
        fi
      done
    fi
    shopt -u nullglob

    echo "==> Claude memories successfully pulled from devbox!"
    ;;

  *)
    echo "Error: Unknown action '${ACTION}'. Use 'push' or 'pull'." >&2
    exit 1
    ;;
esac
