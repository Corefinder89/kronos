#!/bin/bash
# healthcheck.sh
#
# Selenium Grid Health Check and Auto-Repair Script
# 
# This script automatically diagnoses and fixes common issues with the 
# Kronos Selenium Grid deployment on DigitalOcean.
#
# Usage:
#   export DO_API_ACCESS_TOKEN=<your_token>
#   bash scripts/healthcheck.sh [--fix]
#
# Options:
#   --fix    Automatically attempt to repair issues (default: check-only mode)
#
# Dependencies:
#   - doctl (DigitalOcean CLI)
#   - docker (with context support)
#   - curl (for HTTP checks)
#   - jq (for JSON parsing, optional)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MANAGER_NODE="node-1"
GRID_PORT="4444"
DOCKER_CONTEXT="kronos-swarm"
STACK_NAME="selenium"
COMPOSE_FILE="docker-compose.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------------------------

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
    local missing_deps=()
    
    command -v doctl >/dev/null 2>&1 || missing_deps+=("doctl")
    command -v docker >/dev/null 2>&1 || missing_deps+=("docker")
    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install the missing tools and try again."
        exit 1
    fi
    
    if [[ -z "${DO_API_ACCESS_TOKEN:-}" ]]; then
        log_error "DO_API_ACCESS_TOKEN environment variable not set"
        log_info "Export your DigitalOcean API token: export DO_API_ACCESS_TOKEN=<your_token>"
        exit 1
    fi
}

get_manager_ip() {
    local manager_ip
    manager_ip=$(doctl compute droplet list --format Name,PublicIPv4 --no-header | grep "^${MANAGER_NODE} " | awk '{print $2}')
    
    if [[ -z "$manager_ip" ]]; then
        log_error "Manager node '${MANAGER_NODE}' not found"
        return 1
    fi
    
    echo "$manager_ip"
}

# ---------------------------------------------------------------------------
# Health Check Functions
# ---------------------------------------------------------------------------

check_droplets() {
    log_info "Checking DigitalOcean droplets status..."
    
    local droplets
    if ! droplets=$(doctl compute droplet list --format Name,PublicIPv4,Status --no-header 2>/dev/null); then
        log_error "Failed to list droplets. Check your API token and network connection."
        return 1
    fi
    
    local node_count=0
    local active_count=0
    
    while IFS= read -r line; do
        if [[ $line =~ ^node-[0-9]+ ]]; then
            node_count=$((node_count + 1))
            local name=$(echo "$line" | awk '{print $1}')
            local ip=$(echo "$line" | awk '{print $2}')
            local status=$(echo "$line" | awk '{print $3}')
            
            if [[ "$status" == "active" ]]; then
                active_count=$((active_count + 1))
                log_success "  $name ($ip) - $status"
            else
                log_warning "  $name ($ip) - $status"
            fi
        fi
    done <<< "$droplets"
    
    if [[ $node_count -eq 0 ]]; then
        log_error "No Kronos nodes found. Run dropletsetup.sh first."
        return 1
    fi
    
    if [[ $active_count -ne $node_count ]]; then
        log_warning "$active_count/$node_count nodes are active"
        return 1
    fi
    
    log_success "All $node_count nodes are active"
    return 0
}

check_docker_context() {
    log_info "Checking Docker context..."
    
    if docker context inspect "$DOCKER_CONTEXT" >/dev/null 2>&1; then
        log_success "Docker context '$DOCKER_CONTEXT' exists"
        return 0
    else
        log_warning "Docker context '$DOCKER_CONTEXT' does not exist"
        return 1
    fi
}

check_swarm_status() {
    log_info "Checking Docker Swarm status..."
    
    local manager_ip
    if ! manager_ip=$(get_manager_ip); then
        return 1
    fi
    
    local swarm_info
    if ! swarm_info=$(docker --context "$DOCKER_CONTEXT" node ls --format "table {{.ID}}\t{{.Hostname}}\t{{.Status}}\t{{.Availability}}\t{{.ManagerStatus}}" 2>/dev/null); then
        log_error "Cannot connect to Docker Swarm. Context may be invalid."
        return 1
    fi
    
    local manager_drained=false
    while IFS= read -r line; do
        if [[ $line =~ $MANAGER_NODE.*Leader ]]; then
            if [[ $line =~ Drain ]]; then
                manager_drained=true
                log_warning "  Manager node is drained (cannot schedule workloads)"
            else
                log_success "  Manager node is active"
            fi
            break
        fi
    done <<< "$swarm_info"
    
    if [[ $manager_drained == true ]]; then
        return 1
    fi
    
    return 0
}

check_selenium_services() {
    log_info "Checking Selenium Grid services..."
    
    local services
    if ! services=$(docker --context "$DOCKER_CONTEXT" service ls --format "table {{.Name}}\t{{.Replicas}}" 2>/dev/null); then
        log_error "Cannot list Docker services"
        return 1
    fi
    
    local expected_services=("${STACK_NAME}_hub" "${STACK_NAME}_chrome" "${STACK_NAME}_firefox")
    local missing_services=()
    local failed_services=()
    
    for service in "${expected_services[@]}"; do
        if ! echo "$services" | grep -q "^$service"; then
            missing_services+=("$service")
        else
            local replicas
            replicas=$(echo "$services" | grep "^$service" | awk '{print $2}')
            if [[ $replicas =~ ^0/ ]]; then
                failed_services+=("$service ($replicas)")
                log_warning "  $service: $replicas (not running)"
            else
                log_success "  $service: $replicas"
            fi
        fi
    done
    
    if [[ ${#missing_services[@]} -gt 0 ]]; then
        log_warning "Missing services: ${missing_services[*]}"
        return 1
    fi
    
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        log_warning "Failed services: ${failed_services[*]}"
        return 1
    fi
    
    return 0
}

check_grid_connectivity() {
    log_info "Checking Selenium Grid connectivity..."
    
    local manager_ip
    if ! manager_ip=$(get_manager_ip); then
        return 1
    fi
    
    local grid_url="http://${manager_ip}:${GRID_PORT}/wd/hub/status"
    local response
    
    if ! response=$(curl -s --connect-timeout 5 --max-time 10 "$grid_url" 2>/dev/null); then
        log_error "Cannot connect to Selenium Grid at $grid_url"
        return 1
    fi
    
    log_success "Grid is accessible at $grid_url"
    
    # Parse response if jq is available
    if command -v jq >/dev/null 2>&1; then
        local ready
        local node_count
        ready=$(echo "$response" | jq -r '.value.ready // false' 2>/dev/null || echo "unknown")
        node_count=$(echo "$response" | jq -r '.value.nodes | length' 2>/dev/null || echo "unknown")
        
        if [[ "$ready" == "true" ]]; then
            log_success "  Grid status: ready with $node_count nodes"
        else
            log_warning "  Grid status: not ready (nodes connecting: $node_count)"
        fi
    fi
    
    return 0
}

# ---------------------------------------------------------------------------
# Repair Functions
# ---------------------------------------------------------------------------

repair_docker_context() {
    log_info "Creating Docker context..."
    
    local manager_ip
    if ! manager_ip=$(get_manager_ip); then
        return 1
    fi
    
    # Remove existing context if it exists
    docker context rm "$DOCKER_CONTEXT" >/dev/null 2>&1 || true
    
    if docker context create "$DOCKER_CONTEXT" --docker "host=ssh://root@${manager_ip}"; then
        log_success "Created Docker context '$DOCKER_CONTEXT'"
        return 0
    else
        log_error "Failed to create Docker context"
        return 1
    fi
}

repair_swarm_manager() {
    log_info "Activating manager node for workload scheduling..."
    
    local manager_id
    if ! manager_id=$(docker --context "$DOCKER_CONTEXT" node ls --filter "role=manager" --format "{{.ID}}" | head -1); then
        log_error "Cannot find manager node ID"
        return 1
    fi
    
    if docker --context "$DOCKER_CONTEXT" node update --availability active "$manager_id"; then
        log_success "Manager node activated"
        return 0
    else
        log_error "Failed to activate manager node"
        return 1
    fi
}

repair_selenium_services() {
    log_info "Deploying Selenium Grid services..."
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_error "Docker Compose file not found: $COMPOSE_FILE"
        log_info "Make sure you're running this script from the kronos root directory"
        return 1
    fi
    
    if docker --context "$DOCKER_CONTEXT" stack deploy --compose-file "$COMPOSE_FILE" "$STACK_NAME"; then
        log_success "Deployed Selenium Grid stack"
        
        # Wait for services to start
        log_info "Waiting for services to start..."
        sleep 15
        
        # Try to force restart services that might be stuck
        local services=("${STACK_NAME}_hub" "${STACK_NAME}_chrome" "${STACK_NAME}_firefox")
        for service in "${services[@]}"; do
            log_info "Force updating service: $service"
            docker --context "$DOCKER_CONTEXT" service update --force "$service" >/dev/null 2>&1 || true
        done
        
        return 0
    else
        log_error "Failed to deploy Selenium Grid stack"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main Function
# ---------------------------------------------------------------------------

main() {
    local fix_mode=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --fix)
                fix_mode=true
                shift
                ;;
            -h|--help)
                grep -E "^#" "$0" | head -20 | sed 's/^# //'
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    echo "============================================================"
    echo "  Kronos Selenium Grid Health Check"
    echo "  Mode: $(if [[ $fix_mode == true ]]; then echo "Check & Repair"; else echo "Check Only"; fi)"
    echo "  Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
    echo ""
    
    # Check dependencies
    check_dependencies
    
    # Health checks
    local issues=0
    
    # 1. Check droplets
    if ! check_droplets; then
        ((issues++))
        if [[ $fix_mode == false ]]; then
            log_info "Run 'bash scripts/dropletsetup.sh' to create/repair droplets"
        fi
    fi
    
    # 2. Check Docker context
    if ! check_docker_context; then
        ((issues++))
        if [[ $fix_mode == true ]]; then
            if repair_docker_context; then
                log_success "Fixed Docker context"
            else
                log_error "Failed to fix Docker context"
            fi
        else
            log_info "Run with --fix to repair Docker context"
        fi
    fi
    
    # 3. Check Swarm status
    if ! check_swarm_status; then
        ((issues++))
        if [[ $fix_mode == true ]]; then
            if repair_swarm_manager; then
                log_success "Fixed Swarm manager availability"
            else
                log_error "Failed to fix Swarm manager"
            fi
        else
            log_info "Run with --fix to undrain manager node"
        fi
    fi
    
    # 4. Check Selenium services
    if ! check_selenium_services; then
        ((issues++))
        if [[ $fix_mode == true ]]; then
            if repair_selenium_services; then
                log_success "Fixed Selenium services"
                # Re-check after deployment
                sleep 10
                check_selenium_services || true
            else
                log_error "Failed to fix Selenium services"
            fi
        else
            log_info "Run with --fix to deploy/restart Selenium services"
        fi
    fi
    
    # 5. Check Grid connectivity
    if ! check_grid_connectivity; then
        ((issues++))
        if [[ $fix_mode == false ]]; then
            log_info "Grid connectivity issues may resolve after fixing other problems"
        fi
    fi
    
    # Summary
    echo ""
    echo "============================================================"
    echo "  Health Check Summary"
    echo "============================================================"
    
    if [[ $issues -eq 0 ]]; then
        log_success "All checks passed! Selenium Grid is healthy."
        
        # Show quick test command
        local manager_ip
        if manager_ip=$(get_manager_ip 2>/dev/null); then
            echo ""
            log_info "Test your Grid with:"
            echo "  cd scripts/tests"
            echo "  python grid_test.py --hub $manager_ip --browser chrome"
        fi
    else
        log_warning "Found $issues issue(s)"
        if [[ $fix_mode == false ]]; then
            log_info "Run 'bash scripts/healthcheck.sh --fix' to attempt automatic repairs"
        fi
    fi
    
    echo ""
    exit $([[ $issues -eq 0 ]] && echo 0 || echo 1)
}

# Run main function
main "$@"