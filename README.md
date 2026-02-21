# Kronos — Distributed Selenium Grid on DigitalOcean

Kronos automates the provisioning of a **Docker Swarm cluster on DigitalOcean** and deploys a **distributed Selenium Grid** on top of it. It is designed for running parallel browser-based test suites at scale, with Chrome and Firefox nodes distributed across worker droplets.

---

## How It Works

```
Local machine
    │
    ├── doctl          → creates DigitalOcean droplets (node-1, node-2, …)
    ├── cloud-init     → installs Docker Engine on each droplet at boot
    ├── SSH            → initialises Docker Swarm, joins worker nodes
    ├── docker context → points local Docker CLI at the Swarm manager
    └── docker stack   → deploys Selenium Grid (hub + chrome + firefox)
```

The **manager node** runs the Selenium Hub. **Worker nodes** run Chrome and Firefox browser containers. Tests connect to the Grid at `http://<manager-ip>:4444`.

---

## Repository Structure

```
kronos/
├── docker-compose.yml          # Selenium Grid stack definition
├── CODEOWNERS                  # Code ownership definitions
├── .github/
│   └── CODEOWNERS             # GitHub code ownership (preferred location)
└── scripts/
    ├── dropletsetup.sh         # Provision droplets + deploy the Grid
    ├── destroy.sh              # Tear down all droplets + clean up
    ├── healthcheck.sh          # Health monitoring & auto-repair script
    ├── docker-cloud-init.yml   # Cloud-init: installs Docker on boot
    └── tests/
        ├── grid_test.py        # Selenium Grid smoke tests
        └── requirements.txt    # Python dependencies
```

---

## Prerequisites

### 1. Install `doctl` (DigitalOcean CLI)

```bash
# Download and extract
curl -sL https://github.com/digitalocean/doctl/releases/download/v1.119.0/doctl-1.119.0-linux-amd64.tar.gz \
  | tar xz -C /tmp

# Install to PATH (choose one)
sudo mv /tmp/doctl /usr/local/bin/          # system-wide (needs sudo)
# OR
mkdir -p ~/.local/bin && mv /tmp/doctl ~/.local/bin/   # user-only (no sudo)
export PATH="$HOME/.local/bin:$PATH"        # add to ~/.bashrc to persist

# Verify
doctl version
```

### 2. Authenticate `doctl`

```bash
doctl auth init --access-token <YOUR_DO_PERSONAL_ACCESS_TOKEN>
```

Generate a token at: **DigitalOcean → API → Personal access tokens** (needs Read + Write scope).

### 3. Get your SSH key fingerprint

Your SSH public key must be registered in your DigitalOcean account (**Settings → Security → SSH Keys**).

```bash
doctl compute ssh-key list
# Copy the Fingerprint column value, e.g. ab:cd:ef:...
```

### 4. Install local dependencies

| Tool | Purpose |
|---|---|
| `docker` | Stack deployment via `docker context` and context management |
| `jq` | JSON parsing (used internally by scripts) |
| `ssh` | Remote Swarm commands |

---

## Setup

```bash
export DO_API_ACCESS_TOKEN=<your_token>

bash scripts/dropletsetup.sh \
  -n 3 \                        # number of droplets to create
  -s node-1 \                   # which node becomes the Swarm manager
  -k <ssh_key_fingerprint>      # fingerprint from doctl compute ssh-key list
```

What this does, in order:

1. **Cleans up existing contexts** — Automatically removes any existing `docker-swarm` context to prevent conflicts
2. Creates `node-1`, `node-2`, … `node-N` droplets on DigitalOcean (Ubuntu 22.04, 4 vCPU / 8 GB)
3. Waits for Docker to be ready on each node (installed via cloud-init)
4. Initialises Docker Swarm on the manager node and drains it from workloads
5. Joins all other nodes as Swarm workers
6. Creates a local `docker context` named `kronos-swarm` pointing at the manager
7. Deploys the Selenium Grid stack and scales Chrome + Firefox to 2 replicas each

On completion:

```
===> Deployment complete!

  Selenium Grid console : http://<manager-ip>:4444
  Docker context        : kronos-swarm
```

### Managing the Swarm locally

```bash
docker --context kronos-swarm node ls
docker --context kronos-swarm service ls
docker --context kronos-swarm service scale selenium_chrome=4
```

---

## Teardown

```bash
export DO_API_ACCESS_TOKEN=<your_token>

bash scripts/destroy.sh
```

This will:
1. Remove the `selenium` stack from the Swarm
2. **Force remove Docker contexts** — Deletes both `kronos-swarm` and `docker-swarm` contexts (using force flag to handle contexts in use)
3. Delete all `node-*` droplets from DigitalOcean

---

## Selenium Grid

The grid is defined in `docker-compose.yml` and uses the official Selenium images:

| Service | Image | Placement |
|---|---|---|
| `hub` | `selenium/hub:4.27.0` | Manager node |
| `chrome` | `selenium/node-chrome:4.27.0` | Worker nodes |
| `firefox` | `selenium/node-firefox:4.27.0` | Worker nodes |

Connect your test framework to: `http://<manager-ip>:4444/wd/hub`

---

## Testing the Grid

A smoke test script (`grid_test.py`) is included to verify the Grid is working correctly. It connects to the hub, opens a browser on a worker node, navigates to Google, performs a search, and asserts the results page.

```bash
# Install dependency
pip install -r requirements.txt

# Test with Chrome
python grid_test.py --hub <manager-ip>

# Test with Firefox
python grid_test.py --hub <manager-ip> --browser firefox

# Test both browsers in parallel
python grid_test.py --hub <manager-ip> --browser both
```

Example output:

```
============================================================
  Kronos — Selenium Grid Smoke Test
  Hub     : 123.45.67.89:4444
  Browser : chrome, firefox
============================================================

[chrome]  Connecting to Grid at http://123.45.67.89:4444/wd/hub
[firefox] Connecting to Grid at http://123.45.67.89:4444/wd/hub
[chrome]  Session ID : abc123...
[firefox] Session ID : def456...
[chrome]  Page title : Google ✓
[firefox] Page title : Google ✓
[chrome]  Search results title: Selenium Grid - Google Search ✓
[firefox] Search results title: Selenium Grid - Google Search ✓

============================================================
  Results
============================================================
  ✓  chrome     PASSED
  ✓  firefox    PASSED
============================================================
```

---

## Health Monitoring

The `healthcheck.sh` script automatically diagnoses and repairs common Selenium Grid issues. Use this whenever you encounter connection problems or service failures.

### Quick Health Check

```bash
# Check Grid status (safe, no changes)
export DO_API_ACCESS_TOKEN=<your_token>
bash scripts/healthcheck.sh
```

### Auto-Repair Mode

```bash
# Automatically fix detected issues
bash scripts/healthcheck.sh --fix
```

### What It Checks

| Component | Verification |
|---|---|
| **DigitalOcean Droplets** | All nodes are active and accessible |
| **Docker Context** | Remote Swarm connection is configured |
| **Docker Swarm** | Manager node availability and service scheduling |
| **Selenium Services** | Hub, Chrome, and Firefox containers are running |
| **Grid Connectivity** | HTTP access to hub and node registration |

### What It Fixes

- ✅ **Missing Docker Context** — Recreates remote connection to Swarm manager
- ✅ **Drained Manager Node** — Enables workload scheduling on manager
- ✅ **Stopped Services** — Redeploys and restarts Selenium Grid stack
- ✅ **Stuck Containers** — Force-updates unresponsive services

### Example Output

```
============================================================
  Kronos Selenium Grid Health Check
  Mode: Check & Repair
  Time: 2026-02-21 13:23:50
============================================================

[SUCCESS] All 3 nodes are active
[SUCCESS] Docker context 'kronos-swarm' exists  
[SUCCESS] Manager node is active
[SUCCESS] selenium_hub: 1/1
[SUCCESS] selenium_chrome: 1/1
[SUCCESS] selenium_firefox: 1/1
[SUCCESS] Grid is accessible at http://162.243.167.45:4444
[SUCCESS] Grid status: ready with 2 nodes

============================================================
  Health Check Summary
============================================================
[SUCCESS] All checks passed! Selenium Grid is healthy.
```

**Troubleshooting Workflow:**
1. Run `bash scripts/healthcheck.sh` to diagnose issues
2. Run `bash scripts/healthcheck.sh --fix` if problems are detected
3. Test with `python scripts/tests/grid_test.py --hub <manager-ip>`

---

## Code Ownership & Contributing

This repository uses GitHub's **CODEOWNERS** feature to automatically assign code reviews and maintain code quality. Code owners are automatically requested for review when pull requests modify files they own.

### How It Works

| File Pattern | Owner(s) | Review Required For |
|---|---|---|
| **All files** | `@corefinder89` | General changes |
| **Shell scripts (*.sh)** | `@corefinder89` | Security-sensitive automation |
| **Docker configs** | `@corefinder89` | Infrastructure changes |
| **Documentation (*.md)** | `@corefinder89` | Documentation updates |
| **Tests (scripts/tests/)** | `@corefinder89` | Quality assurance changes |

### Contributing Guidelines

1. **Fork the repository** and create a feature branch
2. **Make your changes** following existing code patterns
3. **Test thoroughly** using `scripts/healthcheck.sh` and `scripts/tests/grid_test.py`
4. **Update documentation** if adding new features or changing behavior
5. **Submit a pull request** - code owners will be automatically requested for review

### Branch Protection

For production deployments, enable these GitHub repository settings:
- ✅ **Require pull request reviews before merging**
- ✅ **Require review from code owners** 
- ✅ **Require status checks to pass before merging**
- ✅ **Require branches to be up to date before merging**

### Adding Team Members

To add team-based code ownership, edit [`.github/CODEOWNERS`](.github/CODEOWNERS):

```bash
# Example: Add infrastructure team
scripts/dropletsetup.sh @infrastructure-team @corefinder89
scripts/destroy.sh @infrastructure-team @corefinder89

# Example: Add QA team  
scripts/tests/ @qa-team @corefinder89

# Example: Add security team for sensitive files
*.sh @security-team @corefinder89
CREDENTIALS @security-team @corefinder89
```

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

### Why MIT License?

The MIT License was chosen for Kronos because:
- ✅ **Permissive** - Allows both personal and commercial use
- ✅ **Simple** - Clear and easy to understand terms  
- ✅ **Compatible** - Works well with other open source projects
- ✅ **Business Friendly** - No restrictions on commercial deployment
- ✅ **Community Driven** - Encourages contributions and forks

---

> **Note**: `DO_API_ACCESS_TOKEN` and SSH key details should never be committed to version control. Add any credentials file to `.gitignore`.
