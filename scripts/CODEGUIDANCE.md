# Code Guidance

```

### Required Files
- `docker-cloud-init.yml`: Cloud-init configuration for Docker installation
- `../docker-compose.yml`: Selenium Grid stack definition

## Usage

```bash
bash dropletsetup.sh -n <num_nodes> -s <swarm_manager_name> -k <ssh_key_fingerprint>
```

### Parameters
- `-n`: Number of droplets to create (e.g., 3)
- `-s`: Name of the droplet that will act as Swarm manager (e.g., node-1)
- `-k`: SSH key fingerprint registered in your DigitalOcean account

### Example
```bash
bash dropletsetup.sh -n 3 -s node-1 -k ab:cd:ef:12:34:56:78:90
```

## Step-by-Step Process

### Step 1: Script Initialization
```bash
set -euo pipefail
```
**What it does:** Sets strict error handling
- `e`: Exit immediately if any command fails
- `u`: Treat unset variables as an error
- `o pipefail`: Fail if any command in a pipeline fails

### Step 2: Helper Functions

#### 2.1 Usage Function
```bash
usage() {
  echo "Usage: $0 -n <num_nodes> -s <swarm_manager_name> -k <ssh_key_fingerprint>"
  exit 1
}
```
**Purpose:** Displays command usage and exits with error code 1

#### 2.2 Logging Function
```bash
log() {
  echo ""
  echo "===> $*"
}
```
**Purpose:** Provides formatted logging output with visual separators

#### 2.3 Docker Readiness Check
```bash
wait_for_docker() {
  local ip="$1"
  local retries=30
  local delay=10
  # ... retry loop with SSH docker info test
}
```
**Purpose:** 
- Waits up to 5 minutes (30 × 10s) for Docker to be ready on remote host
- Uses SSH to test `docker info` command
- Exits with error if Docker doesn't become available

#### 2.4 IP Resolution Function
```bash
get_droplet_ip() {
  local name="$1"
  doctl compute droplet list --format "Name,PublicIPv4" --no-header \
    | awk -v n="$name" '$1 == n { print $2 }'
}
```
**Purpose:** 
- Uses DigitalOcean CLI to get droplet's public IP
- Filters by droplet name using AWK

### Step 3: Argument Parsing
```bash
while getopts "n:s:k:" flag; do
  case "${flag}" in
    n) nodes="${OPTARG}" ;;
    s) swarmnode="${OPTARG}" ;;
    k) ssh_key="${OPTARG}" ;;
    *) usage ;;
  esac
done
```
**Purpose:**
- Parses command-line arguments using `getopts`
- Validates all required parameters are provided
- Checks for DigitalOcean API token environment variable
- Verifies cloud-init configuration file exists

### Step 4: Droplet Provisioning
```bash
for i in $(seq 1 "${nodes}"); do
  droplet_name="node-${i}"
  
  # Check if droplet already exists
  existing=$(doctl compute droplet list --format Name --no-header | grep -x "${droplet_name}" || true)
  if [[ -n "${existing}" ]]; then
    echo "Droplet '${droplet_name}' already exists — skipping creation."
    continue
  fi
  
  # Create new droplet
  doctl compute droplet create "${droplet_name}" \
    --image "ubuntu-22-04-x64" \
    --region "nyc1" \
    --size "s-4vcpu-8gb" \
    --ssh-keys "${ssh_key}" \
    --user-data-file "${CLOUD_INIT_FILE}" \
    --wait
done
```
**Purpose:**
- Creates droplets named `node-1`, `node-2`, etc.
- Skips creation if droplet already exists
- Uses Ubuntu 22.04 with 4 vCPUs and 8GB RAM
- Deploys in NYC1 region
- Applies cloud-init configuration for Docker setup
- Waits for droplet to be fully created

### Step 5: IP Resolution and Docker Readiness
```bash
# Create associative array for droplet IPs
declare -A DROPLET_IPS

# Resolve IPs for all droplets
for i in $(seq 1 "${nodes}"); do
  name="node-${i}"
  ip=$(get_droplet_ip "${name}")
  DROPLET_IPS["${name}"]="${ip}"
  echo "  ${name} -> ${ip}"
done

# Store manager IP
MANAGER_IP="${DROPLET_IPS[${swarmnode}]}"

# Wait for Docker on all nodes
for i in $(seq 1 "${nodes}"); do
  wait_for_docker "${DROPLET_IPS[node-${i}]}"
done
```
**Purpose:**
- Creates associative array to store droplet IPs
- Resolves public IP for each droplet
- Identifies the manager node IP
- Waits for Docker to be ready on all nodes (cloud-init installs Docker asynchronously)

### Step 6: Docker Swarm Initialization
```bash
# Initialize swarm on manager node
ssh -o StrictHostKeyChecking=no "root@${MANAGER_IP}" \
  "docker swarm init --advertise-addr ${MANAGER_IP}" || true

# Drain manager node from workload scheduling
ssh -o StrictHostKeyChecking=no "root@${MANAGER_IP}" \
  "docker node update --availability drain ${swarmnode}"
```
**Purpose:**
- Initializes Docker Swarm on the manager node
- Uses `|| true` to ignore errors if swarm already exists
- Drains manager node so it only handles control plane tasks, not workloads

### Step 7: Worker Token Retrieval
```bash
TOKEN=$(ssh -o StrictHostKeyChecking=no "root@${MANAGER_IP}" \
  "docker swarm join-token worker -q")
```
**Purpose:**
- Retrieves the join token for worker nodes
- `-q` flag returns only the token (quiet mode)

### Step 8: Worker Node Joining
```bash
for i in $(seq 1 "${nodes}"); do
  name="node-${i}"
  ip="${DROPLET_IPS[${name}]}"

  # Skip manager node
  if [[ "${name}" == "${swarmnode}" ]]; then
    echo "Skipping manager node ${swarmnode}."
    continue
  fi

  # Join worker to swarm
  ssh -o StrictHostKeyChecking=no "root@${ip}" \
    "docker swarm join --token ${TOKEN} ${MANAGER_IP}:2377"
done
```
**Purpose:**
- Loops through all nodes except the manager
- Joins each worker node to the swarm using the token
- Uses port 2377 (Docker Swarm management port)

### Step 9: Local Docker Context Setup
```bash
CONTEXT_NAME="kronos-swarm"

# Remove existing context if present
docker context rm "${CONTEXT_NAME}" 2>/dev/null || true

# Create new context pointing to swarm manager
docker context create "${CONTEXT_NAME}" \
  --description "Kronos Selenium Grid Swarm manager" \
  --docker "host=ssh://root@${MANAGER_IP}"

# Switch to the new context
docker context use "${CONTEXT_NAME}"
```
**Purpose:**
- Creates a local Docker context pointing to the remote swarm
- Removes any existing context with same name
- Sets up SSH connection to manager node
- Switches to this context for subsequent Docker commands

### Step 10: Selenium Grid Deployment
```bash
COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose.yml"

# Deploy the stack
docker --context "${CONTEXT_NAME}" stack deploy \
  --compose-file "${COMPOSE_FILE}" \
  selenium

# Scale browser services
docker --context "${CONTEXT_NAME}" service scale \
  selenium_chrome=2 \
  selenium_firefox=2
```
**Purpose:**
- Deploys Docker stack using compose file
- Creates Selenium Grid services across the swarm
- Scales Chrome and Firefox services to 2 instances each

### Step 11: Completion and Output
```bash
log "Deployment complete!"
echo ""
echo "  Selenium Grid console : http://${MANAGER_IP}:4444"
echo "  Docker context        : ${CONTEXT_NAME}"
echo ""
echo "To manage the swarm locally:"
echo "  docker --context ${CONTEXT_NAME} node ls"
echo "  docker --context ${CONTEXT_NAME} service ls"
```
**Purpose:**
- Provides success confirmation
- Shows Selenium Grid console URL (port 4444)
- Gives commands for managing the swarm locally

## Key Technical Concepts

### Infrastructure as Code
- **Automated Provisioning**: Uses DigitalOcean API to create infrastructure
- **Idempotent Operations**: Skips creation if resources already exist
- **Configuration Management**: Uses cloud-init for automated setup

### Container Orchestration
- **Docker Swarm**: Manages containers across multiple nodes
- **Service Discovery**: Automatic networking between services
- **Load Balancing**: Built-in load balancing for scaled services

### Remote Management
- **Docker Contexts**: Manage remote Docker daemons from local machine
- **SSH Tunneling**: Secure communication with remote nodes
- **Centralized Control**: Single point of management for distributed infrastructure

### Error Handling and Reliability
- **Retry Logic**: Waits for services to become available
- **Validation**: Comprehensive parameter and environment checking
- **Graceful Degradation**: Handles existing resources appropriately

## Troubleshooting

### Common Issues

1. **Permission Denied on Docker**
   ```bash
   sudo usermod -aG docker $USER
   newgrp docker
   ```

2. **DigitalOcean API Issues**
   - Verify `DO_API_ACCESS_TOKEN` is set correctly
   - Check API token permissions in DigitalOcean dashboard

3. **SSH Key Issues**
   - Ensure SSH key is added to your DigitalOcean account
   - Verify fingerprint matches the key in your account

4. **Cloud-init Timeout**
   - Check `docker-cloud-init.yml` is present and valid
   - Monitor droplet console for cloud-init logs

### Management Commands

After deployment, use these commands to manage your swarm:

```bash
# List all nodes in the swarm
docker --context kronos-swarm node ls

# List all services
docker --context kronos-swarm service ls

# Check service logs
docker --context kronos-swarm service logs selenium_chrome

# Scale services
docker --context kronos-swarm service scale selenium_chrome=4

# Remove the entire stack
docker --context kronos-swarm stack rm selenium

# Switch back to local Docker context
docker context use default
```

## Security Considerations

- **SSH Security**: Script disables SSH host key checking for automation
- **Root Access**: Uses root user for simplified container management
- **Network Security**: Consider firewall rules for production deployments
- **Token Storage**: Keep DigitalOcean API tokens secure and rotate regularly

## Cost Management

- **Resource Sizing**: Default uses `s-4vcpu-8gb` droplets
- **Auto-scaling**: Manually scale services based on testing load
- **Cleanup**: Use `destroy.sh` script to remove resources when done