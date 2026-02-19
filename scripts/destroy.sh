#!/bin/bash
# destroy.sh
#
# Tears down all Swarm droplets (any droplet named node-*), removes the
# Selenium Grid stack, and cleans up the local Docker context.
#
# Usage:
#   export DO_API_ACCESS_TOKEN=<your_token>
#   bash destroy.sh

set -euo pipefail

CONTEXT_NAME="kronos-swarm"

log() {
  echo ""
  echo "===> $*"
}

# Check if a Docker context exists and remove it if it does
remove_docker_context_if_exists() {
  local context_name="$1"
  if docker context ls --format "{{.Name}}" | grep -q "^${context_name}$"; then
    log "Removing existing Docker context '${context_name}'..."
    docker context rm -f "${context_name}"
    echo "Docker context '${context_name}' has been removed."
  else
    echo "Docker context '${context_name}' does not exist."
  fi
}

[[ -z "${DO_API_ACCESS_TOKEN:-}" ]] && { echo "ERROR: DO_API_ACCESS_TOKEN is not set."; exit 1; }

# ---------------------------------------------------------------------------
# 1. Remove the Selenium Grid stack (best-effort — context may be gone)
# ---------------------------------------------------------------------------

log "Removing Selenium Grid stack (if reachable)..."
if docker context inspect "${CONTEXT_NAME}" > /dev/null 2>&1; then
  docker --context "${CONTEXT_NAME}" stack rm selenium 2>/dev/null || true
  echo "Stack removed."
else
  echo "Context '${CONTEXT_NAME}' not found — skipping stack removal."
fi

# ---------------------------------------------------------------------------
# 2. Remove local Docker contexts
# ---------------------------------------------------------------------------

remove_docker_context_if_exists "${CONTEXT_NAME}"
remove_docker_context_if_exists "docker-swarm"

# ---------------------------------------------------------------------------
# 3. Delete all node-* droplets from DigitalOcean
# ---------------------------------------------------------------------------

log "Discovering node-* droplets..."

# Fetch all droplets whose name starts with "node-"
mapfile -t droplet_ids < <(
  doctl compute droplet list --format "ID,Name" --no-header \
    | awk '$2 ~ /^node-/ { print $1 }'
)

if [[ ${#droplet_ids[@]} -eq 0 ]]; then
  echo "No node-* droplets found. Nothing to delete."
else
  echo "Found ${#droplet_ids[@]} droplet(s) to delete."
  for id in "${droplet_ids[@]}"; do
    name=$(doctl compute droplet get "${id}" --format Name --no-header)
    echo "Deleting '${name}' (ID: ${id})..."
    doctl compute droplet delete "${id}" --force
  done
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

log "All done! Swarm droplets destroyed and local context removed."
