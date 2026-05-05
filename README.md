# shopify-order-n8n-automation

Automated Shopify paid order pipeline - self-hosted n8n, Redis state management, weekly Google Sheets rotation, AI-generated reports, and infrastructure monitoring. Production-grade.

<img width="1280" height="380" alt="README_WelcomeBanner" src="https://github.com/user-attachments/assets/353e6872-aa64-42c2-b239-84fd06f48b21" />

[![n8n](https://img.shields.io/badge/n8n-%E2%89%A52.15.1-EA4B71?style=flat-square&logo=n8n)](https://n8n.io)
[![Redis](https://img.shields.io/badge/Redis-7--alpine-DC382D?style=flat-square&logo=redis&logoColor=white)](https://redis.io)
[![Docker](https://img.shields.io/badge/Docker-Compose%20v2-2496ED?style=flat-square&logo=docker&logoColor=white)](https://docker.com)
[![Caddy](https://img.shields.io/badge/Caddy-Reverse%20Proxy-00ADD8?style=flat-square)](https://caddyserver.com)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](./LICENSE)
[![Status](https://img.shields.io/badge/Status-Production-brightgreen?style=flat-square)]()
---

## What This Is

A production-grade Shopify order automation system running on a self-hosted VPS.
Every 30 minutes, it polls Shopify for paid orders, normalizes and writes one row
per line item to a dynamically rotating weekly Google Sheets tab, generates an
AI-formatted HTML email report, audits its own data quality every Monday, and
monitors the VPS infrastructure daily.

Built as a publishable technical reference — not a prototype.

> 🎯 **Want the full picture before diving in?**
> Visit **[LOOKME.md](./LOOKME.md)** for the visual showcase
> or download the **[10-page PDF](./docs/LOOKME.pdf)** — architecture diagrams,
> annotated workflow canvases, engineering decisions, and skills matrix.

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
├── README.md
├── LOOKME.md                         # Visual showcase page — start here
├── clickSTAR.md                      # If this project helped you — visit this ⭐
├── LICENSE
│
├── docs/
│   ├── LOOKME.pdf                    # Full 10-page system showcase (download)
│   ├── WF-01_SOM_Main.md
│   ├── WF-02_WeeklyController.md
│   ├── WF-03_ErrorHandler.md
│   ├── WF-04_VPS_Monitoring.md
│   ├── DEPLOYMENT.md
│   └── SECURITY.md
│
├── workflows/
│   ├── wf-01-som-main.json
│   ├── wf-02-weekly-sheet-controller.json
│   ├── wf-03-error-handler.json
│   └── wf-04-vps-ai-monitoring.json
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
| [LOOKME.md](./LOOKME.md) | Visual showcase — architecture, workflows, skills matrix |
| [docs/LOOKME.pdf](./docs/LOOKME.pdf) | Download the full 10-page PDF showcase |
| [WF-01 — SOM Main](./docs/WF-01_SOM_Main.md) | Core pipeline deep-dive |
| [WF-02 — Weekly Controller](./docs/WF-02_WeeklyController.md) | Data quality audit |
| [WF-03 — Error Handler](./docs/WF-03_ErrorHandler.md) | Centralized error routing |
| [WF-04 — VPS Monitoring](./docs/WF-04_VPS_Monitoring.md) | Infrastructure monitoring |
| [Deployment Guide](./docs/DEPLOYMENT.md) | Full VPS setup from scratch |
| [Security](./docs/SECURITY.md) | Security posture and hardening |
| [clickSTAR.md](./clickSTAR.md) | If this project helped you — visit this ⭐ |

<img width="1280" height="380" alt="README_FAQBanner" src="https://github.com/user-attachments/assets/614c2b29-ad09-463d-95bb-b27df376696e" />

## Frequently Asked Questions

> This project is open for learning, inspiration, and adaptation.
> Every question below reflects a real decision, debate, or problem encountered
> while building this system — not theoretical scenarios.

---

### What is this project and who is it for?

**What does this system actually do?**
It polls a real Shopify store every 30 minutes for paid orders, normalizes each
order into one row per line item, writes the data to a dynamically rotating weekly
Google Sheets tab, generates an AI-formatted HTML email report after every run,
audits its own data quality every Monday, and monitors the VPS infrastructure daily.
Everything runs autonomously — zero manual intervention required after setup.

**Who is this for?**
Developers, freelancers, and automation engineers building serious n8n pipelines.
You do not need to be building a Shopify system specifically — the architectural
patterns (stateful polling, Redis cursors, weekly rotation, centralized error
handling, LLM chaining with fallback) apply to any production automation project.

**Is this a tutorial, a template, or a real system?**
All three. It was built from scratch on a real Shopify dev store, runs in production
on a real VPS, and was designed to be fully documented and readable as a reference.
Every decision is explained. Every trade-off is documented.

**Can I use this for my own projects?**
Yes — MIT licensed. Use it, adapt it, reference it. If you borrow a pattern,
understanding why it was chosen is more valuable than the code itself.

---

### Why polling instead of webhooks?

**The honest answer: webhooks were tried first and rejected.**
The project started with a Shopify webhook trigger (SOMWF1 → SOMWF3). After
successfully connecting the Shopify OAuth2 credential and creating a legacy custom
app (`n8n-acess1`) to meet Shopify's protected customer data requirements, the
webhook trigger hit a persistent 403 error on auto-registration. Rather than
fighting Shopify's webhook permission system, polling was evaluated on its merits.

**Why polling turned out to be the right call anyway:**
- Deterministic — runs on a fixed schedule regardless of Shopify's delivery reliability
- Natively retryable — if a run fails, n8n retries automatically
- No public endpoint required — reduces attack surface
- `sinceId` cursor makes deduplication trivial and immune to clock drift
- 30-minute latency is acceptable for the reporting use case

**Is polling "less professional" than webhooks?**
Not for this use case. Webhooks are the right choice for real-time reaction systems
(inventory, fraud detection, live dashboards). For a reporting pipeline where
30-minute latency is acceptable, polling is simpler, more reliable, and easier
to debug.

---

### Why sinceId instead of filtering by date?

**Date-based filtering (`created_at >= last_run_timestamp`) breaks in three ways:**
1. Clock drift between your server and Shopify's servers can miss orders
2. Timezone mismatches create gaps or duplicates at boundary conditions
3. If your cron runs late, you may query a window that excludes recent orders

**`sinceId` is a monotonically increasing Shopify order ID.** Shopify returns only
orders with IDs strictly greater than the stored value. It is completely immune to
time-related issues. The cursor is stored in Redis with no TTL — it survives
container restarts, n8n upgrades, and redeploys.

**What happens on the very first run?**
`shopify:sinceid` does not exist in Redis. The IF node takes the `false` branch
and fetches without a `sinceId` parameter (full fetch, up to 250 orders). After
the run, the maximum order ID is stored. All subsequent runs are incremental.

**Does n8n stop the workflow if Shopify returns 0 new orders?**
Yes — and that is correct behavior. When a node returns 0 results, n8n halts
execution cleanly. No guard node is needed. This was confirmed by testing: a run
with `sinceId` present but no new orders stopped cleanly without errors.

---

### Why one row per line item instead of one row per order?

**The problem with one row per order:**
If you store `total_revenue` per order in a single row and that order has 3 products,
any SUM aggregation on the sheet returns `3 × total_revenue` — triple-counted.
You then need complex deduplication logic on every query.

**One row per line item means:**
- Order metadata is repeated on every row (order_id, customer, etc.)
- Every aggregation is correct by default — no deduplication needed
- Per-SKU, per-product, per-variant analysis is trivial
- The sheet is a proper line-item-level data lake

This was validated against real orders: command #1011 with 3 products generated
3 rows, and `SUM(total_line_price)` = $3815.27 matched the Shopify order total exactly.

---

### Why Redis instead of n8n Static Data or Google Sheets?

**Three options were compared in depth:**

| | Redis | n8n Static Data | Google Sheets |
|---|---|---|---|
| Complexity | Already deployed | Zero | Medium |
| Reliability | High | Medium | Depends on Google API |
| Debuggability | `redis-cli GET key` | Difficult | Visual |
| Survives workflow re-import | ✅ Yes | ❌ No | ✅ Yes |
| Survives n8n upgrade | ✅ Yes | ❌ Risky | ✅ Yes |
| Speed | Microseconds | Fast | 300–800ms |
| Production-grade | ✅ | Medium | ❌ |

**The decision:** Redis was already deployed, secured, and connected on the VPS.
Using it cost zero additional infrastructure. n8n Static Data was the only real
alternative — but it is lost on workflow re-import and harder to inspect.
Google Sheets for state storage is an anti-pattern: you are making an external API
call on every cron run to read a single cell.

**Only two Redis keys are used in this entire system:**
- `shopify:sinceid` — the order ID cursor (no TTL)
- `shopify:sheet:name` — the active weekly tab name (updated on week rollover)

---

### Why `WEEK{n}_{year}` format for sheet names?

**Two formats were evaluated:**
1. `2026-04-14` (date of Monday of the ISO week)
2. `WEEK16_2026` (ISO week number and year)

**The Monday-date format was implemented first and caused a bug.**
Mixing JavaScript's Monday-based date calculation with the ISO week number
calculation introduced an interference bug — the week number was correct but
the year in edge cases (late December / early January) was wrong.

**`WEEK16_2026` was chosen because:**
- Simpler to compute — one calculation, not two
- Unambiguous — no confusion about which Monday corresponds to which week
- ISO 8601 correct — uses the Thursday-anchored algorithm in UTC
- Non-ambiguous at year boundaries — `WEEK1_2027` is clear even if it starts
  in December 2026

**Important:** ISO week year ≠ calendar year. Week 1 of 2027 can start in late
December 2026. This is correct behavior — do not "fix" it.

---

### Why is AI excluded from error handling?

**The principle: error handling must be reliable unconditionally.**
LLMs can fail, time out, return malformed output, or hit rate limits — none of
which is acceptable when the system is already in a failure state and you need
to be notified reliably.

**What is used instead:**
Native n8n error data (`execution.error.message`, `execution.lastNodeExecuted`,
`execution.url`) normalized by a deterministic Set node. The output is always
predictable, always formatted correctly, always delivered.

**AI is used only where its failure is non-critical:**
- WF-01: formatting the run report email (fallback LLM available)
- WF-02: formatting the audit report email (fallback LLM available)

In both cases, if both LLMs fail, the Gmail node errors → Telegram fallback →
StopAndError → WF-03 catches it. The failure is never silent.

---

### How does the LLM fallback chain work?

**The primary/fallback pattern in n8n:**
Both WF-01 and WF-02 use a `chainLlm` node with `needsFallback: true`.
Two LLM nodes are connected: index 0 (primary) and index 1 (fallback).
If the primary fails, n8n automatically routes to the fallback.

**Current models:**
- Primary: Grok 4 Fast via OpenRouter
- Fallback: Claude Haiku 4.5 via OpenRouter

**Why OpenRouter instead of direct API calls?**
Single credential, single endpoint, model switching without credential changes.
If you want to swap models, you change the model string — nothing else.

**LLM role is strictly limited to formatting:**
The Code node prepares a clean, structured JSON payload (order counts, revenue,
VIP count, anomalies, etc.). The LLM receives this JSON and populates a fixed
HTML skeleton with hardcoded colors. It never evaluates data, makes routing
decisions, or invents content. All business logic is deterministic JS.

---

### How does the weekly sheet rotation work technically?

On every trigger, Track A runs in parallel with Track B. It:
1. Reads the stored sheet name from Redis (`shopify:sheet:name`)
2. Computes the current ISO week name using the Thursday-anchored algorithm (UTC)
3. Compares: `week_changed = (stored_name !== computed_name)`
4. If `false` → exits, Track B uses the existing tab
5. If `true` → creates a new Google Sheets tab, writes 20-column headers via
   HTTP PUT to the Sheets REST API v4, applies formatting via `batchUpdate`
   (dark green header, white bold text, frozen row, per-column widths), then
   updates Redis

**Why does Track B read the sheet name from Redis independently?**
Because Track B cannot reference Track A's output directly — they run in parallel.
Each track reads `shopify:sheet:name` from Redis independently at the start.
Track A updates Redis when the week changes; Track B always reads the current value.

**The `sheet_name` injection:**
The Code node "Split Line Items & Sheet Row Parser" injects `sheet_name` into
every row object via `$('Compute & Check Sheet Week').first().json.computed_name`.
This allows the Google Sheets Append node to reference `$json.sheet_name`
dynamically without hardcoding.

---

### How does the Shopify OAuth2 credential work?

A legacy custom app (`n8n-acess1`) was created in Shopify Partners to meet
protected customer data requirements. A standard Shopify app would return a 403
error when trying to access customer data (email, name, address).

The credential (`n8n-acess1_oauth2`) uses Shopify OAuth2 in n8n. The store
used for development is `bluid-n8n-automation-store.myshopify.com` (Shopify
Partners dev store — free, no payments required for testing).

---

### What are the most common mistakes to avoid?

These are real issues encountered during development:

| Issue | Symptom | Fix |
|---|---|---|
| Missing `sendHtml: true` on Gmail nodes | Email renders as raw HTML text | Enable `sendHtml` on every Gmail node |
| Model name drift | Node label says "Grok 4 Fast" but wrong model configured | Verify the actual model string in each LLM node |
| `N8N_EDITOR_BASE_URL` not set | Execution links in error emails are broken or relative | Set `N8N_EDITOR_BASE_URL=https://your-domain.com` in `.env` |
| ISO week year vs calendar year confusion | Sheet named `WEEK1_2026` instead of `WEEK1_2027` in late December | Use Thursday-anchored ISO algorithm, not `getFullYear()` |
| IF combinator set to `OR` instead of `AND` | Empty string `""` passes the sinceId check | Use `AND` combinator — both `exists` AND `notEmpty` |
| WF-03 not registered on new workflows | Failures are silent — no alert sent | Register `gvhDaCea1oROHUrb` as error workflow on every new WF |
| `EXECUTIONS_DATA_PRUNE` not set | SQLite grows indefinitely | Set pruning env var to manage execution history size |

---

### What are the current known limitations?

These are documented openly — no system is perfect:

| Limitation | Impact | Status |
|---|---|---|
| SQLite internal database | Performance degrades at scale, no queue mode | PostgreSQL migration planned for v2 |
| Backups stored on same disk | Full disk failure = data + backup loss | Off-site via `rclone` planned for v2 |
| Max 250 orders per Shopify poll | Gap possible if >250 orders arrive between runs | Volume alerts surface this; pagination loop planned for v2 |
| Telegram alerts disabled | Delayed notification if Gmail fails | Enable after setting real `chatId` in alert nodes |
| No off-site backup | Disk failure = total loss | `rclone` → Google Drive / S3 planned for v2 |

---

### What can I reuse from this project?

These patterns work independently of Shopify and n8n:

| Pattern | Applicable to |
|---|---|
| `sinceId` incremental cursor | Any API with monotonically increasing record IDs |
| Redis as workflow state store | Any stateful automation that needs persistence across runs |
| SplitInBatches write loop | Any bulk write to an external API |
| Centralized error handler (hub-and-spoke) | Any multi-workflow n8n instance |
| Primary/fallback LLM chain | Any AI-powered automation needing reliability |
| Pure JS audit engine | Any structured dataset — not Shopify-specific |
| Weekly rotation via Redis | Any time-partitioned data storage pattern |
| Data freshness guard (fail-fast) | Any system that reads from a file or cache |

**Where to start:**
- Read `LOOKME.pdf` for the visual overview
- Read `docs/WF-01_SOM_Main.md` for the core architecture
- Import `wf-03-error-handler.json` first — it is 4 nodes, immediately useful,
  and the foundation everything else depends on

---

### Can I contribute?

Issues and pull requests are welcome.
If you have adapted a pattern from this project for a different use case,
open an issue and share it — the goal is to build a useful reference for
the automation community.

---

## Author

**Ali Boussecsou**
[ali-n8n.com](https://ali-n8n.com) · [GitHub @boussecsou](https://github.com/boussecsou)

---

*MIT License — feel free to use, adapt, and reference this project.*
