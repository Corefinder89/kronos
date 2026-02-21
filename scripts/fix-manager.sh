#!/bin/bash
# fix-manager.sh
#
# Checks if Swarm manager node is drained and automatically fixes it
# by undraining the manager and restarting all Selenium services.
#
# Usage:
#   export DO_API_ACCESS_TOKEN=<your_token>
#   bash scripts/fix-manager.sh
#
# Dependencies:
#   - docker (with kronos-swarm context configured)
#   - doctl (DigitalOcean CLI)

set -euo pipefail

# Configuration
DOCKER_CONTEXT="kronos-swarm"
STACK_NAME="selenium"
COMPOSE_FILE="docker-compose.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

check_dependencies() {
    command -v docker >/dev/null 2>&1 || { log_error "docker is required but not installed"; exit 1; }
    command -v doctl >/dev/null 2>&1 || { log_error "doctl is required but not installed"; exit 1; }
    
    if [[ -z "${DO_API_ACCESS_TOKEN:-}" ]]; then
        log_error "DO_API_ACCESS_TOKEN environment variable not set"
        exit 1
    fi
}

check_docker_context() {
    if ! docker context inspect "$DOCKER_CONTEXT" >/dev/null 2>&1; then
        log_error "Docker context '$DOCKER_CONTEXT' does not exist"
        log_info "Run 'bash scripts/healthcheck.sh --fix' to recreate the context"
        exit 1
    fi
}

get_manager_node_info() {
    local swarm_info
    if ! swarm_info=$(docker --context "$DOCKER_CONTEXT" node ls --format "{{.ID}} {{.Hostname}} {{.Status}} {{.Availability}} {{.ManagerStatus}}" 2>/dev/null); then
        log_error "Cannot connect to Docker Swarm"
        exit 1
    fi
    
    local manager_id=""
    local manager_hostname=""
    local manager_availability=""
    
    while IFS= read -r line; do
        if [[ $line =~ Leader ]]; then
            manager_id=$(echo "$line" | awk '{print $1}')
            manager_hostname=$(echo "$line" | awk '{print $2}')
            manager_availability=$(echo "$line" | awk '{print $4}')
            break
        fi
    done <<< "$swarm_info"
    
    if [[ -z "$manager_id" ]]; then
        log_error "Could not find manager node"
        exit 1
    fi
    
    echo "$manager_id|$manager_hostname|$manager_availability"
}

check_manager_status() {
    local manager_info
    manager_info=$(get_manager_node_info)
    
    local manager_id=$(echo "$manager_info" | cut -d'|' -f1)
    local manager_hostname=$(echo "$manager_info" | cut -d'|' -f2)
    local manager_availability=$(echo "$manager_info" | cut -d'|' -f3)
    
    log_info "Manager node: $manager_hostname (ID: $manager_id)"
    log_info "Availability: $manager_availability"
    
    if [[ "$manager_availability" == "Drain" ]]; then
        log_warning "Manager node is drained (cannot schedule workloads)"
        return 1
    else
        log_success "Manager node is active"
        return 0
    fi
}

fix_manager_node() {
    log_info "Fixing drained manager node..."
    
    local manager_info
    manager_info=$(get_manager_node_info)
    local manager_id=$(echo "$manager_info" | cut -d'|' -f1)
    
    log_info "Undraining manager node (ID: $manager_id)..."
    if docker --context "$DOCKER_CONTEXT" node update --availability active "$manager_id"; then
        log_success "Manager node undraining successful"
    else
        log_error "Failed to undrain manager node"
        exit 1
    fi
}

restart_selenium_services() {
    log_info "Restarting Selenium Grid services..."
    
    # Check if stack exists
    if ! docker --context "$DOCKER_CONTEXT" stack ls | grep -q "$STACK_NAME"; then
        log_warning "Selenium stack not found, deploying fresh..."
        if [[ ! -f "$COMPOSE_FILE" ]]; then
            log_error "Compose file not found: $COMPOSE_FILE"
            exit 1
        fi
        docker --context "$DOCKER_CONTEXT" stack deploy --compose-file "$COMPOSE_FILE" "$STACK_NAME"
    else
        log_info "Redeploying existing Selenium stack..."
        docker --context "$DOCKER_CONTEXT" stack deploy --compose-file "$COMPOSE_FILE" "$STACK_NAME"
    fi
    
    log_info "Waiting for services to stabilize..."
    sleep 10
    
    # Force update all services to restart them
    local services=("${STACK_NAME}_hub" "${STACK_NAME}_chrome" "${STACK_NAME}_firefox")
    for service in "${services[@]}"; do
        log_info "Force updating service: $service"
        docker --context "$DOCKER_CONTEXT" service update --force "$service" >/dev/null 2>&1 || {
            log_warning "Failed to update $service (may not exist yet)"
        }
    done
    
    log_info "Waiting for services to restart..."
    sleep 15
}

verify_services() {
    log_info "Verifying Selenium Grid services..."
    
    local services
    if ! services=$(docker --context "$DOCKER_CONTEXT" service ls --format "{{.Name}} {{.Replicas}}" 2>/dev/null); then
        log_error "Cannot list Docker services"
        return 1
    fi
    
    local expected_services=("${STACK_NAME}_hub" "${STACK_NAME}_chrome" "${STACK_NAME}_firefox")
    local all_healthy=true
    
    for expected_service in "${expected_services[@]}"; do
        if echo "$services" | grep -q "^$expected_service"; then
            local replicas
            replicas=$(echo "$services" | grep "^$expected_service" | awk '{print $2}')
            if [[ $replicas =~ ^[1-9]/[1-9] ]]; then
                log_success "✓ $expected_service: $replicas"
            else
                log_warning "⚠ $expected_service: $replicas (not running)"
                all_healthy=false
            fi
        else
            log_warning "⚠ $expected_service: not found"
            all_healthy=false
        fi
    done
    
    if [[ $all_healthy == true ]]; then
        log_success "All Selenium services are healthy"
        return 0
    else
        log_warning "Some services are not healthy"
        return 1
    fi
}

test_grid_connectivity() {
    log_info "Testing Grid connectivity..."
    
    # Get manager IP
    local manager_ip
    if ! manager_ip=$(doctl compute droplet list --format Name,PublicIPv4 --no-header | grep "^node-1 " | awk '{print $2}'); then
        log_warning "Could not determine manager IP"
        return 1
    fi
    
    local grid_url="http://${manager_ip}:4444/wd/hub/status"
    local response
    
    if response=$(curl -s --connect-timeout 5 --max-time 10 "$grid_url" 2>/dev/null); then
        log_success "Grid is accessible at $grid_url"
        
        # Parse response if jq is available
        if command -v jq >/dev/null 2>&1; then
            local ready
            local node_count
            ready=$(echo "$response" | jq -r '.value.ready // false' 2>/dev/null || echo "unknown")
            node_count=$(echo "$response" | jq -r '.value.nodes | length' 2>/dev/null || echo "unknown")
            
            if [[ "$ready" == "true" ]]; then
                log_success "Grid status: ready with $node_count nodes"
            else
                log_warning "Grid status: not ready (nodes connecting: $node_count)"
            fi
        fi
        return 0
    else
        log_error "Cannot connect to Grid at $grid_url"
        return 1
    fi
}

main() {
    echo "============================================================"
    echo "  Kronos Manager Fix & Service Restart"
    echo "  Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
    echo ""
    
    # Check dependencies
    check_dependencies
    check_docker_context
    
    # Check if manager is drained
    if check_manager_status; then
        log_info "Manager node is already active, checking services..."
    else
        log_info "Manager node is drained, fixing..."
        fix_manager_node
        
        # Verify fix worked
        if ! check_manager_status; then
            log_error "Failed to fix manager node"
            exit 1
        fi
    fi
    
    # Restart services regardless
    restart_selenium_services
    
    # Wait a bit more for services to fully start
    log_info "Waiting for services to fully initialize..."
    sleep 20
    
    # Verify everything is working
    echo ""
    echo "============================================================"
    echo "  Verification Results"
    echo "============================================================"
    
    local services_healthy=true
    local grid_accessible=true
    
    if ! verify_services; then
        services_healthy=false
    fi
    
    if ! test_grid_connectivity; then
        grid_accessible=false
    fi
    
    echo ""
    echo "============================================================"
    echo "  Summary"
    echo "============================================================"
    
    if [[ $services_healthy == true && $grid_accessible == true ]]; then
        log_success "Manager fix completed successfully!"
        log_success "Selenium Grid is fully operational"
        echo ""
        log_info "You can now run tests:"
        echo "  make test"
        echo "  make test-chrome"
        echo "  make test-firefox"
    elif [[ $services_healthy == true ]]; then
        log_warning "Services are running but Grid connectivity needs time"
        log_info "Try running 'make test' in a few minutes"
    else
        log_warning "Manager fixed but some services need more time to start"
        log_info "Run 'make health-fix' if issues persist"
    fi
    
    echo ""
}

# Run main function
main "$@"