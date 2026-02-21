# Kronos - Distributed Selenium Grid on DigitalOcean
# Makefile for common operations and automation

.PHONY: help install setup deploy test health destroy clean lint check-deps config deploy-from-config update-hub-ip fix-manager

# Default target
help: ## Show this help message
	@echo "Kronos - Distributed Selenium Grid Automation"
	@echo ""
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# =============================================================================
# Prerequisites and Setup
# =============================================================================

check-deps: ## Check if required dependencies are installed
	@echo "Checking dependencies..."
	@command -v docker >/dev/null 2>&1 || { echo "❌ docker is required but not installed"; exit 1; }
	@command -v doctl >/dev/null 2>&1 || { echo "❌ doctl is required but not installed"; exit 1; }
	@command -v curl >/dev/null 2>&1 || { echo "❌ curl is required but not installed"; exit 1; }
	@command -v python3 >/dev/null 2>&1 || { echo "❌ python3 is required but not installed"; exit 1; }
	@echo "✅ All dependencies are available"

install-test-deps: ## Install Python test dependencies
	@echo "Installing Python test dependencies..."
	@pip install -r scripts/tests/requirements.txt
	@echo "✅ Test dependencies installed"

setup: check-deps ## Validate environment and check API token
	@echo "Validating environment setup..."
	@test -n "$(DO_API_ACCESS_TOKEN)" || { echo "❌ DO_API_ACCESS_TOKEN environment variable is not set"; exit 1; }
	@doctl auth list >/dev/null 2>&1 || { echo "❌ doctl is not authenticated"; exit 1; }
	@echo "✅ Environment is properly configured"

# =============================================================================
# Deployment Operations
# =============================================================================

deploy: setup ## Deploy Selenium Grid (requires: NODES, MANAGER, SSH_KEY)
	@test -n "$(NODES)" || { echo "❌ NODES variable is required (e.g., make deploy NODES=3)"; exit 1; }
	@test -n "$(MANAGER)" || { echo "❌ MANAGER variable is required (e.g., make deploy MANAGER=node-1)"; exit 1; }
	@test -n "$(SSH_KEY)" || { echo "❌ SSH_KEY variable is required (e.g., make deploy SSH_KEY=ab:cd:ef:...)"; exit 1; }
	@echo "🚀 Deploying Selenium Grid with $(NODES) nodes..."
	@bash scripts/dropletsetup.sh -n $(NODES) -s $(MANAGER) -k $(SSH_KEY)
	@echo "✅ Deployment complete!"

quick-deploy: setup ## Quick deploy with default settings (3 nodes, node-1 manager)
	@test -n "$(SSH_KEY)" || { echo "❌ SSH_KEY variable is required (e.g., make quick-deploy SSH_KEY=ab:cd:ef:...)"; exit 1; }
	@echo "🚀 Quick deploying with defaults (3 nodes, node-1 as manager)..."
	@bash scripts/dropletsetup.sh -n 3 -s node-1 -k $(SSH_KEY)

# =============================================================================
# Health Check and Testing
# =============================================================================

health: setup ## Run health check on deployed Grid
	@echo "🔍 Running health check..."
	@bash scripts/healthcheck.sh

health-fix: setup ## Run health check with auto-repair
	@echo "🔧 Running health check with auto-repair..."
	@bash scripts/healthcheck.sh --fix

fix-manager: setup ## Fix drained manager node and restart all services
	@echo "🔧 Checking and fixing manager node..."
	@bash scripts/fix-manager.sh

test: install-test-deps ## Run Selenium Grid tests (uses config.local.yml or HUB_IP parameter)
	@if [ -n "$(HUB_IP)" ]; then \
		GRID_IP="$(HUB_IP)"; \
	elif [ -f config.local.yml ]; then \
		GRID_IP=$$(grep "hub_ip:" config.local.yml | cut -d'"' -f2); \
	fi; \
	if [ -z "$$GRID_IP" ]; then \
		echo "❌ HUB_IP not found. Either:"; \
		echo "   1. Set HUB_IP parameter: make test HUB_IP=198.211.109.144"; \
		echo "   2. Configure hub_ip in config.local.yml (run 'make config' first)"; \
		exit 1; \
	fi; \
	echo "🧪 Running Selenium Grid tests on $$GRID_IP..."; \
	cd scripts/tests && python grid_test.py --hub $$GRID_IP --browser both

test-chrome: install-test-deps ## Test Chrome browser only (uses config.local.yml or HUB_IP parameter)
	@if [ -n "$(HUB_IP)" ]; then \
		GRID_IP="$(HUB_IP)"; \
	elif [ -f config.local.yml ]; then \
		GRID_IP=$$(grep "hub_ip:" config.local.yml | cut -d'"' -f2); \
	fi; \
	if [ -z "$$GRID_IP" ]; then \
		echo "❌ HUB_IP not found. Either set HUB_IP parameter or configure hub_ip in config.local.yml"; \
		exit 1; \
	fi; \
	echo "🧪 Running Chrome tests on $$GRID_IP..."; \
	cd scripts/tests && python grid_test.py --hub $$GRID_IP --browser chrome

test-firefox: install-test-deps ## Test Firefox browser only (uses config.local.yml or HUB_IP parameter)
	@if [ -n "$(HUB_IP)" ]; then \
		GRID_IP="$(HUB_IP)"; \
	elif [ -f config.local.yml ]; then \
		GRID_IP=$$(grep "hub_ip:" config.local.yml | cut -d'"' -f2); \
	fi; \
	if [ -z "$$GRID_IP" ]; then \
		echo "❌ HUB_IP not found. Either set HUB_IP parameter or configure hub_ip in config.local.yml"; \
		exit 1; \
	fi; \
	echo "🧪 Running Firefox tests on $$GRID_IP..."; \
	cd scripts/tests && python grid_test.py --hub $$GRID_IP --browser firefox

# =============================================================================
# Management Operations  
# =============================================================================

status: ## Show status of droplets and services
	@echo "📊 Kronos Infrastructure Status"
	@echo "================================"
	@echo ""
	@echo "DigitalOcean Droplets:"
	@doctl compute droplet list --format Name,PublicIPv4,Status | grep -E "(Name|node-)" || echo "No Kronos nodes found"
	@echo ""
	@echo "Docker Contexts:"
	@docker context ls | grep -E "(NAME|kronos)" || echo "No Kronos contexts found"

scale-chrome: ## Scale Chrome nodes (requires: REPLICAS)
	@test -n "$(REPLICAS)" || { echo "❌ REPLICAS variable is required (e.g., make scale-chrome REPLICAS=4)"; exit 1; }
	@echo "📈 Scaling Chrome nodes to $(REPLICAS) replicas..."
	@docker --context kronos-swarm service scale selenium_chrome=$(REPLICAS)

scale-firefox: ## Scale Firefox nodes (requires: REPLICAS)
	@test -n "$(REPLICAS)" || { echo "❌ REPLICAS variable is required (e.g., make scale-firefox REPLICAS=2)"; exit 1; }
	@echo "📈 Scaling Firefox nodes to $(REPLICAS) replicas..."
	@docker --context kronos-swarm service scale selenium_firefox=$(REPLICAS)

logs: ## View service logs (optional: SERVICE=selenium_hub|selenium_chrome|selenium_firefox)
	@SERVICE_NAME=$${SERVICE:-selenium_hub}; \
	echo "📝 Viewing logs for $$SERVICE_NAME..."; \
	docker --context kronos-swarm service logs $$SERVICE_NAME --tail 50

# =============================================================================
# Cleanup Operations
# =============================================================================

destroy: setup ## Destroy all Kronos infrastructure
	@echo "💥 Destroying Kronos infrastructure..."
	@echo "⚠️  This will delete all droplets and remove local contexts!"
	@read -p "Are you sure? [y/N] " -n 1 -r; echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		bash scripts/destroy.sh; \
		echo "✅ Infrastructure destroyed"; \
	else \
		echo "❌ Destruction cancelled"; \
	fi

force-destroy: setup ## Force destroy without confirmation (DANGEROUS)
	@echo "💥 Force destroying Kronos infrastructure..."
	@bash scripts/destroy.sh
	@echo "✅ Infrastructure destroyed"

clean: ## Clean up local Docker contexts only
	@echo "🧹 Cleaning up local Docker contexts..."
	@docker context rm kronos-swarm 2>/dev/null || true
	@docker context rm docker-swarm 2>/dev/null || true
	@echo "✅ Local contexts cleaned"

# =============================================================================
# Development and Quality
# =============================================================================

lint: ## Run shellcheck on bash scripts
	@echo "🔍 Linting shell scripts..."
	@find scripts -name "*.sh" -type f -exec shellcheck {} \;
	@echo "✅ Shellcheck passed"

format: ## Check script formatting and permissions
	@echo "🎨 Checking script formatting..."
	@find scripts -name "*.sh" -type f | while read -r script; do \
		if [[ ! -x "$$script" ]]; then \
			echo "⚠️  $$script is not executable, fixing..."; \
			chmod +x "$$script"; \
		fi; \
	done
	@echo "✅ Script permissions verified"

validate: lint format ## Run all validation checks
	@echo "✅ All validation checks passed"

# =============================================================================
# Information and Examples
# =============================================================================

examples: ## Show usage examples
	@echo "Kronos Usage Examples"
	@echo "===================="
	@echo ""
	@echo "1. Initial Setup:"
	@echo "   export DO_API_ACCESS_TOKEN=your_token_here"
	@echo "   make setup"
	@echo ""
	@echo "2a. Deploy with Configuration File (Recommended):"
	@echo "   make config                    # Create config.local.yml"
	@echo "   # Edit config.local.yml with your SSH key and preferences"
	@echo "   make deploy-from-config       # Deploy using configuration"
	@echo ""
	@echo "2b. Deploy with Manual Parameters:"
	@echo "   make deploy NODES=3 MANAGER=node-1 SSH_KEY=ab:cd:ef:..."
	@echo "   # or"
	@echo "   make quick-deploy SSH_KEY=ab:cd:ef:..."
	@echo ""
	@echo "3. Monitor and Test:"
	@echo "   make status"
	@echo "   make health-fix               # Full health check with repairs"
	@echo "   make fix-manager              # Fix drained manager + restart services"
	@echo "   make test                     # Uses hub_ip from config.local.yml"
	@echo "   # or"
	@echo "   make test HUB_IP=198.211.109.144  # Override with specific IP"
	@echo ""
	@echo "4. Scale Services:"
	@echo "   make scale-chrome REPLICAS=4"
	@echo "   make scale-firefox REPLICAS=2"
	@echo ""
	@echo "5. Cleanup:"
	@echo "   make destroy"

env-example: ## Show environment variables example
	@echo "Required Environment Variables:"
	@echo "==============================="
	@echo ""
	@echo "# DigitalOcean API Token (required)"
	@echo "export DO_API_ACCESS_TOKEN=dop_v1_abc123..."
	@echo ""
	@echo "# Common Make Variables (can also be set in config.local.yml):"
	@echo "NODES=3                    # Number of droplets to create"
	@echo "MANAGER=node-1            # Manager node name" 
	@echo "SSH_KEY=ab:cd:ef:...      # SSH key fingerprint"
	@echo "HUB_IP=198.211.109.144     # Grid hub IP for testing (auto-detected)"
	@echo "REPLICAS=4                # Number of service replicas"
	@echo "SERVICE=selenium_chrome    # Service name for logs"
	@echo ""
	@echo "💡 TIP: Use 'make config' to create a local configuration file!"
	@echo "💡 TIP: Customize config.local.yml for your environment!"

config: ## Create local configuration file from template
	@echo "📝 Creating local configuration file..."
	@if [ -f config.local.yml ]; then \
		echo "⚠️  config.local.yml already exists! Backup created."; \
		cp config.local.yml config.local.yml.backup; \
	fi
	@cp config.yml config.local.yml
	@echo "✅ Created config.local.yml - customize it for your environment"
	@echo ""
	@echo "Next steps:"
	@echo "1. Edit config.local.yml with your settings"
	@echo "2. Set DO_API_ACCESS_TOKEN environment variable"
	@echo "3. Run 'make deploy-from-config' to use the configuration"

deploy-from-config: ## Deploy using config.local.yml settings
	@if [ ! -f config.local.yml ]; then \
		echo "❌ config.local.yml not found. Run 'make config' first."; \
		exit 1; \
	fi
	@echo "🚀 Deploying from config.local.yml..."
	@SSH_KEY=$$(grep "ssh_key:" config.local.yml | cut -d'"' -f2); \
	NODES=$$(grep "node_count:" config.local.yml | awk '{print $$2}'); \
	MANAGER=$$(grep "manager_node:" config.local.yml | cut -d'"' -f2); \
	if [ -z "$$SSH_KEY" ] || [ "$$SSH_KEY" = "ab:cd:ef:12:34:56:78:90:ab:cd:ef:12:34:56:78:90" ]; then \
		echo "❌ Please update ssh_key in config.local.yml with your actual SSH key fingerprint"; \
		exit 1; \
	fi; \
	$(MAKE) deploy NODES=$$NODES MANAGER=$$MANAGER SSH_KEY=$$SSH_KEY; \
	echo "🔄 Updating hub_ip in config.local.yml..."; \
	$(MAKE) update-hub-ip

update-hub-ip: ## Update hub_ip in config.local.yml with current manager IP
	@if [ ! -f config.local.yml ]; then \
		echo "❌ config.local.yml not found"; \
		exit 1; \
	fi
	@MANAGER_IP=$$(doctl compute droplet list --format Name,PublicIPv4 --no-header | grep "^node-1 " | awk '{print $$2}'); \
	if [ -z "$$MANAGER_IP" ]; then \
		echo "❌ Could not find manager node IP"; \
		exit 1; \
	fi; \
	sed -i.bak "s/hub_ip: \".*\"/hub_ip: \"$$MANAGER_IP\"/" config.local.yml; \
	echo "✅ Updated hub_ip to $$MANAGER_IP in config.local.yml"