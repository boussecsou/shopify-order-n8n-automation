[![n8n](https://img.shields.io/badge/n8n-%E2%89%A52.15.1-EA4B71?style=flat-square&logo=n8n)](https://n8n.io)
[![Redis](https://img.shields.io/badge/Redis-7--alpine-DC382D?style=flat-square&logo=redis&logoColor=white)](https://redis.io)
[![Docker](https://img.shields.io/badge/Docker-Compose%20v2-2496ED?style=flat-square&logo=docker&logoColor=white)](https://docker.com)
[![Caddy](https://img.shields.io/badge/Caddy-Reverse%20Proxy-00ADD8?style=flat-square)](https://caddyserver.com)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](./LICENSE)
[![Status](https://img.shields.io/badge/Status-Production-brightgreen?style=flat-square)]()
# shopify-order-n8n-automation

Automated Shopify paid order pipeline - self-hosted n8n, Redis state management, weekly Google Sheets rotation, AI-generated reports, and infrastructure monitoring. Production-grade.

<img width="1280" height="380" alt="README_WelcomeBanner" src="https://github.com/user-attachments/assets/353e6872-aa64-42c2-b239-84fd06f48b21" />

---

## What This Is

A production-grade Shopify order automation system running on a self-hosted VPS.
Every 30 minutes, it polls Shopify for paid orders, normalizes and writes one row
per line item to a dynamically rotating weekly Google Sheets tab, generates an
AI-formatted HTML email report, audits its own data quality every Monday, and
monitors the VPS infrastructure daily.

Built as a publishable technical reference — not a prototype.

📄 **[System Architecture & Engineering Showcase (PDF)](./LOOKME.pdf)**

---

## Architecture

```
EXTERNAL APIS
  Shopify ──────────────────────────────────────────────────┐
  Google Sheets ────────────────────────────────────────┐   │
  OpenRouter (AI) ──────────────────────────────────┐   │   │
                                                    │   │   │
APPLICATION LAYER                                   │   │   │
  n8n Enterprise v2.18.5 (self-hosted) ─────────────┘───┘───┘
  Redis 7-alpine (state management)

RUNTIME
  Docker Engine 29.x + Docker Compose v2

NETWORK & PROXY
  Caddy (reverse proxy + automatic Let's Encrypt SSL)

HARDWARE & OS
  Hostinger KVM2 VPS — 2 vCPU / 8 GB RAM / 96 GB
  Ubuntu 24.04 LTS
```

---

## The 4 Workflows

| Workflow | Trigger | Purpose | Doc |
|---|---|---|---|
| **WF-01** SOM Main | Every 30min | Shopify polling → Google Sheets → AI report | [→](./docs/WF-01_SOM_Main.md) |
| **WF-02** Weekly Controller | Monday 06:00 UTC | 7-check data quality audit | [→](./docs/WF-02_WeeklyController.md) |
| **WF-03** Error Handler | On any workflow failure | Centralized alert fan-out (Gmail + Telegram) | [→](./docs/WF-03_ErrorHandler.md) |
| **WF-04** VPS Monitoring | Daily 07:10 + every 2h | VPS health audit + OpenRouter credit watch | [→](./docs/WF-04_VPS_Monitoring.md) |

---

## WF-01 — Core Pipeline

```
Schedule Trigger (every 30min)
├── TRACK A — Sheet Week Management
│   ├── Read shopify:sheet:name from Redis
│   ├── Compute ISO 8601 week (UTC, Thursday-anchored)
│   └── week_changed?
│       ├── FALSE → no-op
│       └── TRUE  → Create tab → Write headers → Format → Update Redis
│
└── TRACK B — Order Data Pipeline
    ├── Read shopify:sinceid cursor from Redis
    ├── Fetch paid orders from Shopify (incremental or full, ≤250)
    ├── Has Orders?
    │   ├── FALSE → 0-order alert → stop
    │   └── TRUE  → SplitInBatches (1 row per line item)
    │       ├── [loop]  → Append row to Google Sheets
    │       └── [done]  → Update sinceId in Redis
    │                   → Aggregate → AI Report → Gmail
    │                   → Volume alerts (≥50 / ≥100 orders)
```

### Key Design Decisions

| Domain | Standard Approach | This System |
|---|---|---|
| Data ingestion | Webhooks | 30-min polling — deterministic, retryable, no public endpoint |
| Deduplication | Filter by `created_at` | `sinceId` cursor — immune to clock drift and timezone issues |
| State storage | n8n Static Data | Redis — survives container restarts and n8n upgrades |
| Data model | One row per order | One row per line item — prevents aggregation duplication |
| AI usage | LLM evaluates data | LLM formats HTML only — all logic is deterministic |

---

## Stack

| Layer | Technology | Role |
|---|---|---|
| Automation | n8n Enterprise ≥2.15.1 | Workflow engine |
| State | Redis 7-alpine | `sinceId` cursor, sheet name |
| Proxy | Caddy | Reverse proxy + automatic SSL |
| Data | Google Sheets | Weekly rotating order data lake |
| Source | Shopify OAuth2 | Paid order ingestion |
| AI | OpenRouter (Grok 4 Fast / Claude Haiku 4.5) | Report generation |
| Alerts | Gmail + Telegram | Run reports, errors, volume alerts |
| Monitoring | Hostinger API + Monarx | VPS health, snapshots, malware |
| OS | Ubuntu 24.04 LTS | Host operating system |
| Containers | Docker Compose v2 | Service orchestration |

---

## Security

| Layer | Measure |
|---|---|
| Firewall | UFW — deny all inbound except 22, 80, 443 |
| SSH | Key-only — `PasswordAuthentication no` |
| Brute-force | Fail2Ban active on SSH jail |
| TLS | Caddy auto-renew — HSTS, X-Frame, nosniff, `-Server` |
| Network | Redis internal Docker network only — never exposed |
| File access | n8n restricted to `/data/metrics` via env var |
| Malware | Monarx agent active on host |
| Secrets | `.env` never committed — encrypted at rest via n8n |
| Updates | `unattended-upgrades` auto-applies security patches |

→ Full details in [docs/SECURITY.md](./docs/SECURITY.md)

---

## Automation & Ops

| Time | Frequency | Action |
|---|---|---|
| 02:00 | Daily | Backup `n8n_data/` + 7-day rotation |
| 07:00 | Daily | `vps_metrics.sh` → generates `vps_metrics.json` |
| 03:30 | Every Sunday | `update-n8n.sh` — auto-update n8n with pre-backup |

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/boussecsou/shopify-order-n8n-automation.git
cd shopify-order-n8n-automation

# 2. Configure
cp infrastructure/.env.example .env
# Fill in N8N_ENCRYPTION_KEY, N8N_LICENSE_ACTIVATION_KEY,
# REDIS_PASSWORD, N8N_RESTRICT_FILE_ACCESS_TO

# 3. Configure Caddy
cp infrastructure/Caddyfile.example Caddyfile
# Replace your-domain.com with your actual domain

# 4. Start
docker compose -f infrastructure/docker-compose.yml up -d

# 5. Import workflows (in order)
# n8n UI → Settings → Import Workflow
# wf-03 → wf-01 → wf-02 → wf-04
```

→ Full deployment guide in [docs/DEPLOYMENT.md](./docs/DEPLOYMENT.md)

---

## Repository Structure

```
shopify-order-n8n-automation/
├── LOOKME.pdf                        # Visual system showcase (10 pages)
├── README.md
├── LICENSE
│
├── workflows/
│   ├── wf-01-som-main.json
│   ├── wf-02-weekly-sheet-controller.json
│   ├── wf-03-error-handler.json
│   └── wf-04-vps-ai-monitoring.json
│
├── docs/
│   ├── WF-01_SOM_Main.md
│   ├── WF-02_WeeklyController.md
│   ├── WF-03_ErrorHandler.md
│   ├── WF-04_VPS_Monitoring.md
│   ├── DEPLOYMENT.md
│   └── SECURITY.md
│
├── infrastructure/
│   ├── docker-compose.yml
│   ├── Caddyfile.example
│   └── .env.example
│
└── scripts/
    ├── vps_metrics.sh
    └── update-n8n.sh
```

---

## Known Limitations (v2 Roadmap)

| Limitation | Planned Fix |
|---|---|
| SQLite internal database | Migration to PostgreSQL |
| Local backups only (same disk) | Off-site via `rclone` → Google Drive / S3 |
| Max 250 orders per Shopify poll | Pagination loop (v2) |
| Telegram alerts disabled | Enable after configuring real `chatId` |

---

## Documentation

| Document | Description |
|---|---|
| [LOOKME.pdf](./LOOKME.pdf) | Full visual system showcase — start here |
| [WF-01 — SOM Main](./docs/WF-01_SOM_Main.md) | Core pipeline deep-dive |
| [WF-02 — Weekly Controller](./docs/WF-02_WeeklyController.md) | Data quality audit |
| [WF-03 — Error Handler](./docs/WF-03_ErrorHandler.md) | Centralized error routing |
| [WF-04 — VPS Monitoring](./docs/WF-04_VPS_Monitoring.md) | Infrastructure monitoring |
| [Deployment Guide](./docs/DEPLOYMENT.md) | Full VPS setup from scratch |
| [Security](./docs/SECURITY.md) | Security posture and hardening |

---

## Author

**Ali Boussecsou**
[ali-n8n.com](https://ali-n8n.com) · [GitHub @boussecsou](https://github.com/boussecsou)

---

*MIT License — feel free to use, adapt, and reference this project.*
