# Deployment Guide

This guide covers the full stack deployment on a fresh VPS.
Follow steps in order — each section depends on the previous one.

## Prerequisites

| Component | Minimum version | Notes |
|---|---|---|
| VPS | 2 vCPU / 4 GB RAM / 40 GB disk | Tested on Hostinger KVM2 (8 GB RAM / 96 GB disk) |
| OS | Ubuntu 22.04 LTS or 24.04 LTS | Other distributions not tested |
| Docker Engine | 24.x+ | Installed via official script |
| Docker Compose | v2.x+ | Bundled with modern Docker Engine |
| Domain name | — | Must point to the VPS public IP before starting |

---

## 1. Server Preparation

### System update

```bash
apt update && apt upgrade -y
apt install -y curl git ufw fail2ban unattended-upgrades
```

### Create service user

```bash
# Dedicated non-root user for metrics collection
useradd -m -s /bin/bash adlin
```

### Firewall (UFW)

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP (Caddy redirect)
ufw allow 443/tcp   # HTTPS
ufw enable
```

### Fail2Ban

```bash
# Default configuration protects SSH
systemctl enable fail2ban
systemctl start fail2ban

# Verify SSH jail is active
fail2ban-client status sshd
```

### SSH hardening — disable password authentication

```bash
# Edit /etc/ssh/sshd_config
PasswordAuthentication no
PermitRootLogin prohibit-password   # root access via key only

systemctl restart ssh
```

> **Warning:** Add your public key to `~/.ssh/authorized_keys` BEFORE disabling password authentication or you will lock yourself out.

---

## 2. Docker Installation

```bash
curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker

# Verify
docker --version
docker compose version
```

---

## 3. Stack Deployment

### Clone the repository

```bash
cd ~
git clone https://github.com/boussecsou/shopify-order-n8n-automation.git n8n-automation
cd n8n-automation
```

### Configure environment variables

```bash
cp infrastructure/.env.example .env
nano .env
```

| Variable | Description | How to generate |
|---|---|---|
| `N8N_ENCRYPTION_KEY` | n8n credential encryption key | `openssl rand -hex 32` |
| `N8N_LICENSE_ACTIVATION_KEY` | n8n Enterprise license key | n8n.io account |
| `REDIS_PASSWORD` | Redis authentication password | `openssl rand -hex 24` |
| `N8N_RESTRICT_FILE_ACCESS_TO` | Directories n8n can read from | `/data/metrics` |

```bash
# Generate secure keys
openssl rand -hex 32   # N8N_ENCRYPTION_KEY
openssl rand -hex 24   # REDIS_PASSWORD
```

### Configure Caddy

```bash
cp infrastructure/Caddyfile.example Caddyfile
nano Caddyfile
# Replace ali-n8n.com with your domain
# Replace ai.ali-n8n.com with your subdomain, or remove the block if unused
```

### Start the stack

```bash
docker compose up -d

# Verify all 3 containers are UP
docker compose ps
```

Expected output:

```
NAME              STATUS
n8n-container     Up
redis-container   Up
caddy-proxy       Up
```

### Check logs on first start

```bash
docker compose logs -f n8n
# Wait for: "Editor is now accessible via..."
# Ctrl+C to exit
```

---

## 4. Metrics Directory Setup

```bash
# Create metrics directory under adlin user
mkdir -p /home/adlin/metrics

# Deploy the metrics collection script
cp scripts/vps_metrics.sh /home/adlin/metrics/vps_metrics.sh
chmod +x /home/adlin/metrics/vps_metrics.sh

# The Docker volume mount (read-only) is already defined in docker-compose.yml:
# /home/adlin/metrics:/data/metrics:ro
# n8n reads /data/metrics/vps_metrics.json — no write access
```

---

## 5. Cron Jobs

```bash
crontab -e
```

Add the following lines:

```bash
# Daily backup at 02:00 — archives n8n_data + 7-day rotation
0 2 * * * tar -czf ~/backups/n8n_backup_$(date +\%Y\%m\%d).tar.gz -C ~/n8n-automation n8n_data/ 2>/dev/null && find ~/backups -name 'n8n_backup_*.tar.gz' -mtime +7 -delete

# VPS metrics collection at 07:00 — generates /home/adlin/metrics/vps_metrics.json
0 7 * * * /home/adlin/metrics/vps_metrics.sh >> /home/adlin/metrics/vps_metrics.log 2>&1

# Automatic n8n update every Sunday at 03:30
30 3 * * 0 /root/update-n8n.sh
```

### Deploy the auto-update script

```bash
cp scripts/update-n8n.sh /root/update-n8n.sh
chmod +x /root/update-n8n.sh
mkdir -p ~/logs
```

### Create backup directory

```bash
mkdir -p ~/backups
```

---

## 6. n8n Configuration

### First access

Open `https://your-domain.com` in a browser.
Create the admin account on first launch.

### Import workflows

Go to **Settings → Import Workflow** and import in this order:

| Order | File | Reason |
|---|---|---|
| 1st | `workflows/wf-03-error-handler.json` | All other workflows depend on it |
| 2nd | `workflows/wf-01-som-main.json` | Core pipeline |
| 3rd | `workflows/wf-02-weekly-sheet-controller.json` | Depends on WF-01 data |
| 4th | `workflows/wf-04-vps-ai-monitoring.json` | Independent |

### Configure credentials

Go to **Settings → Credentials** and create:

| Credential | Type | Used by |
|---|---|---|
| Gmail OAuth2 | Google OAuth2 | WF-01, WF-02, WF-03, WF-04 |
| Google Sheets OAuth2 | Google OAuth2 | WF-01, WF-02 |
| Shopify OAuth2 | Shopify OAuth2 | WF-01 |
| OpenRouter API | HTTP Header Auth | WF-01, WF-02 |
| Redis | Redis | WF-01, WF-02 |
| Hostinger API | API Key | WF-04 |
| Telegram Bot | Telegram API | WF-01, WF-02, WF-03, WF-04 (optional) |

### Register WF-03 as error workflow

For each workflow (WF-01, WF-02, WF-04):
1. Open the workflow → **Settings** (gear icon)
2. **Error Workflow** → select `wf-03-error-handler`
3. Save

> **Warning:** Without this step, workflow failures are silent — no alert will be sent.

### Redis initial state

On first run, `shopify:sinceid` does not exist in Redis.
WF-01 will automatically perform a full fetch (up to 250 orders) — this is expected behavior.

To set a specific starting point, manually execute the `Reset sinceId` node
from the WF-01 canvas before activating the workflow.

### Activate workflows

Activate in this order:

| Order | Workflow |
|---|---|
| 1st | `wf-03-error-handler` |
| 2nd | `wf-04-vps-ai-monitoring` |
| 3rd | `wf-02-weekly-sheet-controller` |
| 4th | `wf-01-som-main` ← last |

---

## 7. Post-deployment Verification

```bash
# Docker stack
docker compose ps

# n8n logs (no errors on startup)
docker compose logs n8n --tail=50

# Redis connectivity
docker exec redis-container redis-cli -a "$REDIS_PASSWORD" ping
# Expected: PONG

# VPS metrics
/home/adlin/metrics/vps_metrics.sh
cat /home/adlin/metrics/vps_metrics.json

# SSL
curl -I https://your-domain.com
# Expected: HTTP/2 200
```

Then run WF-01 manually once and verify:
- Rows appear in Google Sheets
- A report email is received
- No errors in n8n execution logs

---

## 8. Updates

### n8n (automatic)

`update-n8n.sh` runs every Sunday at 03:30:
1. Backs up `n8n_data/` before any action — aborts if backup fails
2. Pulls the latest Docker image
3. Restarts only the n8n container (`--no-deps` — Caddy and Redis untouched)
4. Waits for n8n to respond (up to 60s timeout)
5. Sends a confirmation or failure email

### Docker stack (manual)

```bash
cd ~/n8n-automation
docker compose pull
docker compose up -d
```

### OS (automatic)

`unattended-upgrades` applies security updates automatically.
Non-security updates remain manual:

```bash
apt update && apt upgrade -y
```

---

## Cron Jobs — Summary

| Time | Frequency | Action |
|---|---|---|
| 02:00 | Daily | Backup `n8n_data/` + 7-day rotation |
| 07:00 | Daily | Collect VPS metrics → `vps_metrics.json` |
| 03:30 | Every Sunday | Auto-update n8n |

---

## Environment Variables — Reference

| Variable | Required | Description |
|---|---|---|
| `N8N_ENCRYPTION_KEY` | ✅ | Encrypts credentials stored in n8n database |
| `N8N_LICENSE_ACTIVATION_KEY` | ✅ | Enterprise license (advanced features) |
| `REDIS_PASSWORD` | ✅ | Redis authentication |
| `N8N_RESTRICT_FILE_ACCESS_TO` | ✅ | Restricts n8n file access to `/data/metrics` |

> **Security:** The `.env` file must never be committed. It is listed in `.gitignore`.

---

*Author: Ali Boussecsou — [ali-n8n.com](https://ali-n8n.com)*  
*Project: Shopify Order n8n Automation*
