#!/usr/bin/env bash
#
# devbox-idle-watchdog.sh
# Multi-factor idle detection watchdog for lmorchard-gcp-devbox.
#
# Factors checked:
# 1. Interactive SSH sessions (who | grep -q 'pts/')
# 2. Wideboi connected clients (web or terminal clients)
# 3. Wideboi active panes (any pane with status="working")
# 4. Agent sub-processes (child processes actively running under claude/codex/opencode)
# 5. Recent file modifications in agent session/history directories
# 6. CPU load average above threshold
#
# If idle for AUTO_STOP_HOURS (default 2), powers off the VM.
#
set -euo pipefail

DEV_USER="${DEV_USER:-lmorchard}"
DEV_HOME="/home/${DEV_USER}"
STATE_FILE="/var/run/devbox-idle-state"

export HOME="${DEV_HOME}"

# Load environment configuration if available
if [[ -f "${DEV_HOME}/.profile.d/agent-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "${DEV_HOME}/.profile.d/agent-env.sh"
fi

AUTO_STOP_HOURS="${AUTO_STOP_HOURS:-2}"

# 0 or negative disables auto-stop
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

# ------------------------------------------------------------------------------
# 1. Check for interactive SSH logins
# ------------------------------------------------------------------------------
if who | grep -q 'pts/'; then
  is_active=1
  active_reasons+=("interactive-ssh-session")
fi

# ------------------------------------------------------------------------------
# 2 & 3. Check Wideboi status (connected clients & working panes)
# ------------------------------------------------------------------------------
# Find Wideboi socket under /tmp/wideboi-<uid>/
DEV_UID=$(id -u "${DEV_USER}" 2>/dev/null || echo 1000)
WB_SOCK="/tmp/wideboi-${DEV_UID}/default.sock"

if [[ -S "${WB_SOCK}" ]] && command -v wideboi >/dev/null 2>&1; then
  # Check connected clients
  WB_CLIENTS=$(sudo -u "${DEV_USER}" wideboi -s "${WB_SOCK}" status --traffic --json 2>/dev/null | jq -r '.clients | length' 2>/dev/null || echo 0)
  if [[ "${WB_CLIENTS}" -gt 0 ]]; then
    is_active=1
    active_reasons+=("wideboi-clients-connected:${WB_CLIENTS}")
  fi

  # Check working panes
  WB_WORKING_PANES=$(sudo -u "${DEV_USER}" wideboi -s "${WB_SOCK}" status --json 2>/dev/null | jq -r '[.pane_statuses[] | select(. == "working")] | length' 2>/dev/null || echo 0)
  if [[ "${WB_WORKING_PANES}" -gt 0 ]]; then
    is_active=1
    active_reasons+=("wideboi-panes-working:${WB_WORKING_PANES}")
  fi
fi

# ------------------------------------------------------------------------------
# 3b. Check for active Docker containers (e.g. Zoo stacks, kind clusters)
# ------------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  RUNNING_CONTAINERS=$(docker ps -q 2>/dev/null | wc -l || echo 0)
  RUNNING_CONTAINERS=$(echo "${RUNNING_CONTAINERS}" | tr -d ' ')
  if [[ "${RUNNING_CONTAINERS}" -gt 0 ]]; then
    is_active=1
    active_reasons+=("docker-containers-running:${RUNNING_CONTAINERS}")
  fi
fi

# ------------------------------------------------------------------------------
# 4. Check for active child processes spawned by agents
# ------------------------------------------------------------------------------
# Find PIDs for claude, opencode, codex
AGENT_PIDS=$(pgrep -u "${DEV_USER}" -f 'claude|opencode|codex' 2>/dev/null || true)
if [[ -n "${AGENT_PIDS}" ]]; then
  for apid in ${AGENT_PIDS}; do
    # Check if this agent process has children (e.g. bash, node, python, git, go)
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

# ------------------------------------------------------------------------------
# 5. Check recent file modifications in agent session/history directories
# ------------------------------------------------------------------------------
# Look for writes in the last 15 minutes across agent directories
AGENT_DIRS=(
  "${DEV_HOME}/.claude/sessions"
  "${DEV_HOME}/.claude/history.jsonl"
  "${DEV_HOME}/.codex/sessions"
  "${DEV_HOME}/.local/share/opencode"
)

for adir in "${AGENT_DIRS[@]}"; do
  if [[ -e "${adir}" ]]; then
    # find files modified in the last 15 minutes (-mmin -15)
    RECENT_MODS=$(find "${adir}" -maxdepth 2 -mmin -15 2>/dev/null | head -n 1)
    if [[ -n "${RECENT_MODS}" ]]; then
      is_active=1
      active_reasons+=("recent-agent-file-writes:${adir}")
      break
    fi
  fi
done

# ------------------------------------------------------------------------------
# 6. Check CPU load (1-minute load average > 0.5 per 4 vCPUs)
# ------------------------------------------------------------------------------
LOAD_1MIN=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0.0")
LOAD_INT=$(echo "${LOAD_1MIN}" | awk '{print int($1 * 100)}')
# If 1-minute load is over 0.50 (50), something is doing non-trivial work
if [[ "${LOAD_INT}" -ge 50 ]]; then
  is_active=1
  active_reasons+=("cpu-load:${LOAD_1MIN}")
fi

# ------------------------------------------------------------------------------
# Evaluate Idle Duration & Take Action
# ------------------------------------------------------------------------------
if [[ "${is_active}" -eq 1 ]]; then
  # System is active - reset last active timestamp
  echo "${NOW}" > "${STATE_FILE}"
  log "System ACTIVE: ${active_reasons[*]} (resetting idle timer)"
  exit 0
fi

# If system is not active, determine how long it has been idle
if [[ ! -f "${STATE_FILE}" ]]; then
  # First observation of idleness - initialize timestamp to now
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
  # Sync filesystems before poweroff
  sync
  # Initiate power off via systemd
  systemctl poweroff
fi
