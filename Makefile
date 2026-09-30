# Load optional local .env if present (gitignored)
-include .env

# Defaults
PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
ZONE ?= us-central1-a
REGION ?= $(shell echo $(ZONE) | sed 's/-[a-z]$$//')
INSTANCE_NAME ?= wideboi-sandbox
MACHINE_TYPE ?= e2-standard-8
BOOT_DISK_SIZE ?= 100GB
BOOT_DISK_TYPE ?= pd-balanced

# Custom Image Configuration & Auto-Detection
CUSTOM_IMAGE_FAMILY ?= devbox-base
CUSTOM_IMAGE_EXISTS := $(shell gcloud compute images describe-from-family $(CUSTOM_IMAGE_FAMILY) --project=$(PROJECT_ID) --format="value(name)" 2>/dev/null)

ifeq ($(USE_CUSTOM_IMAGE),false)
  IMAGE_FAMILY = ubuntu-2404-lts-amd64
  IMAGE_PROJECT = ubuntu-os-cloud
else ifneq ($(CUSTOM_IMAGE_EXISTS),)
  # Automatically select devbox-base if it exists, unless user explicitly set a non-stock family
  ifeq ($(filter-out ubuntu-2404-lts-amd64,$(IMAGE_FAMILY)),)
    IMAGE_FAMILY = $(CUSTOM_IMAGE_FAMILY)
    IMAGE_PROJECT = $(PROJECT_ID)
  endif
else
  IMAGE_FAMILY ?= ubuntu-2404-lts-amd64
  IMAGE_PROJECT ?= ubuntu-os-cloud
endif

IMAGE_FAMILY ?= ubuntu-2404-lts-amd64
IMAGE_PROJECT ?= ubuntu-os-cloud

# Builder VM settings for baking custom images
BUILDER_INSTANCE_NAME ?= devbox-builder
BUILDER_BASE_FAMILY ?= ubuntu-2404-lts-amd64
BUILDER_BASE_PROJECT ?= ubuntu-os-cloud

# Network Configuration (defaults to dedicated 'devbox-net' VPC)
NETWORK ?= devbox-net
SUBNET ?= devbox-subnet
SUBNET_RANGE ?= 10.10.0.0/24

# Flags for network
NET_FLAGS = --network=$(NETWORK) --subnet=$(SUBNET)

# Idle auto-stop hours (default 2; 0 to disable)
AUTO_STOP_HOURS ?= 2

# Service Account for the devbox instance
SA_NAME ?= devbox-runner
SA_EMAIL = $(SA_NAME)@$(PROJECT_ID).iam.gserviceaccount.com

# Target user inside the VM
DEV_USER ?= lmorchard
DEV_HOME = /home/$(DEV_USER)

# Tailscale Hostname
TAILSCALE_HOSTNAME ?= $(INSTANCE_NAME)

.PHONY: help init-secrets sync-secrets push-memories pull-memories sync-memories up do-up down stop start status ssh web logs clean bake-image list-images clean-images

help:
	@echo "wideboi-sandbox management commands:"
	@echo "  make init-secrets  - Interactive wizard to populate GCP Secret Manager"
	@echo "  make sync-secrets  - Push updated .env secrets & Claude memories to running VM"
	@echo "  make push-memories - Sync local Claude global context & project memories to VM"
	@echo "  make pull-memories - Pull updated Claude memories & journal from VM to local Mac"
	@echo "  make bake-image    - Pre-bake custom GCE image in '$(CUSTOM_IMAGE_FAMILY)' family"
	@echo "  make list-images   - List images in '$(CUSTOM_IMAGE_FAMILY)' family"
	@echo "  make clean-images  - Delete older images in '$(CUSTOM_IMAGE_FAMILY)', keeping latest"
	@echo "  make up            - Create and bootstrap the ephemeral VM"
	@echo "  make ssh           - SSH into the VM via Tailscale (or fallback to gcloud)"
	@echo "  make web           - Open Wideboi's web UI over Tailscale in your browser"
	@echo "  make upgrade-wideboi - Hot-upgrade running Wideboi server to latest rolling build"
	@echo "  make status        - Check VM and startup progress"
	@echo "  make logs          - Tail the startup script log"
	@echo "  make stop          - Stop VM (compute billing paused, disk remains if kept)"
	@echo "  make start         - Start stopped VM"
	@echo "  make down          - Destroy the VM (stops all compute & disk billing)"
	@echo "  make destroy-infra - Destroy VM, VPC network, subnet, and runner service account"

# Verify GCP Project is set
check-project:
	@if [ -z "$(PROJECT_ID)" ]; then \
		echo "Error: PROJECT_ID not set. Run 'gcloud config set project <PROJECT_ID>'"; \
		exit 1; \
	fi

# 1. Secret Manager Wizard
init-secrets: check-project
	@chmod +x scripts/init-secrets.sh
	@scripts/init-secrets.sh

# Helper to find current Tailscale IP of the active instance
get-ts-ip = $(shell tailscale status --json 2>/dev/null | jq -r '.Peer[] | select(.HostName | startswith("$(TAILSCALE_HOSTNAME)")) | select(.Online == true) | .TailscaleIPs[0]' | head -n1)

# 1b. Sync secrets to Secret Manager and running VM in-place
sync-secrets: init-secrets
	@TS_IP="$(call get-ts-ip)"; \
	TARGET="$${TS_IP:-$(TAILSCALE_HOSTNAME)}"; \
	if tailscale ping --until-direct=false -c 1 "$$TARGET" >/dev/null 2>&1; then \
		echo "==> Syncing updated secrets to active VM ($$TARGET)..."; \
		chmod +x scripts/sync-secrets-to-vm.sh scripts/sync-claude.sh; \
		scripts/sync-secrets-to-vm.sh "$$TARGET" "$(DEV_USER)" "$(PROJECT_ID)"; \
		scripts/sync-claude.sh push "$$TARGET" "$(DEV_USER)"; \
	else \
		echo "==> VM is not currently reachable over Tailscale. Secrets updated in Secret Manager only."; \
	fi

# 1c. Sync Claude Code context & project memories (push/pull)
push-memories: check-project
	@TS_IP="$(call get-ts-ip)"; \
	TARGET="$${TS_IP:-$(TAILSCALE_HOSTNAME)}"; \
	chmod +x scripts/sync-claude.sh; \
	scripts/sync-claude.sh push "$$TARGET" "$(DEV_USER)"

pull-memories: check-project
	@TS_IP="$(call get-ts-ip)"; \
	TARGET="$${TS_IP:-$(TAILSCALE_HOSTNAME)}"; \
	chmod +x scripts/sync-claude.sh; \
	scripts/sync-claude.sh pull "$$TARGET" "$(DEV_USER)"

sync-memories: push-memories

# 2. Network & Subnet Setup (dedicated VPC with internet gateway access)
ensure-network: check-project
	@if ! gcloud compute networks describe $(NETWORK) --project=$(PROJECT_ID) >/dev/null 2>&1; then \
		echo "==> Creating dedicated VPC network '$(NETWORK)'..."; \
		gcloud compute networks create $(NETWORK) --project=$(PROJECT_ID) --subnet-mode=custom; \
	fi
	@if ! gcloud compute networks subnets describe $(SUBNET) --region=$(REGION) --project=$(PROJECT_ID) >/dev/null 2>&1; then \
		echo "==> Creating subnet '$(SUBNET)' in $(REGION)..."; \
		gcloud compute networks subnets create $(SUBNET) \
			--project=$(PROJECT_ID) \
			--network=$(NETWORK) \
			--region=$(REGION) \
			--range=$(SUBNET_RANGE); \
	fi
	@if ! gcloud compute firewall-rules describe $(NETWORK)-allow-internal --project=$(PROJECT_ID) >/dev/null 2>&1; then \
		echo "==> Creating default internal firewall rule..."; \
		gcloud compute firewall-rules create $(NETWORK)-allow-internal \
			--project=$(PROJECT_ID) \
			--network=$(NETWORK) \
			--allow=tcp,udp,icmp \
			--source-ranges=$(SUBNET_RANGE); \
	fi
	@if ! gcloud compute firewall-rules describe $(NETWORK)-allow-iap-ssh --project=$(PROJECT_ID) >/dev/null 2>&1; then \
		echo "==> Creating firewall rule for GCP IAP SSH tunnel..."; \
		gcloud compute firewall-rules create $(NETWORK)-allow-iap-ssh \
			--project=$(PROJECT_ID) \
			--network=$(NETWORK) \
			--allow=tcp:22 \
			--source-ranges=35.235.240.0/20; \
	fi

# 3. Service Account Setup (ensures SA exists and has Secret Manager Secret Accessor role)
ensure-sa: check-project
	@echo "==> Ensuring service account $(SA_EMAIL) exists..."
	@gcloud iam service-accounts describe $(SA_EMAIL) --project=$(PROJECT_ID) >/dev/null 2>&1 || \
		gcloud iam service-accounts create $(SA_NAME) \
			--display-name="Devbox Instance Runner" \
			--project=$(PROJECT_ID)
	@echo "==> Granting roles/secretmanager.secretAccessor..."
	@gcloud projects add-iam-policy-binding $(PROJECT_ID) \
		--member="serviceAccount:$(SA_EMAIL)" \
		--role="roles/secretmanager.secretAccessor" \
		--condition=None --quiet >/dev/null

# 3b. Pre-bake custom GCE image
bake-image: check-project ensure-network
	@if gcloud compute instances describe $(BUILDER_INSTANCE_NAME) --project=$(PROJECT_ID) --zone=$(ZONE) >/dev/null 2>&1; then \
		echo "Error: $(BUILDER_INSTANCE_NAME) already exists. Delete it first with 'gcloud compute instances delete $(BUILDER_INSTANCE_NAME) --zone=$(ZONE)'"; \
		exit 1; \
	fi
	@echo "==> Pre-baking image in family '$(CUSTOM_IMAGE_FAMILY)'..."
	@IMAGE_NAME="$(CUSTOM_IMAGE_FAMILY)-$$(date +%Y%m%d%H%M)"; \
	echo "==> Target image name: $$IMAGE_NAME"; \
	echo "==> Launching builder instance '$(BUILDER_INSTANCE_NAME)' in $(ZONE)..."; \
	gcloud compute instances create $(BUILDER_INSTANCE_NAME) \
		--project=$(PROJECT_ID) \
		--zone=$(ZONE) \
		--machine-type=$(MACHINE_TYPE) \
		--image-family=$(BUILDER_BASE_FAMILY) \
		--image-project=$(BUILDER_BASE_PROJECT) \
		--boot-disk-size=$(BOOT_DISK_SIZE) \
		--boot-disk-type=$(BOOT_DISK_TYPE) \
		--boot-disk-auto-delete \
		$(NET_FLAGS) \
		--metadata-from-file=startup-script=scripts/bake.sh \
		--metadata=enable-guest-attributes=TRUE,dev-user=$(DEV_USER) || exit 1; \
	echo "==> Tracking image bake stages:"; \
	last_stage=""; \
	bake_ok=0; \
	for i in $$(seq 1 180); do \
		stage=$$(gcloud compute instances get-guest-attributes $(BUILDER_INSTANCE_NAME) \
			--project=$(PROJECT_ID) \
			--zone=$(ZONE) \
			--query-path="devbox/bake-stage" \
			--format="value(value)" 2>/dev/null || true); \
		status=$$(gcloud compute instances get-guest-attributes $(BUILDER_INSTANCE_NAME) \
			--project=$(PROJECT_ID) \
			--zone=$(ZONE) \
			--query-path="devbox/bake-status" \
			--format="value(value)" 2>/dev/null || true); \
		if [ -n "$$stage" ] && [ "$$stage" != "$$last_stage" ]; then \
			echo "    [stage] $$stage"; \
			last_stage="$$stage"; \
		fi; \
		if [ "$$status" = "complete" ] || [ "$$stage" = "complete" ]; then \
			echo "    [stage] image bake complete!"; \
			bake_ok=1; \
			break; \
		elif [ "$$status" = "failed" ]; then \
			echo "❌ Image bake script failed. Streaming serial port log:"; \
			gcloud compute instances get-serial-port-output $(BUILDER_INSTANCE_NAME) \
				--project=$(PROJECT_ID) \
				--zone=$(ZONE) || true; \
			break; \
		fi; \
		sleep 3; \
	done; \
	if [ "$$bake_ok" -ne 1 ]; then \
		echo "❌ Bake failed or timed out. Fetching serial logs before cleanup:"; \
		gcloud compute instances get-serial-port-output $(BUILDER_INSTANCE_NAME) \
			--project=$(PROJECT_ID) \
			--zone=$(ZONE) || true; \
		echo "==> Cleaning up builder instance..."; \
		gcloud compute instances delete $(BUILDER_INSTANCE_NAME) --project=$(PROJECT_ID) --zone=$(ZONE) --quiet || true; \
		exit 1; \
	fi; \
	echo "==> Stopping builder instance before creating image..."; \
	gcloud compute instances stop $(BUILDER_INSTANCE_NAME) --project=$(PROJECT_ID) --zone=$(ZONE) --quiet || { \
		echo "❌ Failed to stop builder instance. Retaining instance for inspection."; \
		exit 1; \
	}; \
	echo "==> Creating custom image '$$IMAGE_NAME'..."; \
	gcloud compute images create "$$IMAGE_NAME" \
		--project=$(PROJECT_ID) \
		--source-disk=$(BUILDER_INSTANCE_NAME) \
		--source-disk-zone=$(ZONE) \
		--family=$(CUSTOM_IMAGE_FAMILY) \
		--quiet || { \
		echo "❌ Failed to create image '$$IMAGE_NAME'. Retaining builder instance for inspection."; \
		exit 1; \
	}; \
	echo "==> Deleting builder instance '$(BUILDER_INSTANCE_NAME)'..."; \
	gcloud compute instances delete $(BUILDER_INSTANCE_NAME) --project=$(PROJECT_ID) --zone=$(ZONE) --quiet; \
	echo "==> Successfully baked image '$$IMAGE_NAME' in family '$(CUSTOM_IMAGE_FAMILY)'!"

# List images in custom image family
list-images: check-project
	@echo "==> Images in family '$(CUSTOM_IMAGE_FAMILY)':"
	@gcloud compute images list \
		--project=$(PROJECT_ID) \
		--filter="family=$(CUSTOM_IMAGE_FAMILY)" \
		--format="table(name,family,creationTimestamp,status)"

# Clean older images in custom image family (keeps latest)
clean-images: check-project
	@echo "==> Checking for older images in family '$(CUSTOM_IMAGE_FAMILY)' to prune..."
	@IMAGES=$$(gcloud compute images list \
		--project=$(PROJECT_ID) \
		--filter="family=$(CUSTOM_IMAGE_FAMILY)" \
		--sort-by="~creationTimestamp" \
		--format="value(name)") || { \
		echo "Error: Failed to list images in project $(PROJECT_ID)"; \
		exit 1; \
	}; \
	TOTAL=$$(echo "$$IMAGES" | grep -v '^$$' | wc -l | tr -d ' '); \
	if [ "$$TOTAL" -le 1 ]; then \
		echo "==> No older images to clean up (total images: $$TOTAL)."; \
	else \
		LATEST=$$(echo "$$IMAGES" | head -n 1); \
		OLDER=$$(echo "$$IMAGES" | tail -n +2); \
		echo "==> Keeping latest image: $$LATEST"; \
		echo "==> Deleting older image(s):"; \
		for img in $$OLDER; do \
			echo "    - Deleting $$img..."; \
			gcloud compute images delete "$$img" --project=$(PROJECT_ID) --quiet || exit 1; \
		done; \
		echo "==> Cleanup complete."; \
	fi

# 4. Spin up ephemeral VM
up: check-project
	@STATUS=$$(gcloud compute instances describe $(INSTANCE_NAME) --project=$(PROJECT_ID) --zone=$(ZONE) --format="value(status)" 2>/dev/null || true); \
	if [ -n "$$STATUS" ]; then \
		if [ "$$STATUS" = "RUNNING" ]; then \
			stage=$$(gcloud compute instances get-guest-attributes $(INSTANCE_NAME) \
				--project=$(PROJECT_ID) --zone=$(ZONE) \
				--query-path="devbox/stage" \
				--format="value(value)" 2>/dev/null || true); \
			if [ "$$stage" != "ready" ]; then \
				echo "==> Instance '$(INSTANCE_NAME)' is already running (bootstrap stage: $${stage:-starting}). Resuming progress tracking..."; \
				$(MAKE) wait-ready; \
				exit 0; \
			else \
				echo "==> Instance '$(INSTANCE_NAME)' is already running and ready!"; \
				echo "    SSH:     make ssh (or: ssh $(DEV_USER)@$(TAILSCALE_HOSTNAME))"; \
				echo "    Web UI:  make web (or: http://$(TAILSCALE_HOSTNAME):8080)"; \
				echo "    Status:  make status"; \
				echo "    Down:    make down (to destroy and recreate)"; \
				exit 0; \
			fi; \
		elif [ "$$STATUS" = "TERMINATED" ] || [ "$$STATUS" = "STOPPED" ]; then \
			echo "==> Instance '$(INSTANCE_NAME)' already exists but is stopped (status: $$STATUS)."; \
			echo "    Start:   make start (to resume)"; \
			echo "    Down:    make down (to destroy and recreate)"; \
			exit 1; \
		else \
			echo "==> Instance '$(INSTANCE_NAME)' already exists with status: $$STATUS."; \
			echo "    Wait a moment or run 'make down' to recreate."; \
			exit 1; \
		fi; \
	fi; \
	$(MAKE) do-up

do-up: init-secrets ensure-network ensure-sa
	@echo "==> Launching $(INSTANCE_NAME) in $(ZONE)..."
	@echo "    Using image: $(IMAGE_FAMILY) (project: $(IMAGE_PROJECT))"
	gcloud compute instances create $(INSTANCE_NAME) \
		--project=$(PROJECT_ID) \
		--zone=$(ZONE) \
		--machine-type=$(MACHINE_TYPE) \
		--image-family=$(IMAGE_FAMILY) \
		--image-project=$(IMAGE_PROJECT) \
		--boot-disk-size=$(BOOT_DISK_SIZE) \
		--boot-disk-type=$(BOOT_DISK_TYPE) \
		--boot-disk-auto-delete \
		$(NET_FLAGS) \
		--service-account=$(SA_EMAIL) \
		--scopes=cloud-platform \
		--metadata-from-file=startup-script=startup.sh \
		--metadata=enable-oslogin=TRUE,enable-guest-attributes=TRUE,VmDnsSetting=ZonalOnly,auto-stop-hours=$(AUTO_STOP_HOURS),dev-user=$(DEV_USER),tailscale-hostname=$(TAILSCALE_HOSTNAME)
	@echo ""
	@echo "Instance created. Waiting for bootstrap to complete and Tailscale to connect..."
	@$(MAKE) wait-ready
	@echo ""
	@echo "==> Devbox is READY!"
	@echo "    SSH:     make ssh (or: ssh $(DEV_USER)@$(TAILSCALE_HOSTNAME))"
	@echo "    Web UI:  make web (or: http://$(TAILSCALE_HOSTNAME):8080)"

# Wait for instance to become responsive and show stage progress
wait-ready:
	@echo "==> Tracking bootstrap stages:"
	@last_stage=""; \
	for i in $$(seq 1 120); do \
		stage=$$(gcloud compute instances get-guest-attributes $(INSTANCE_NAME) \
			--project=$(PROJECT_ID) \
			--zone=$(ZONE) \
			--query-path="devbox/stage" \
			--format="value(value)" 2>/dev/null || true); \
		if [ -n "$$stage" ] && [ "$$stage" != "$$last_stage" ]; then \
			echo "    [stage] $$stage"; \
			last_stage="$$stage"; \
		fi; \
		if [ "$$stage" = "ready" ]; then \
			echo "    [stage] bootstrap complete!"; \
			warnings=$$(gcloud compute instances get-guest-attributes $(INSTANCE_NAME) \
				--project=$(PROJECT_ID) \
				--zone=$(ZONE) \
				--query-path="devbox/warnings" \
				--format="value(value)" 2>/dev/null || true); \
			if [ -n "$$warnings" ]; then \
				echo ""; \
				echo "⚠️  WARNINGS during bootstrap:"; \
				echo "    $$warnings"; \
			fi; \
			exit 0; \
		elif [ "$$stage" = "ready-tailscale-failed" ]; then \
			echo ""; \
			echo "❌ [ERROR] Tailscale failed to connect during bootstrap. Run 'make logs' to inspect."; \
			exit 1; \
		fi; \
		sleep 3; \
	done; \
	echo "Timed out waiting for readiness. Run 'make logs' to inspect."; \
	exit 1

# Helper to find current Tailscale IP of the active instance
get-ts-ip = $(shell tailscale status --json 2>/dev/null | jq -r '.Peer[] | select(.HostName | startswith("$(TAILSCALE_HOSTNAME)")) | select(.Online == true) | .TailscaleIPs[0]' | head -n1)

# 5. SSH Access (auto-resolves active Tailscale IP)
ssh:
	@TS_IP="$(call get-ts-ip)"; \
	if [ -n "$$TS_IP" ]; then \
		echo "==> Connecting to $$TS_IP..."; \
		ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null $(DEV_USER)@$$TS_IP; \
	elif tailscale ping -c 1 $(TAILSCALE_HOSTNAME) >/dev/null 2>&1; then \
		echo "==> Connecting via $(TAILSCALE_HOSTNAME)..."; \
		ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null $(DEV_USER)@$(TAILSCALE_HOSTNAME); \
	else \
		echo "==> Tailscale not reachable yet; falling back to gcloud IAP tunnel..."; \
		gcloud compute ssh $(DEV_USER)@$(INSTANCE_NAME) --zone=$(ZONE) --tunnel-through-iap; \
	fi

# 5. Open Web UI (with token hash if WIDEBOI_TOKEN is configured)
web:
	@TS_IP="$(call get-ts-ip)"; \
	TARGET="$${TS_IP:-$(TAILSCALE_HOSTNAME)}"; \
	TOKEN_FRAGMENT=""; \
	if [ -n "$(WIDEBOI_TOKEN)" ]; then \
		TOKEN_FRAGMENT="#token=$(WIDEBOI_TOKEN)"; \
	fi; \
	URL="http://$$TARGET:8080/$$TOKEN_FRAGMENT"; \
	echo "==> Opening Wideboi web UI at $$URL ..."; \
	open "$$URL" 2>/dev/null || xdg-open "$$URL" 2>/dev/null || echo "Open $$URL in your browser."

# Upgrade wideboi in-place without dropping sessions or processes
upgrade-wideboi:
	@TS_IP="$(call get-ts-ip)"; \
	TARGET="$${TS_IP:-$(TAILSCALE_HOSTNAME)}"; \
	echo "==> Upgrading Wideboi on $$TARGET to latest rolling release..."; \
	ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null $(DEV_USER)@$$TARGET \
		"bash -c 'set -e; \
		TMP_DIR=\$$(mktemp -d); \
		curl -fsSL https://github.com/lmorchard/wideboi/releases/download/rolling/wideboi_rolling_linux_amd64.tar.gz -o \$$TMP_DIR/wideboi.tar.gz; \
		tar -C \$$TMP_DIR -xzf \$$TMP_DIR/wideboi.tar.gz; \
		sudo install -m 0755 \$$TMP_DIR/wideboi /usr/local/bin/wideboi; \
		wideboi upgrade-server /usr/local/bin/wideboi || systemctl --user restart wideboi.service; \
		rm -rf \$$TMP_DIR; \
		echo \"Wideboi upgraded to:\"; \
		wideboi version'"

# 6. Monitor startup logs (stream live serial port output, non-interactive)
logs: check-project
	@echo "==> Streaming live startup logs from $(INSTANCE_NAME) (Ctrl+C to exit)..."
	gcloud compute instances tail-serial-port-output $(INSTANCE_NAME) \
		--project=$(PROJECT_ID) \
		--zone=$(ZONE)

# 7. Check instance status
status: check-project
	gcloud compute instances describe $(INSTANCE_NAME) \
		--project=$(PROJECT_ID) \
		--zone=$(ZONE) \
		--format="table(name,status,machineType.basename(),zone.basename())"

# 8. Temporary stop (compute stops, billing paused)
stop: check-project
	gcloud compute instances stop $(INSTANCE_NAME) --project=$(PROJECT_ID) --zone=$(ZONE) --quiet

# 9. Resume stopped instance
start: check-project
	@echo "==> Resuming $(INSTANCE_NAME) in $(ZONE)..."
	gcloud compute instances start $(INSTANCE_NAME) --project=$(PROJECT_ID) --zone=$(ZONE) --quiet
	@echo ""
	@echo "Instance resumed. Waiting for bootstrap to complete and Tailscale to connect..."
	@sleep 5
	@$(MAKE) wait-ready
	@echo ""
	@echo "==> Devbox is READY!"
	@echo "    SSH:     make ssh (or: ssh $(DEV_USER)@$(TAILSCALE_HOSTNAME))"
	@echo "    Web UI:  make web (or: http://$(TAILSCALE_HOSTNAME):8080)"

# 10. Delete VM instance (stopping all compute/disk costs)
down: check-project
	@echo "==> Terminating $(INSTANCE_NAME)..."
	@gcloud compute instances describe $(INSTANCE_NAME) --project=$(PROJECT_ID) --zone=$(ZONE) >/dev/null 2>&1 && \
		gcloud compute instances delete $(INSTANCE_NAME) \
			--project=$(PROJECT_ID) \
			--zone=$(ZONE) \
			--quiet || echo "Instance '$(INSTANCE_NAME)' does not exist."

# 11. Complete teardown of all devbox infrastructure (VPC, subnet, firewall, SA)
destroy-infra: down
	@echo "==> Deleting firewall rules for $(NETWORK)..."
	@gcloud compute firewall-rules describe $(NETWORK)-allow-internal --project=$(PROJECT_ID) >/dev/null 2>&1 && \
		gcloud compute firewall-rules delete $(NETWORK)-allow-internal --project=$(PROJECT_ID) --quiet || true
	@echo "==> Deleting subnet $(SUBNET)..."
	@gcloud compute networks subnets describe $(SUBNET) --region=$(REGION) --project=$(PROJECT_ID) >/dev/null 2>&1 && \
		gcloud compute networks subnets delete $(SUBNET) --region=$(REGION) --project=$(PROJECT_ID) --quiet || true
	@echo "==> Deleting VPC network $(NETWORK)..."
	@gcloud compute networks describe $(NETWORK) --project=$(PROJECT_ID) >/dev/null 2>&1 && \
		gcloud compute networks delete $(NETWORK) --project=$(PROJECT_ID) --quiet || true
	@echo "==> Deleting service account $(SA_EMAIL)..."
	@gcloud iam service-accounts describe $(SA_EMAIL) --project=$(PROJECT_ID) >/dev/null 2>&1 && \
		gcloud iam service-accounts delete $(SA_EMAIL) --project=$(PROJECT_ID) --quiet || true
	@echo "==> All devbox infrastructure removed."
