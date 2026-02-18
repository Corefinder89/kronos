#!/bin/bash
# dropletsetup.sh
#
# Provisions DigitalOcean droplets, initialises a Docker Swarm, and deploys
# the Selenium Grid stack.
#
# Dependencies (must be installed and configured locally):
#   - doctl  : DigitalOcean CLI  (https://docs.digitalocean.com/reference/doctl/)
#   - jq     : JSON processor    (https://stedolan.github.io/jq/)
#   - docker : Docker CLI        (for context management and stack deploy)
#
# Usage:
#   export DO_API_ACCESS_TOKEN=<your_token>
#   bash dropletsetup.sh -n <num_nodes> -s <swarm_manager_name> -k <ssh_key_fingerprint>
#
# Example:
#   bash dropletsetup.sh -n 3 -s node-1 -k ab:cd:ef:...

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
  echo "Usage: $0 -n <num_nodes> -s <swarm_manager_name> -k <ssh_key_fingerprint>"
  echo ""
  echo "  -n  Number of droplets to create (e.g. 3)"
  echo "  -s  Name of the droplet that will act as Swarm manager (e.g. node-1)"
  echo "  -k  SSH key fingerprint registered in your DigitalOcean account"
  echo ""
  echo "Environment variables:"
  echo "  DO_API_ACCESS_TOKEN  Your DigitalOcean personal access token (required)"
  exit 1
}

log() {
  echo ""
  echo "===> $*"
}
  
# Wait until Docker is reachable on a remote host via SSH.
wait_for_docker() {
  local ip="$1"
  local retries=30
  local delay=10

  log "Waiting for Docker to be ready on ${ip}..."
  for ((i = 1; i <= retries; i++)); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@${ip}" \
        "docker info > /dev/null 2>&1"; then
      echo "Docker is ready on ${ip}."
      return 0
    fi
    echo "  Attempt ${i}/${retries} — retrying in ${delay}s..."
    sleep "${delay}"
  done

  echo "ERROR: Docker did not become ready on ${ip} after $((retries * delay))s." >&2
  exit 1
}

# Resolve the public IPv4 of a droplet by its name using doctl.
get_droplet_ip() {
  local name="$1"
  doctl compute droplet list --format "Name,PublicIPv4" --no-header \
    | awk -v n="$name" '$1 == n { print $2 }'
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

nodes=""
swarmnode=""
ssh_key=""

while getopts "n:s:k:" flag; do
  case "${flag}" in
    n) nodes="${OPTARG}" ;;
    s) swarmnode="${OPTARG}" ;;
    k) ssh_key="${OPTARG}" ;;
    *) usage ;;
  esac
done

[[ -z "${nodes}"     ]] && { echo "ERROR: -n (num_nodes) is required.";           usage; }
[[ -z "${swarmnode}" ]] && { echo "ERROR: -s (swarm_manager_name) is required.";  usage; }
[[ -z "${ssh_key}"   ]] && { echo "ERROR: -k (ssh_key_fingerprint) is required."; usage; }
[[ -z "${DO_API_ACCESS_TOKEN:-}" ]] && { echo "ERROR: DO_API_ACCESS_TOKEN is not set."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT_FILE="${SCRIPT_DIR}/docker-cloud-init.yml"

[[ ! -f "${CLOUD_INIT_FILE}" ]] && {
  echo "ERROR: cloud-init file not found at ${CLOUD_INIT_FILE}"
  exit 1
}

# ---------------------------------------------------------------------------
# 1. Provision droplets
# ---------------------------------------------------------------------------

log "Creating ${nodes} droplet(s)..."

for i in $(seq 1 "${nodes}"); do
  droplet_name="node-${i}"

  # Skip creation if the droplet already exists
  existing=$(doctl compute droplet list --format Name --no-header | grep -x "${droplet_name}" || true)
  if [[ -n "${existing}" ]]; then
    echo "Droplet '${droplet_name}' already exists — skipping creation."
    continue
  fi

  echo "Creating droplet: ${droplet_name}"
  doctl compute droplet create "${droplet_name}" \
    --image    "ubuntu-22-04-x64" \
    --region   "nyc1" \
    --size     "s-4vcpu-8gb" \
    --ssh-keys "${ssh_key}" \
    --user-data-file "${CLOUD_INIT_FILE}" \
    --wait \
    --no-header
done

# ---------------------------------------------------------------------------
# 2. Resolve IPs and wait for Docker to be ready on all nodes
# ---------------------------------------------------------------------------

log "Resolving droplet IPs..."

declare -A DROPLET_IPS

for i in $(seq 1 "${nodes}"); do
  name="node-${i}"
  ip=$(get_droplet_ip "${name}")
  if [[ -z "${ip}" ]]; then
    echo "ERROR: Could not resolve IP for '${name}'." >&2
    exit 1
  fi
  DROPLET_IPS["${name}"]="${ip}"
  echo "  ${name} -> ${ip}"
done

MANAGER_IP="${DROPLET_IPS[${swarmnode}]}"

# Wait for Docker on every node (cloud-init runs asynchronously after boot)
for i in $(seq 1 "${nodes}"); do
  wait_for_docker "${DROPLET_IPS[node-${i}]}"
done

# ---------------------------------------------------------------------------
# 3. Initialise Docker Swarm on the manager node
# ---------------------------------------------------------------------------

log "Initialising Docker Swarm on ${swarmnode} (${MANAGER_IP})..."

ssh -o StrictHostKeyChecking=no "root@${MANAGER_IP}" \
  "docker swarm init --advertise-addr ${MANAGER_IP}" || true   # 'true' tolerates already-initialised swarm

# Drain the manager so it only schedules control-plane work
log "Draining manager node ${swarmnode} from workload scheduling..."
ssh -o StrictHostKeyChecking=no "root@${MANAGER_IP}" \
  "docker node update --availability drain ${swarmnode}"

# ---------------------------------------------------------------------------
# 4. Retrieve the worker join token
# ---------------------------------------------------------------------------

log "Retrieving Swarm worker join token..."
TOKEN=$(ssh -o StrictHostKeyChecking=no "root@${MANAGER_IP}" \
  "docker swarm join-token worker -q")

# ---------------------------------------------------------------------------
# 5. Join all worker nodes to the Swarm
# ---------------------------------------------------------------------------

log "Joining worker nodes to the Swarm..."

for i in $(seq 1 "${nodes}"); do
  name="node-${i}"
  ip="${DROPLET_IPS[${name}]}"

  if [[ "${name}" == "${swarmnode}" ]]; then
    echo "Skipping manager node ${swarmnode}."
    continue
  fi

  echo "Joining ${name} (${ip}) to the Swarm..."
  ssh -o StrictHostKeyChecking=no "root@${ip}" \
    "docker swarm join --token ${TOKEN} ${MANAGER_IP}:2377"
done

# ---------------------------------------------------------------------------
# 6. Create a local Docker context pointing at the Swarm manager
# ---------------------------------------------------------------------------

CONTEXT_NAME="kronos-swarm"

log "Creating Docker context '${CONTEXT_NAME}' -> ssh://root@${MANAGER_IP}..."

# Remove stale context if it exists
docker context rm "${CONTEXT_NAME}" 2>/dev/null || true

docker context create "${CONTEXT_NAME}" \
  --description "Kronos Selenium Grid Swarm manager" \
  --docker "host=ssh://root@${MANAGER_IP}"

docker context use "${CONTEXT_NAME}"

# ---------------------------------------------------------------------------
# 7. Deploy the Selenium Grid stack
# ---------------------------------------------------------------------------

COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose.yml"

log "Deploying Selenium Grid stack..."
docker --context "${CONTEXT_NAME}" stack deploy \
  --compose-file "${COMPOSE_FILE}" \
  selenium

log "Scaling Selenium nodes..."
docker --context "${CONTEXT_NAME}" service scale \
  selenium_chrome=2 \
  selenium_firefox=2

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

log "Deployment complete!"
echo ""
echo "  Selenium Grid console : http://${MANAGER_IP}:4444"
echo "  Docker context        : ${CONTEXT_NAME}"
echo ""
echo "To manage the swarm locally:"
echo "  docker --context ${CONTEXT_NAME} node ls"
echo "  docker --context ${CONTEXT_NAME} service ls"
