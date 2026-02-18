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
└── scripts/
    ├── dropletsetup.sh         # Provision droplets + deploy the Grid
    ├── destroy.sh              # Tear down all droplets + clean up
    └── docker-cloud-init.yml   # Cloud-init: installs Docker on boot
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
| `docker` | Stack deployment via `docker context` |
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

1. Creates `node-1`, `node-2`, … `node-N` droplets on DigitalOcean (Ubuntu 22.04, 4 vCPU / 8 GB)
2. Waits for Docker to be ready on each node (installed via cloud-init)
3. Initialises Docker Swarm on the manager node and drains it from workloads
4. Joins all other nodes as Swarm workers
5. Creates a local `docker context` named `kronos-swarm` pointing at the manager
6. Deploys the Selenium Grid stack and scales Chrome + Firefox to 2 replicas each

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
2. Delete the local `kronos-swarm` Docker context
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

> **Note**: `DO_API_ACCESS_TOKEN` and SSH key details should never be committed to version control. Add any credentials file to `.gitignore`.
