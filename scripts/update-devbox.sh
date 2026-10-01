#!/usr/bin/env bash
#
# update-devbox.sh: Apply all pending local updates to the devbox.
# Called by 'make update'.
#
#   1. Push startup.sh to instance metadata (applies on next boot; works while stopped)
#   2. Depending on VM state:
#        - reachable over Tailscale: update Secret Manager, push secrets to the VM
#          (only if any changed, since it restarts Wideboi), push Claude memories,
#          upgrade Wideboi
#        - RUNNING but unreachable (likely a crashed bootstrap): re-run the startup
#          script over IAP SSH, then continue as above
#        - stopped: update Secret Manager only; the VM picks it up on next start
#
# Each step runs even if an earlier one fails; a summary is printed at the end.
#
# Usage:
#   scripts/update-devbox.sh <tailscale_hostname> <instance_name> <project_id> <zone> <dev_user>
#
set -uo pipefail

TAILSCALE_HOSTNAME="$1"
INSTANCE_NAME="$2"
PROJECT_ID="$3"
ZONE="$4"
DEV_USER="$5"
MAKE="${MAKE:-make}"

declare -a RESULTS=()
FAILED=0

run_step() {
  local label="$1"
  shift
  echo ""
  echo "==> ${label}"
  if "$@"; then
    RESULTS+=("  ✅ ${label}")
  else
    RESULTS+=("  ❌ ${label}")
    FAILED=1
  fi
}

skip_step() {
  RESULTS+=("  ⏭️  $1 (skipped: $2)")
}

sub_make() {
  "${MAKE}" --no-print-directory "$@"
}

# Resolve the VM's current Tailscale IP each time, since an ephemeral node that
# re-registers (e.g. after a bootstrap re-run) may get a new IP and name suffix.
is_reachable() {
  local target
  target=$(tailscale status --json 2>/dev/null \
    | jq -r --arg h "${TAILSCALE_HOSTNAME}" '.Peer[] | select(.HostName | startswith($h)) | select(.Online == true) | .TailscaleIPs[0]' \
    | head -n1)
  tailscale ping --until-direct=false -c 1 "${target:-${TAILSCALE_HOSTNAME}}" >/dev/null 2>&1
}

# Poll for reachability, since a node that just re-registered takes a few
# seconds to appear as an online peer.
wait_reachable() {
  for _ in $(seq 1 20); do
    is_reachable && return 0
    sleep 3
  done
  return 1
}

local_tailscale_running() {
  [[ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState')" == "Running" ]]
}

# Re-run the startup script in place over IAP SSH. Refuses if a bootstrap is
# still in progress, so we don't run two copies at once.
rerun_bootstrap() {
  echo "    (this blocks until the startup script finishes; 'make logs' in another terminal shows progress)"
  gcloud compute ssh "${DEV_USER}@${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --tunnel-through-iap \
    --command='if [ "$(systemctl is-active google-startup-scripts.service)" = activating ]; then
        echo "Bootstrap is still running; not starting another. Try: make wait-ready"; exit 1
      fi
      sudo google_metadata_script_runner startup' || return 1

  local stage
  stage=$(gcloud compute instances get-guest-attributes "${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --query-path="devbox/stage" \
    --format="value(value)" 2>/dev/null || true)
  echo "    Final bootstrap stage: ${stage:-unknown}"
  [[ "${stage}" == ready* && "${stage}" != "ready-tailscale-failed" ]]
}

run_on_vm_steps() {
  local changed_file
  changed_file=$(mktemp -u)
  run_step "Update secrets in Secret Manager" env SECRETS_CHANGED_FILE="${changed_file}" "${MAKE}" --no-print-directory init-secrets
  if [[ -f "${changed_file}" ]]; then
    rm -f "${changed_file}"
    run_step "Push secrets to VM (restarts Wideboi)" sub_make push-secrets
  else
    skip_step "Push secrets to VM" "no secret changes"
  fi
  run_step "Push Claude memories" sub_make push-memories
  run_step "Upgrade Wideboi" sub_make upgrade-wideboi
}

STATUS=$(gcloud compute instances describe "${INSTANCE_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --format="value(status)" 2>/dev/null || true)
echo "==> ${INSTANCE_NAME} status: ${STATUS:-not found}"

if [[ -z "${STATUS}" ]]; then
  echo "Instance does not exist. Run 'make up' to create it."
  exit 1
fi

run_step "Push startup.sh to instance metadata" sub_make update-startup

if [[ "${STATUS}" == "RUNNING" ]] && ! local_tailscale_running; then
  echo ""
  echo "==> Tailscale is not running on this machine; can't reach the VM."
  echo "    Start it (e.g. 'tailscale up' or the menu bar app) and re-run 'make update'."
  skip_step "Push secrets & Claude memories to VM" "local Tailscale stopped"
  skip_step "Upgrade Wideboi" "local Tailscale stopped"
  FAILED=1
elif is_reachable; then
  run_on_vm_steps
elif [[ "${STATUS}" == "RUNNING" ]]; then
  echo ""
  echo "==> VM is RUNNING but not reachable over Tailscale; bootstrap likely failed."
  run_step "Re-run bootstrap via IAP SSH" rerun_bootstrap
  echo ""
  echo "==> Waiting for the VM to come up on Tailscale..."
  if wait_reachable; then
    run_on_vm_steps
  else
    skip_step "Push secrets & Claude memories to VM" "VM still unreachable"
    skip_step "Upgrade Wideboi" "VM still unreachable"
  fi
else
  echo ""
  echo "==> VM is ${STATUS}; on-VM updates will apply on next start."
  run_step "Update secrets in Secret Manager" sub_make init-secrets
  skip_step "Push secrets & Claude memories to VM" "VM ${STATUS}"
  skip_step "Upgrade Wideboi" "VM ${STATUS}"
fi

echo ""
echo "==> Update summary:"
printf '%s\n' "${RESULTS[@]}"
if [[ "${STATUS}" == "RUNNING" ]]; then
  echo ""
  echo "Note: if the bootstrap wasn't re-run, startup.sh changes take effect on the next boot."
fi

exit "${FAILED}"
