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

---

# Health Check Script (`healthcheck.sh`)

## Overview

The `healthcheck.sh` script provides comprehensive health monitoring and automatic repair capabilities for Kronos Selenium Grid deployments. It performs end-to-end validation from DigitalOcean droplets to Selenium Grid connectivity and can automatically fix common issues.

### Required Dependencies
- `doctl`: DigitalOcean CLI for droplet management
- `docker`: Docker CLI with context support for Swarm management
- `curl`: HTTP client for Grid connectivity testing
- `jq`: JSON processor (optional, for enhanced Grid status parsing)

## Usage

```bash
# Check-only mode (safe, no modifications)
export DO_API_ACCESS_TOKEN=<your_token>
bash scripts/healthcheck.sh

# Auto-repair mode (fixes issues automatically)
bash scripts/healthcheck.sh --fix

# Display help information
bash scripts/healthcheck.sh --help
```

### Parameters
- `--fix`: Enable automatic repair mode (default: check-only)
- `--help`: Display usage information and exit

### Example
```bash
export DO_API_ACCESS_TOKEN=dop_v1_abc123...
bash scripts/healthcheck.sh --fix
```

## Step-by-Step Process

### Step 1: Script Configuration
```bash
MANAGER_NODE="node-1"
GRID_PORT="4444"
DOCKER_CONTEXT="kronos-swarm"
STACK_NAME="selenium"
COMPOSE_FILE="docker-compose.yml"
```
**What it does:** Sets configuration constants for consistent operation across all health checks and repairs

### Step 2: Dependency Validation
```bash
check_dependencies() {
    local missing_deps=()
    command -v doctl >/dev/null 2>&1 || missing_deps+=("doctl")
    command -v docker >/dev/null 2>&1 || missing_deps+=("docker")
    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
}
```
**Purpose:**
- Validates all required CLI tools are installed
- Checks for DigitalOcean API token environment variable
- Exits with clear error message if dependencies are missing

### Step 3: DigitalOcean Droplets Health Check
```bash
check_droplets() {
    local droplets
    droplets=$(doctl compute droplet list --format Name,PublicIPv4,Status --no-header)
    
    while IFS= read -r line; do
        if [[ $line =~ ^node-[0-9]+ ]]; then
            # Process each Kronos node...
        fi
    done <<< "$droplets"
}
```
**Purpose:**
- Lists all DigitalOcean droplets using `doctl`
- Filters for Kronos nodes (named `node-*`)
- Validates each node is in "active" status
- Reports count of active vs total nodes

### Step 4: Docker Context Validation
```bash
check_docker_context() {
    if docker context inspect "$DOCKER_CONTEXT" >/dev/null 2>&1; then
        log_success "Docker context '$DOCKER_CONTEXT' exists"
        return 0
    else
        log_warning "Docker context '$DOCKER_CONTEXT' does not exist"
        return 1
    fi
}
```
**Purpose:**
- Verifies the `kronos-swarm` Docker context exists
- Tests if context can connect to remote Swarm manager
- Essential for managing remote Docker services

### Step 5: Docker Swarm Status Check
```bash
check_swarm_status() {
    local swarm_info
    swarm_info=$(docker --context "$DOCKER_CONTEXT" node ls --format "table {{.ID}}\t{{.Hostname}}\t{{.Status}}\t{{.Availability}}\t{{.ManagerStatus}}")
    
    # Check if manager node is drained...
}
```
**Purpose:**
- Connects to remote Swarm and lists all nodes
- Identifies manager node and checks availability status
- Detects if manager is "drained" (cannot schedule workloads)
- Critical for service deployment capability

### Step 6: Selenium Services Health Check
```bash
check_selenium_services() {
    local services
    services=$(docker --context "$DOCKER_CONTEXT" service ls --format "table {{.Name}}\t{{.Replicas}}")
    
    local expected_services=("${STACK_NAME}_hub" "${STACK_NAME}_chrome" "${STACK_NAME}_firefox")
    # Validate each service exists and is running...
}
```
**Purpose:**
- Lists all Docker Swarm services
- Validates required Selenium services exist (`selenium_hub`, `selenium_chrome`, `selenium_firefox`)
- Checks replica counts (e.g., `1/1` = healthy, `0/1` = failed)
- Identifies missing or failed services

### Step 7: Grid Connectivity Test
```bash
check_grid_connectivity() {
    local manager_ip
    manager_ip=$(get_manager_ip)
    
    local grid_url="http://${manager_ip}:${GRID_PORT}/wd/hub/status"
    local response
    response=$(curl -s --connect-timeout 5 --max-time 10 "$grid_url")
}
```
**Purpose:**
- Tests HTTP connectivity to Selenium Grid hub
- Fetches Grid status JSON from `/wd/hub/status` endpoint
- Parses response to check if Grid is ready and count connected nodes
- Validates end-to-end functionality

## Auto-Repair Functions

### Docker Context Repair
```bash
repair_docker_context() {
    local manager_ip
    manager_ip=$(get_manager_ip)
    
    # Remove existing context if it exists
    docker context rm "$DOCKER_CONTEXT" >/dev/null 2>&1 || true
    
    # Create new context
    docker context create "$DOCKER_CONTEXT" --docker "host=ssh://root@${manager_ip}"
}
```
**Purpose:**
- Recreates Docker context pointing to current manager IP
- Handles cases where context is corrupted or pointing to wrong IP
- Essential when droplets are recreated with new IPs

### Swarm Manager Activation
```bash
repair_swarm_manager() {
    local manager_id
    manager_id=$(docker --context "$DOCKER_CONTEXT" node ls --filter "role=manager" --format "{{.ID}}" | head -1)
    
    docker --context "$DOCKER_CONTEXT" node update --availability active "$manager_id"
}
```
**Purpose:**
- Undrains the manager node to allow workload scheduling
- Required when manager is set to "drain" mode (cannot run containers)
- Enables hub service to run on manager node

### Selenium Services Deployment
```bash
repair_selenium_services() {
    docker --context "$DOCKER_CONTEXT" stack deploy --compose-file "$COMPOSE_FILE" "$STACK_NAME"
    
    # Force restart stuck services
    local services=("${STACK_NAME}_hub" "${STACK_NAME}_chrome" "${STACK_NAME}_firefox")
    for service in "${services[@]}"; do
        docker --context "$DOCKER_CONTEXT" service update --force "$service" >/dev/null 2>&1 || true
    done
}
```
**Purpose:**
- Redeploys Selenium Grid stack using Docker Compose
- Force-updates individual services that may be stuck
- Waits for services to stabilize before proceeding

## Error Handling and Logging

### Colored Output System
```bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'

log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
```
**Purpose:**
- Provides color-coded status messages for clear visual feedback
- Distinguishes between success, warning, error, and informational messages
- Improves user experience during health checks

### Graceful Error Handling
- Uses `set -euo pipefail` for strict error handling
- Each function returns proper exit codes (0 = success, 1 = failure)
- Continues checking all components even if some fail
- Provides actionable repair suggestions for each issue type

## Security Considerations

- **SSH Security**: Uses `StrictHostKeyChecking=no` for automation (same as dropletsetup.sh)
- **API Token**: Validates DO_API_ACCESS_TOKEN is set but doesn't log its value
- **Network Security**: Connects to Grid on public IP (consider VPN for production)
- **Force Operations**: Auto-repair mode performs potentially destructive operations

---

# Manager Fix Script (`fix-manager.sh`)

## Overview

The `fix-manager.sh` script provides targeted repair for Docker Swarm manager node drainage issues. When the manager node becomes "drained" (unable to schedule workloads), this script automatically undrains it and restarts all Selenium Grid services to restore full functionality.

### Required Dependencies
- `docker`: Docker CLI with `kronos-swarm` context configured
- `doctl`: DigitalOcean CLI for droplet management
- `jq`: JSON processor (optional, for enhanced Grid status parsing)

## Usage

```bash
# Standard manager fix and service restart
export DO_API_ACCESS_TOKEN=<your_token>
bash scripts/fix-manager.sh

# Via Makefile (recommended)
make fix-manager
```

### Environment Variables
- `DO_API_ACCESS_TOKEN`: DigitalOcean personal access token (required)

### Example
```bash
export DO_API_ACCESS_TOKEN=dop_v1_abc123...
bash scripts/fix-manager.sh
```

## Step-by-Step Process

### Step 1: Script Configuration
```bash
DOCKER_CONTEXT="kronos-swarm"
STACK_NAME="selenium"
COMPOSE_FILE="docker-compose.yml"
```
**What it does:** Sets configuration constants for consistent operation with existing Kronos infrastructure

### Step 2: Dependency Validation
```bash
check_dependencies() {
    command -v docker >/dev/null 2>&1 || { log_error "docker is required but not installed"; exit 1; }
    command -v doctl >/dev/null 2>&1 || { log_error "doctl is required but not installed"; exit 1; }
    
    if [[ -z "${DO_API_ACCESS_TOKEN:-}" ]]; then
        log_error "DO_API_ACCESS_TOKEN environment variable not set"
        exit 1
    fi
}
```
**Purpose:**
- Validates Docker CLI is available for Swarm management
- Ensures DigitalOcean CLI is installed for IP resolution
- Checks for required API token environment variable
- Exits with clear error messages if dependencies are missing

### Step 3: Docker Context Validation
```bash
check_docker_context() {
    if ! docker context inspect "$DOCKER_CONTEXT" >/dev/null 2>&1; then
        log_error "Docker context '$DOCKER_CONTEXT' does not exist"
        log_info "Run 'bash scripts/healthcheck.sh --fix' to recreate the context"
        exit 1
    fi
}
```
**Purpose:**
- Verifies the `kronos-swarm` Docker context exists and is accessible
- Provides helpful suggestion to run healthcheck if context is missing
- Essential for remote Docker Swarm operations

### Step 4: Manager Node Information Extraction
```bash
get_manager_node_info() {
    local swarm_info
    swarm_info=$(docker --context "$DOCKER_CONTEXT" node ls --format "{{.ID}} {{.Hostname}} {{.Status}} {{.Availability}} {{.ManagerStatus}}")
    
    while IFS= read -r line; do
        if [[ $line =~ Leader ]]; then
            manager_id=$(echo "$line" | awk '{print $1}')
            manager_hostname=$(echo "$line" | awk '{print $2}')
            manager_availability=$(echo "$line" | awk '{print $4}')
            break
        fi
    done <<< "$swarm_info"
}
```
**Purpose:**
- Connects to remote Docker Swarm and lists all nodes
- Identifies the leader manager node (primary Swarm manager)
- Extracts manager ID, hostname, and availability status
- Returns structured information for downstream processing

### Step 5: Manager Drainage Detection
```bash
check_manager_status() {
    local manager_info
    manager_info=$(get_manager_node_info)
    
    local manager_availability=$(echo "$manager_info" | cut -d'|' -f3)
    
    if [[ "$manager_availability" == "Drain" ]]; then
        log_warning "Manager node is drained (cannot schedule workloads)"
        return 1
    else
        log_success "Manager node is active"
        return 0
    fi
}
```
**Purpose:**
- Checks if manager node availability is set to "Drain"
- Drained nodes cannot schedule new containers or services
- Returns appropriate exit code for conditional logic
- Provides clear status messages for user feedback

### Step 6: Manager Node Repair
```bash
fix_manager_node() {
    local manager_info
    manager_info=$(get_manager_node_info)
    local manager_id=$(echo "$manager_info" | cut -d'|' -f1)
    
    log_info "Undraining manager node (ID: $manager_id)..."
    docker --context "$DOCKER_CONTEXT" node update --availability active "$manager_id"
}
```
**Purpose:**
- Updates manager node availability from "Drain" to "Active"
- Enables the manager to schedule workloads again
- Critical for hub service deployment (hub runs on manager)
- Uses node ID for precise targeting

### Step 7: Selenium Services Restart
```bash
restart_selenium_services() {
    # Check if stack exists and deploy/redeploy
    if ! docker --context "$DOCKER_CONTEXT" stack ls | grep -q "$STACK_NAME"; then
        log_warning "Selenium stack not found, deploying fresh..."
        docker --context "$DOCKER_CONTEXT" stack deploy --compose-file "$COMPOSE_FILE" "$STACK_NAME"
    else
        log_info "Redeploying existing Selenium stack..."
        docker --context "$DOCKER_CONTEXT" stack deploy --compose-file "$COMPOSE_FILE" "$STACK_NAME"
    fi
    
    # Force restart all services
    local services=("${STACK_NAME}_hub" "${STACK_NAME}_chrome" "${STACK_NAME}_firefox")
    for service in "${services[@]}"; do
        docker --context "$DOCKER_CONTEXT" service update --force "$service"
    done
}
```
**Purpose:**
- Redeploys entire Selenium Grid stack from docker-compose.yml
- Handles both fresh deployment and existing stack updates
- Force-updates individual services to ensure restart
- Includes stabilization delays for service initialization

### Step 8: Service Health Verification
```bash
verify_services() {
    local services
    services=$(docker --context "$DOCKER_CONTEXT" service ls --format "{{.Name}} {{.Replicas}}")
    
    local expected_services=("${STACK_NAME}_hub" "${STACK_NAME}_chrome" "${STACK_NAME}_firefox")
    
    for expected_service in "${expected_services[@]}"; do
        local replicas
        replicas=$(echo "$services" | grep "^$expected_service" | awk '{print $2}')
        if [[ $replicas =~ ^[1-9]/[1-9] ]]; then
            log_success "✓ $expected_service: $replicas"
        else
            log_warning "⚠ $expected_service: $replicas (not running)"
        fi
    done
}
```
**Purpose:**
- Validates all required Selenium services are running
- Checks replica counts (e.g., `1/1` = healthy, `0/1` = failed)
- Provides visual status indicators (✓ for success, ⚠ for warnings)
- Returns aggregate health status for overall verification

### Step 9: Grid Connectivity Testing
```bash
test_grid_connectivity() {
    # Get manager IP for Grid access
    local manager_ip
    manager_ip=$(doctl compute droplet list --format Name,PublicIPv4 --no-header | grep "^node-1 " | awk '{print $2}')
    
    local grid_url="http://${manager_ip}:4444/wd/hub/status"
    local response
    
    if response=$(curl -s --connect-timeout 5 --max-time 10 "$grid_url"); then
        # Parse Grid status with jq if available
        if command -v jq >/dev/null 2>&1; then
            local ready=$(echo "$response" | jq -r '.value.ready // false')
            local node_count=$(echo "$response" | jq -r '.value.nodes | length')
            
            if [[ "$ready" == "true" ]]; then
                log_success "Grid status: ready with $node_count nodes"
            else
                log_warning "Grid status: not ready (nodes connecting: $node_count)"
            fi
        fi
    fi
}
```
**Purpose:**
- Tests end-to-end HTTP connectivity to Selenium Grid hub
- Resolves manager IP dynamically using DigitalOcean API
- Fetches Grid status from `/wd/hub/status` endpoint
- Parses JSON response to show ready status and node count
- Validates complete functionality chain from Docker → Grid → HTTP

## Error Handling and Logging

### Colored Output System
```bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
```
**Purpose:**
- Provides color-coded status messages for clear visual feedback
- Distinguishes between informational, success, warning, and error states
- Improves troubleshooting experience with immediate visual status

### Comprehensive Workflow
The script follows a complete workflow:
1. **Validation** → Dependencies and Docker context
2. **Detection** → Manager drainage status
3. **Repair** → Undrain manager if needed
4. **Restart** → Redeploy all Selenium services
5. **Verification** → Validate services and Grid connectivity
6. **Reporting** → Summary with next steps

## When to Use fix-manager.sh

### Primary Use Cases
- **Manager Drainage**: When `docker node ls` shows manager as "Drain"
- **Service Scheduling Failures**: When hub service cannot start due to manager constraints
- **Post-Maintenance**: After DigitalOcean droplet maintenance that affects manager
- **Grid Connectivity Issues**: When healthcheck passes but Grid is not accessible

### Integration with Other Scripts
- **Healthcheck Integration**: Run `make health-fix` for comprehensive issues
- **Targeted Repair**: Use `make fix-manager` for specific manager problems
- **Testing Workflow**: Follow with `make test` to validate Grid functionality

### Comparison with healthcheck.sh
- **healthcheck.sh**: Comprehensive 5-step validation and repair (droplets → context → swarm → services → connectivity)
- **fix-manager.sh**: Targeted manager drainage repair with service restart focus
- **Use healthcheck.sh** for unknown issues or full infrastructure validation
- **Use fix-manager.sh** for known manager drainage or service restart needs

## Security Considerations

- **SSH Context**: Relies on existing `kronos-swarm` Docker context (created by healthcheck.sh)
- **API Token**: Validates DO_API_ACCESS_TOKEN but doesn't log token value
- **Force Operations**: Performs service restarts that may interrupt running tests
- **Network Access**: Connects to Grid on public IP (same security model as healthcheck.sh)

---

# Destroy Script (`destroy.sh`)

## Overview

The `destroy.sh` script provides complete teardown of Kronos Selenium Grid infrastructure. It safely removes Docker Swarm services, cleans up local Docker contexts, and deletes all DigitalOcean droplets, ensuring no resources are left running.

### Required Dependencies
- `doctl`: DigitalOcean CLI for droplet management
- `docker`: Docker CLI for context and stack management

## Usage

```bash
export DO_API_ACCESS_TOKEN=<your_token>
bash scripts/destroy.sh
```

### Environment Variables
- `DO_API_ACCESS_TOKEN`: DigitalOcean personal access token (required)

### Example
```bash
export DO_API_ACCESS_TOKEN=dop_v1_abc123...
bash scripts/destroy.sh
```

## Step-by-Step Process

### Step 1: Script Initialization
```bash
set -euo pipefail
CONTEXT_NAME="kronos-swarm"
```
**What it does:**
- Sets strict error handling (exit on any failure)
- Defines the target Docker context name
- Validates DigitalOcean API token is set

### Step 2: Selenium Grid Stack Removal
```bash
log "Removing Selenium Grid stack (if reachable)..."
if docker context inspect "${CONTEXT_NAME}" > /dev/null 2>&1; then
  docker --context "${CONTEXT_NAME}" stack rm selenium 2>/dev/null || true
  echo "Stack removed."
else
  echo "Context '${CONTEXT_NAME}' not found — skipping stack removal."
fi
```
**Purpose:**
- Attempts to remove the `selenium` Docker stack from remote Swarm
- Gracefully handles cases where context is already missing
- Uses `|| true` to continue even if stack removal fails
- Prevents orphaned containers and networks

### Step 3: Docker Context Cleanup
```bash
remove_docker_context_if_exists() {
  local context_name="$1"
  if docker context ls --format "{{.Name}}" | grep -q "^${context_name}$"; then
    docker context rm -f "${context_name}"
  fi
}

remove_docker_context_if_exists "${CONTEXT_NAME}"
remove_docker_context_if_exists "docker-swarm"
```
**Purpose:**
- Removes local Docker contexts that point to the Swarm
- Handles both `kronos-swarm` and legacy `docker-swarm` contexts
- Uses force flag (`-f`) to remove contexts even if they're in use
- Prevents stale context references

### Step 4: DigitalOcean Droplet Discovery
```bash
mapfile -t droplet_ids < <(
  doctl compute droplet list --format "ID,Name" --no-header \
    | awk '$2 ~ /^node-/ { print $1 }'
)
```
**Purpose:**
- Uses `doctl` to list all droplets in the account
- Filters for droplets with names starting with `node-` using AWK regex
- Collects droplet IDs into an array for batch processing
- Targets only Kronos-related infrastructure

### Step 5: Droplet Deletion
```bash
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
```
**Purpose:**
- Checks if any Kronos droplets were found
- Iterates through each droplet ID for deletion
- Retrieves droplet name for user confirmation
- Uses `--force` flag to delete without interactive confirmation
- Completely removes DigitalOcean infrastructure

### Step 6: Completion Logging
```bash
log "All done! Swarm droplets destroyed and local context removed."
```
**Purpose:**
- Provides clear confirmation that all operations completed
- Uses consistent logging format with visual separators
- Indicates successful cleanup of all resources

## Safety Features

### Graceful Error Handling
- **Best-effort cleanup**: Continues operation even if individual steps fail
- **Context validation**: Checks if contexts exist before attempting removal
- **Droplet filtering**: Only targets `node-*` droplets, protecting other infrastructure

### Resource Protection
```bash
awk '$2 ~ /^node-/ { print $1 }'
```
**Purpose:**
- Uses precise regex pattern (`^node-`) to match only Kronos droplets
- Prevents accidental deletion of other droplets in the account
- Requires exact naming convention compliance

### Confirmation Output
- Reports number of droplets found before deletion
- Shows droplet name and ID during deletion process
- Provides clear success/failure feedback for each operation

## Cost Management Impact

### Immediate Cost Savings
- **Compute Resources**: Stops all droplet billing immediately upon deletion
- **Networking**: Removes associated network resources and IP allocations
- **Storage**: Deletes attached volumes (if any) to prevent ongoing charges

### Complete Cleanup
- **No Orphaned Resources**: Removes stacks before destroying infrastructure
- **Context Cleanup**: Prevents future accidental connections to deleted resources
- **Zero Residual State**: Ensures clean state for future deployments

## Error Scenarios and Recovery

### Partial Deletion Scenarios
If the script fails partway through:
1. **Stack removal failed**: Droplets will still be deleted, containers become inaccessible
2. **Context removal failed**: Local contexts may remain but point to deleted resources
3. **Droplet deletion failed**: Some droplets may remain - re-run script to complete cleanup

### Network Connection Issues
- Script validates API token before starting operations
- Uses `--force` flags to avoid interactive prompts during network issues
- Each operation is independent - partial completion is acceptable

### Manual Recovery
If automatic cleanup fails:
```bash
# Manually remove contexts
docker context rm -f kronos-swarm docker-swarm

# Manually delete droplets
doctl compute droplet list --format "ID,Name" --no-header | grep node- | awk '{print $1}' | xargs doctl compute droplet delete --force
```