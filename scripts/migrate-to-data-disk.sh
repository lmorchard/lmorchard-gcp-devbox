#!/usr/bin/env bash
#
# migrate-to-data-disk.sh: Live, non-destructive migration of $HOME (and optional Docker)
# to a persistent secondary GCE data disk.
#
# Can be run from a local development machine or from inside the VM.
#
set -euo pipefail

TAILSCALE_HOSTNAME="${1:-wideboi-sandbox}"
INSTANCE_NAME="${2:-wideboi-sandbox}"
PROJECT_ID="${3:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${4:-us-central1-a}"
DEV_USER="${5:-lmorchard}"
DATA_DISK_NAME="${6:-devbox-data}"
DATA_DISK_SIZE="${7:-150GB}"
DATA_DISK_TYPE="${8:-pd-balanced}"
MIGRATE_DOCKER="${9:-0}"
SAFETY_SNAPSHOT="${SAFETY_SNAPSHOT:-1}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Error: PROJECT_ID not set. Run 'gcloud config set project <PROJECT_ID>'";
  exit 1;
fi

echo "================================================================"
echo "Devbox Data Migration to Persistent Secondary Disk"
echo "================================================================"
echo "  Target Instance:   ${INSTANCE_NAME} (${ZONE})"
echo "  Target User:       ${DEV_USER}"
echo "  Persistent Disk:   ${DATA_DISK_NAME} (${DATA_DISK_SIZE}, ${DATA_DISK_TYPE})"
echo "  Migrate Docker:    $([[ "${MIGRATE_DOCKER}" == "1" ]] && echo "Yes" || echo "No (fresh Docker cache)")"
echo "  Safety Snapshot:   $([[ "${SAFETY_SNAPSHOT}" == "1" ]] && echo "Yes" || echo "Skipped")"
echo "================================================================"

# Check if we are running inside the VM or remotely
INSIDE_VM=0
CURRENT_HOST=$(hostname 2>/dev/null || true)
if [[ "${CURRENT_HOST}" == "${TAILSCALE_HOSTNAME}" ]] || [[ "${CURRENT_HOST}" == "${INSTANCE_NAME}" ]]; then
  INSIDE_VM=1
fi

# 1. Ensure persistent disk exists
echo "==> [1/5] Checking persistent disk '${DATA_DISK_NAME}' in ${ZONE}..."
if ! gcloud compute disks describe "${DATA_DISK_NAME}" --project="${PROJECT_ID}" --zone="${ZONE}" >/dev/null 2>&1; then
  echo "    Creating disk '${DATA_DISK_NAME}' (${DATA_DISK_SIZE}, ${DATA_DISK_TYPE})..."
  gcloud compute disks create "${DATA_DISK_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --size="${DATA_DISK_SIZE}" \
    --type="${DATA_DISK_TYPE}" || {
      echo "❌ Failed to create disk ${DATA_DISK_NAME}";
      exit 1;
    }
else
  echo "    Disk '${DATA_DISK_NAME}' already exists."
fi

# 2. Safety snapshot of current boot disk before migration
if [[ "${SAFETY_SNAPSHOT}" == "1" ]]; then
  SNAPSHOT_NAME="${INSTANCE_NAME}-pre-migration-$(date +%Y%m%d%H%M%S)"
  echo "==> [2/5] Creating safety snapshot '${SNAPSHOT_NAME}' of current boot disk..."
  gcloud compute disks snapshot "${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --snapshot-names="${SNAPSHOT_NAME}" \
    --quiet || echo "⚠️  Warning: Safety snapshot failed; continuing migration..."
else
  echo "==> [2/5] Skipping safety snapshot (SAFETY_SNAPSHOT=0)."
fi

# 3. Hot-attach disk to running instance if not already attached
echo "==> [3/5] Checking if disk '${DATA_DISK_NAME}' is attached to ${INSTANCE_NAME}..."
ATTACHED_DISKS=$(gcloud compute instances describe "${INSTANCE_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --format="value(disks[].source)" 2>/dev/null || true)

if ! echo "${ATTACHED_DISKS}" | grep -q "${DATA_DISK_NAME}"; then
  echo "    Hot-attaching '${DATA_DISK_NAME}' to ${INSTANCE_NAME}..."
  gcloud compute instances attach-disk "${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --disk="${DATA_DISK_NAME}" \
    --device-name="${DATA_DISK_NAME}" \
    --mode=rw || {
      echo "❌ Failed to attach disk ${DATA_DISK_NAME} to ${INSTANCE_NAME}";
      exit 1;
    }
else
  echo "    Disk '${DATA_DISK_NAME}' is already attached."
fi

# 4. In-Guest Migration Commands
echo "==> [4/5] Running in-guest filesystem preparation and rsync..."

GUEST_SCRIPT=$(cat <<EOF
set -euo pipefail

DATA_DISK_NAME="${DATA_DISK_NAME}"
DEV_USER="${DEV_USER}"
MIGRATE_DOCKER="${MIGRATE_DOCKER}"
DEV_HOME="/home/\${DEV_USER}"
MOUNT_POINT="/mnt/disks/\${DATA_DISK_NAME}"
DISK_DEV="/dev/disk/by-id/google-\${DATA_DISK_NAME}"

echo "    Waiting for device \${DISK_DEV}..."
disk_found=0
for i in \$(seq 1 30); do
  if [[ -e "\${DISK_DEV}" ]]; then
    disk_found=1
    break
  fi
  sleep 1
done

if [[ "\${disk_found}" -ne 1 ]]; then
  echo "❌ Device \${DISK_DEV} not found after 30s!"
  exit 1
fi

# Format if unformatted
if ! blkid "\${DISK_DEV}" >/dev/null 2>&1; then
  echo "    Formatting \${DISK_DEV} with ext4..."
  mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard "\${DISK_DEV}"
fi

mkdir -p "\${MOUNT_POINT}"
if ! mountpoint -q "\${MOUNT_POINT}"; then
  echo "    Mounting \${DISK_DEV} at \${MOUNT_POINT}..."
  mount -o discard,defaults "\${DISK_DEV}" "\${MOUNT_POINT}"
fi

mkdir -p "\${MOUNT_POINT}/home" "\${MOUNT_POINT}/docker"

echo "    Starting rsync of \${DEV_HOME}/ -> \${MOUNT_POINT}/home/ ..."
echo "    (Source directory remains 100% read-only and unmutated)"
rsync -aHAX --info=progress2 "\${DEV_HOME}/" "\${MOUNT_POINT}/home/"

USER_UID=\$(id -u "\${DEV_USER}")
USER_GID=\$(id -g "\${DEV_USER}")
chown "\${USER_UID}:\${USER_GID}" "\${MOUNT_POINT}/home"

if [[ "\${MIGRATE_DOCKER}" == "1" && -d /var/lib/docker ]]; then
  echo "    Stopping Docker for clean container layer rsync..."
  systemctl stop docker containerd || true
  rsync -aHAX --info=progress2 /var/lib/docker/ "\${MOUNT_POINT}/docker/"
  systemctl start docker || true
fi

echo ""
echo "    Verification:"
echo "      Source home size:      \$(du -sh "\${DEV_HOME}" 2>/dev/null | awk '{print \$1}')"
echo "      Persistent disk home:  \$(du -sh "\${MOUNT_POINT}/home" 2>/dev/null | awk '{print \$1}')"
echo "      Numeric ownership:     \$(stat -c '%u:%g' "\${MOUNT_POINT}/home")"
EOF
)

if [[ "${INSIDE_VM}" -eq 1 ]]; then
  echo "${GUEST_SCRIPT}" | sudo bash
else
  # Resolve Tailscale IP or fall back to gcloud SSH
  TS_IP=$(tailscale status --json 2>/dev/null | jq -r --arg h "${TAILSCALE_HOSTNAME}" '.Peer[] | select(.HostName | startswith($h)) | select(.Online == true) | .TailscaleIPs[0]' | head -n1 || true)
  TARGET="${TS_IP:-${TAILSCALE_HOSTNAME}}"

  if tailscale ping --until-direct=false -c 1 "${TARGET}" >/dev/null 2>&1; then
    echo "    Connecting over Tailscale to ${TARGET}..."
    ssh -o StrictHostKeyChecking=accept-new "${DEV_USER}@${TARGET}" "sudo bash -s" <<< "${GUEST_SCRIPT}"
  else
    echo "    Tailscale not reachable; connecting via gcloud IAP tunnel..."
    gcloud compute ssh "${DEV_USER}@${INSTANCE_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --tunnel-through-iap \
      --command="sudo bash -s" <<< "${GUEST_SCRIPT}"
  fi
fi

echo "==> [5/5] Migration Complete!"
echo ""
echo "✅ All data from /home/${DEV_USER} is safely synchronized to persistent disk '${DATA_DISK_NAME}'."
echo ""
echo "Next steps:"
echo "  1. Add or set in your local .env:"
echo "       PERSISTENT_DATA_DISK=true"
echo "       DATA_DISK_NAME=${DATA_DISK_NAME}"
echo "       DATA_DISK_SIZE=${DATA_DISK_SIZE}"
echo "       DATA_DISK_TYPE=${DATA_DISK_TYPE}"
echo ""
echo "  2. When you are ready to recreate the devbox or pause work:"
echo "       make down    # Safely detaches '${DATA_DISK_NAME}' and pauses compute costs (\$0.00)"
echo "       make up      # Automatically boots new VM with '${DATA_DISK_NAME}' mounted"
