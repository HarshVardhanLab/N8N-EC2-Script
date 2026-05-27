<div align="center">

# 🚀 n8n · Docker Installer · AWS EC2

**A production-ready, fully-automated Bash script to install and manage n8n on AWS EC2 Ubuntu servers using Docker & Docker Compose.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%2F%2024.04-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Docker](https://img.shields.io/badge/Docker-Compose%20v2-2496ED?style=flat-square&logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![n8n](https://img.shields.io/badge/n8n-latest-EA4B71?style=flat-square&logo=n8n&logoColor=white)](https://n8n.io/)
[![AWS](https://img.shields.io/badge/AWS-EC2-FF9900?style=flat-square&logo=amazon-aws&logoColor=white)](https://aws.amazon.com/ec2/)
[![Bash](https://img.shields.io/badge/Bash-5.0%2B-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)

---

```
╔══════════════════════════════════════════════════════════╗
║          n8n  ·  Docker Installer  ·  AWS EC2            ║
║          Ubuntu 22.04 / 24.04  —  Production Ready       ║
╚══════════════════════════════════════════════════════════╝
```

</div>

---

## 📋 Table of Contents

- [Overview](#-overview)
- [Features](#-features)
- [Prerequisites](#-prerequisites)
- [Quick Start](#-quick-start)
- [How It Works](#-how-it-works)
- [Script Architecture](#-script-architecture)
- [Interactive Configuration](#-interactive-configuration)
- [Smart Container Detection](#-smart-container-detection)
- [Generated Docker Compose](#-generated-docker-compose)
- [Post-Install](#-post-install)
- [Useful Commands](#-useful-commands)
- [Fixing Safari / HTTP Issue](#-fixing-safari--http-issue)
- [HTTPS Setup](#-https-setup-optional)
- [Backup & Restore](#-backup--restore)
- [Troubleshooting](#-troubleshooting)
- [AWS Security Group](#-aws-security-group)

---

## 🌟 Overview

`setup-n8n.sh` is a **single-command installer** that takes a bare Ubuntu EC2 instance from zero to a fully running [n8n](https://n8n.io/) workflow automation server — in under 5 minutes. Re-running the script on an existing server is completely safe: it detects an existing container, updates the `WEBHOOK_URL` to the current public IP, and restarts without touching your data.

---

## ✨ Features

| Feature | Details |
|---|---|
| 🔍 **Smart Detection** | Checks if Docker, Docker Compose, and the n8n container already exist — skips reinstalling anything |
| 🔄 **IP Auto-Update** | On re-run, detects the new public IP and patches `WEBHOOK_URL` automatically |
| 🛡️ **Safe Re-runs** | Existing container is restarted with new config; **data volume is never touched** |
| 🌐 **EC2 IMDSv2** | Uses AWS Instance Metadata Service v2 to detect the public IP natively |
| 📦 **Persistent Storage** | Mounts `./n8n_data` so workflows survive container upgrades and restarts |
| 🔥 **Firewall Aware** | Automatically opens the n8n port in UFW if active; warns about Security Group otherwise |
| 🎨 **Coloured Output** | Clear, colour-coded log levels: `[OK]`, `[INFO]`, `[WARN]`, `[ERROR]` |
| 📝 **Timestamped Logs** | Full install log saved to `/tmp/setup-n8n-YYYYMMDD-HHMMSS.log` |
| ⚙️ **Interactive Prompts** | Customise port, container name, domain, HTTPS — or press Enter for defaults |
| 🔐 **HTTPS Ready** | Optional domain + Certbot HTTPS setup instructions printed at the end |
| 💥 **Error Handling** | `set -euo pipefail` + `trap ERR` with line-number reporting |
| 🏗️ **Modular Functions** | 15 clean, single-purpose Bash functions — easy to read and extend |

---

## 📦 Prerequisites

### On your local machine
- SSH client
- Your EC2 key pair (`.pem` file)

### On AWS
- An **EC2 instance** running **Ubuntu 22.04 or 24.04**
- Recommended instance size: **t3.small** or larger (minimum 2 GB RAM)
- Minimum **8 GB** root volume storage
- **Port 5678 open** in the EC2 Security Group inbound rules (see [AWS Security Group](#-aws-security-group))

> **Note:** Docker and Docker Compose do **not** need to be pre-installed. The script handles everything.

---

## ⚡ Quick Start

**1. SSH into your EC2 instance**
```bash
ssh -i your-key.pem ubuntu@YOUR_EC2_PUBLIC_IP
```

**2. Download the script**
```bash
curl -O https://raw.githubusercontent.com/your-repo/setup-n8n.sh
# or copy-paste the script contents into a new file
```

**3. Make it executable**
```bash
chmod +x setup-n8n.sh
```

**4. Run it**
```bash
sudo ./setup-n8n.sh
```

**5. Open n8n in your browser**
```
http://YOUR_EC2_PUBLIC_IP:5678
```

That's it. 🎉

---

## 🔍 How It Works

The script runs through **two possible paths** depending on whether an n8n container already exists:

```
sudo ./setup-n8n.sh
        │
        ├─── ✅ Prerequisites (always run)
        │       ├── check_root()              — must run as sudo/root
        │       ├── check_internet()          — verifies outbound connectivity
        │       ├── detect_os()               — confirms Ubuntu 22.04/24.04
        │       ├── detect_public_ip()        — EC2 IMDSv2 → ifconfig.me → fallback
        │       ├── optional_prompts()        — interactive customisation
        │       ├── system_update()           — apt update + upgrade
        │       ├── install_docker()          — official Docker repo (skips if present)
        │       ├── install_compose()         — Docker Compose v2 plugin
        │       ├── configure_docker_service()— systemctl enable/start + docker group
        │       └── configure_firewall()      — UFW rule for chosen port
        │
        ├─── 🔎 check_container_exists()
        │
        ├─── PATH A — Container EXISTS
        │       ├── create_project_dir()      — ensures data dir exists
        │       ├── update_webhook_url()      — patches compose file with new IP
        │       └── restart_existing_container() — down → pull → up -d
        │
        └─── PATH B — Container NOT FOUND (fresh install)
                ├── create_project_dir()      — ~/n8n/ + n8n_data/
                ├── create_compose_file()     — writes docker-compose.yml
                └── start_n8n()              — pull + up -d
        
        └─── Always: verify_installation() + print_summary()
```

---

## 🏗️ Script Architecture

The script is fully modular. Each function has one job:

| Function | Purpose |
|---|---|
| `check_root()` | Validates the script is run with `sudo` or as root |
| `check_internet()` | Pings Google to confirm outbound internet access |
| `detect_os()` | Sources `/etc/os-release` and warns if not Ubuntu |
| `detect_public_ip()` | EC2 IMDSv2 → `ifconfig.me` → `ipify.org` → `icanhazip.com` → hostname fallback |
| `optional_prompts()` | Interactive prompts for port, name, domain, HTTPS, directory |
| `system_update()` | `apt-get update && upgrade` + installs curl, wget, gnupg, ufw, etc. |
| `install_docker()` | Adds Docker's official GPG key + apt repo, installs Docker CE (idempotent) |
| `install_compose()` | Verifies Docker Compose v2 plugin; falls back to standalone binary if missing |
| `configure_docker_service()` | `systemctl enable/start docker` + adds invoking user to docker group |
| `configure_firewall()` | Opens n8n port in UFW if active; skips gracefully if UFW is inactive |
| `check_container_exists()` | Inspects running + stopped containers; extracts current `WEBHOOK_URL` |
| `update_webhook_url()` | `sed` patches `WEBHOOK_URL` in `docker-compose.yml` with fresh IP |
| `restart_existing_container()` | `compose down` → `pull` → `compose up -d` (volume preserved) |
| `create_project_dir()` | `mkdir -p ~/n8n/n8n_data` with correct ownership (`uid 1000`) |
| `create_compose_file()` | Generates a fully-commented `docker-compose.yml` |
| `start_n8n()` | `docker compose pull` + `docker compose up -d` (fresh install path) |
| `verify_installation()` | Checks container running state + HTTP health probe on `/healthz` |
| `print_summary()` | Coloured summary: URL, status, all useful commands, backup instructions |
| `on_error()` | `trap ERR` handler — reports the failing line number and log location |
| `cleanup()` | `trap EXIT` handler — extensible cleanup hook |

---

## ⚙️ Interactive Configuration

When you run the script, it prompts for optional customisations. Press **Enter** to accept the default shown in `[brackets]`.

```
Press ENTER to accept defaults shown in [brackets].

  n8n port [5678]:
  Container name [n8n]:
  Domain name (leave blank to use IP) []:
  n8n project directory [/root/n8n]:
```

| Prompt | Default | Description |
|---|---|---|
| **n8n port** | `5678` | Host port to expose. Must be 1–65535. |
| **Container name** | `n8n` | Docker container name |
| **Domain name** | *(empty)* | Your domain (e.g. `n8n.mysite.com`). Leave blank to use public IP. |
| **HTTPS** | `no` | Only shown if you enter a domain. Prints Certbot instructions at the end. |
| **Project directory** | `~/n8n` | Where `docker-compose.yml` and `n8n_data/` are stored |

You can also pre-set values via environment variables to run the script non-interactively:

```bash
export N8N_PORT=5678
export CONTAINER_NAME=n8n
export N8N_DIR=/opt/n8n
sudo -E ./setup-n8n.sh
```

---

## 🔄 Smart Container Detection

This is the script's most powerful feature. Every time you run `setup-n8n.sh`, it checks:

```bash
docker ps -a --filter "name=^n8n$"
```

**If the container EXISTS** (running or stopped):
1. Detects the current `WEBHOOK_URL` from `docker inspect`
2. Detects the **new** public IP (EC2 IPs change on restart)
3. Patches `docker-compose.yml` with the new IP via `sed`
4. Runs `docker compose down → pull → up -d`
5. Your workflows, credentials, and data are **100% safe**

**If the container does NOT exist** → performs a clean fresh install.

This means you can safely re-run the script after every EC2 stop/start to fix the webhook URL.

```bash
# EC2 got a new IP after restart? Just re-run:
sudo ./setup-n8n.sh
```

---

## 📄 Generated Docker Compose

The script auto-generates this `docker-compose.yml` at `~/n8n/docker-compose.yml`:

```yaml
version: "3.8"

services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: always
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - NODE_ENV=production
      - WEBHOOK_URL=http://YOUR_PUBLIC_IP:5678/
      # - GENERIC_TIMEZONE=UTC
      # - N8N_BASIC_AUTH_ACTIVE=true
      # - N8N_BASIC_AUTH_USER=admin
      # - N8N_BASIC_AUTH_PASSWORD=changeme
    volumes:
      - ./n8n_data:/home/node/.n8n
```

Key decisions:
- `restart: always` — n8n survives server reboots automatically
- `N8N_HOST=0.0.0.0` — listens on all interfaces (required for EC2 access)
- `./n8n_data` volume — all workflows, credentials, and settings persist here

---

## 🎯 Post-Install

After the script completes, you'll see:

```
╔══════════════════════════════════════════════════════════════╗
║               🎉  n8n Installation Complete!                 ║
╚══════════════════════════════════════════════════════════════╝

  Access n8n at:
    http://YOUR_EC2_IP:5678/

  Project directory:  /root/n8n
  Persistent data:    /root/n8n/n8n_data   ← BACK THIS UP!
  Install log:        /tmp/setup-n8n-20260527-121141.log
```

Open the URL in your browser. On **first launch**, n8n will ask you to create an owner account (name, email, password). This is stored locally in the `n8n_data` volume.

---

## 🛠️ Useful Commands

```bash
# ── View live logs ──────────────────────────────────────────
docker compose -f ~/n8n/docker-compose.yml logs -f

# ── Stop n8n ────────────────────────────────────────────────
docker compose -f ~/n8n/docker-compose.yml down

# ── Start n8n ───────────────────────────────────────────────
docker compose -f ~/n8n/docker-compose.yml up -d

# ── Restart n8n ─────────────────────────────────────────────
docker compose -f ~/n8n/docker-compose.yml restart

# ── Update to latest n8n version ────────────────────────────
docker compose -f ~/n8n/docker-compose.yml pull
docker compose -f ~/n8n/docker-compose.yml up -d

# ── Check container status ───────────────────────────────────
docker ps --filter "name=n8n"

# ── Enter the container shell ────────────────────────────────
docker exec -it n8n sh

# ── Check install log ────────────────────────────────────────
cat /tmp/setup-n8n-*.log
```

---

## 🦺 Fixing Safari / HTTP Issue

If you see this error in Safari:

> **"Your n8n server is configured to use a secure cookie, however you are either visiting this via an insecure URL, or using Safari."**

Recent n8n versions enable `N8N_SECURE_COOKIE=true` by default, which blocks Safari on plain HTTP. Fix it in 3 commands:

```bash
# Step 1 — Add the env var
sed -i 's|- NODE_ENV=production|- NODE_ENV=production\n      - N8N_SECURE_COOKIE=false|' \
  ~/n8n/docker-compose.yml

# Step 2 — Verify
grep -A2 "NODE_ENV" ~/n8n/docker-compose.yml

# Step 3 — Restart
docker compose -f ~/n8n/docker-compose.yml down
docker compose -f ~/n8n/docker-compose.yml up -d
```

> ⚠️ **Long-term:** Set up a domain + HTTPS (see below) and remove this workaround.

---

## 🔐 HTTPS Setup (Optional)

If you entered a domain name during setup, the script prints Certbot instructions automatically. To do it manually:

**Step 1 — Point your domain's A record to your EC2 IP**
```
A  n8n.yourdomain.com  →  44.203.25.203
```

**Step 2 — Install Nginx + Certbot**
```bash
sudo apt-get install -y nginx certbot python3-certbot-nginx
```

**Step 3 — Get a certificate**
```bash
sudo certbot --nginx -d n8n.yourdomain.com
```

**Step 4 — Update WEBHOOK_URL**
```bash
sed -i 's|WEBHOOK_URL=.*|WEBHOOK_URL=https://n8n.yourdomain.com/|' \
  ~/n8n/docker-compose.yml

docker compose -f ~/n8n/docker-compose.yml up -d
```

**Step 5 — Also remove the secure cookie workaround** (if you added it earlier)
```bash
sed -i '/N8N_SECURE_COOKIE/d' ~/n8n/docker-compose.yml
docker compose -f ~/n8n/docker-compose.yml up -d
```

---

## 💾 Backup & Restore

All n8n data (workflows, credentials, settings) lives in one folder:

```
~/n8n/n8n_data/
```

**Backup**
```bash
tar czf n8n-backup-$(date +%Y%m%d).tar.gz ~/n8n/n8n_data
```

**Restore**
```bash
# Stop n8n first
docker compose -f ~/n8n/docker-compose.yml down

# Restore the data
tar xzf n8n-backup-20260527.tar.gz -C ~/

# Start n8n again
docker compose -f ~/n8n/docker-compose.yml up -d
```

> 🔑 **Tip:** Automate backups with a cron job:
> ```bash
> 0 2 * * * tar czf /home/ubuntu/backups/n8n-$(date +\%Y\%m\%d).tar.gz /root/n8n/n8n_data
> ```

---

## 🔧 Troubleshooting

<details>
<summary><strong>Container is not starting</strong></summary>

```bash
# Check what went wrong
docker compose -f ~/n8n/docker-compose.yml logs --tail=50

# Check if port is already in use
sudo ss -tlnp | grep 5678
```
</details>

<details>
<summary><strong>Can't access n8n in browser</strong></summary>

1. Confirm the container is running: `docker ps`
2. Test locally on the server: `curl -I http://localhost:5678`
3. Check AWS Security Group — port 5678 must be open for inbound TCP
4. If using Safari on HTTP, add `N8N_SECURE_COOKIE=false` (see above)
</details>

<details>
<summary><strong>Webhook URLs not working after EC2 restart</strong></summary>

EC2 instances get a new public IP on every stop/start. Just re-run the script:

```bash
sudo ./setup-n8n.sh
```

It will detect the existing container, update the IP, and restart automatically.
</details>

<details>
<summary><strong>Permission denied running the script</strong></summary>

```bash
chmod +x setup-n8n.sh
sudo ./setup-n8n.sh
```
</details>

<details>
<summary><strong>Docker group — must use sudo for docker commands</strong></summary>

After the script adds your user to the `docker` group, you need to reload your shell session:

```bash
newgrp docker
# or log out and log back in
```
</details>

<details>
<summary><strong>Check the full install log</strong></summary>

```bash
cat /tmp/setup-n8n-*.log | less
```
</details>

---

## 🔒 AWS Security Group

The script **cannot** modify your AWS Security Group — that must be done in the AWS Console.

**Steps:**
1. Go to **AWS Console → EC2 → Instances**
2. Click your instance → **Security** tab → click the Security Group
3. Click **Edit inbound rules** → **Add rule**

| Type | Protocol | Port | Source |
|---|---|---|---|
| Custom TCP | TCP | **5678** | `0.0.0.0/0` (or your IP for security) |
| SSH | TCP | 22 | Your IP |
| HTTP | TCP | 80 | `0.0.0.0/0` *(only if using HTTPS/Certbot)* |
| HTTPS | TCP | 443 | `0.0.0.0/0` *(only if using HTTPS/Certbot)* |

---

## 📁 Directory Structure

After installation, your server will have:

```
~/n8n/
├── docker-compose.yml      ← Auto-generated, auto-updated on re-run
└── n8n_data/               ← ALL your n8n data lives here — back this up!
    ├── config              ← n8n configuration
    ├── database.sqlite     ← Workflows, credentials, executions
    └── ...
```

---

## 📜 License

MIT — free to use, modify, and distribute.

---

<div align="center">

**Made with ❤️ for the DevOps community**

If this saved you time, give it a ⭐

</div># N8N-EC2-Script
