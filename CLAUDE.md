# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

A production-grade Shopify order automation system: 4 n8n workflows, a Docker Compose stack (n8n + Redis + Caddy), VPS shell scripts, and full documentation. There is no application code to build or test — the runnable artifacts are JSON workflow exports and shell scripts.

## Stack

| Layer | Technology |
|---|---|
| Automation engine | n8n Enterprise ≥2.15.1 (self-hosted, Docker) |
| State management | Redis 7-alpine — only two keys: `shopify:sinceid`, `shopify:sheet:name` |
| Proxy + SSL | Caddy (automatic Let's Encrypt) |
| Data store | Google Sheets (weekly rotating tabs) |
| AI (report formatting only) | OpenRouter → Grok 4 Fast (primary) / Claude Haiku 4.5 (fallback) |
| Alerts | Gmail + Telegram |
| VPS monitoring | Hostinger API + Monarx |

## Workflow Overview

| File | ID | Trigger | Role |
|---|---|---|---|
| `wf-01-som-main.json` | WF-01 | Every 30min | Shopify polling → Sheets → AI report |
| `wf-02-weekly-sheet-controller.json` | WF-02 | Monday 06:00 UTC | 7-check data quality audit |
| `wf-03-error-handler.json` | WF-03 | Any workflow error | Centralized Gmail + Telegram alert fan-out |
| `wf-04-vps-ai-monitoring.json` | WF-04 | Daily 07:10 + every 2h | VPS health + OpenRouter credit watch |

**Import order matters:** WF-03 must be imported first; all other workflows register it as their error workflow. WF-03's workflow ID (`gvhDaCea1oROHUrb`) is hardcoded as the error handler in the other workflows.

## Stack Commands

```bash
# Start the stack (run from infrastructure/ or project root with -f flag)
docker compose -f infrastructure/docker-compose.yml up -d

# Check container status
docker compose -f infrastructure/docker-compose.yml ps

# Tail n8n logs
docker compose -f infrastructure/docker-compose.yml logs -f n8n

# Test Redis connectivity
docker exec redis-container redis-cli -a "$REDIS_PASSWORD" ping

# Inspect Redis state keys
docker exec redis-container redis-cli -a "$REDIS_PASSWORD" GET shopify:sinceid
docker exec redis-container redis-cli -a "$REDIS_PASSWORD" GET shopify:sheet:name

# Run VPS metrics script manually
/home/adlin/metrics/vps_metrics.sh
```

## Environment Setup

```bash
cp infrastructure/.env.example .env
# Fill: N8N_ENCRYPTION_KEY, N8N_LICENSE_ACTIVATION_KEY, REDIS_PASSWORD, N8N_RESTRICT_FILE_ACCESS_TO

cp infrastructure/Caddyfile.example Caddyfile
# Replace ali-n8n.com with your domain
```

Generate secrets:
```bash
openssl rand -hex 32   # N8N_ENCRYPTION_KEY
openssl rand -hex 24   # REDIS_PASSWORD
```

## Critical Architectural Invariants

These are non-obvious decisions that must not be "fixed":

- **`sinceId` cursor, not date filtering** — `shopify:sinceid` is a monotonically increasing Shopify order ID stored in Redis with no TTL. Do not replace with timestamp-based filtering; it is immune to clock drift and timezone issues by design.
- **One row per line item, not per order** — Aggregating at the order level causes revenue triple-counting when an order has multiple products. The sheet is a line-item data lake.
- **ISO week year ≠ calendar year** — Sheet tabs use `WEEK{n}_{year}` where year follows the ISO 8601 week year (Thursday-anchored). Week 1 of 2027 can start in late December 2026. This is correct.
- **Track A and Track B read Redis independently** — In WF-01, the two parallel tracks cannot share data. Each reads `shopify:sheet:name` from Redis at the start. Track A updates Redis when the week rolls over; Track B always reads the current value.
- **AI is formatting-only** — LLMs receive structured JSON and populate a fixed HTML skeleton. All business logic (routing, thresholds, aggregation) is deterministic JavaScript. AI is never used in error handling paths.
- **WF-03 must not use AI** — Error handling must be unconditionally reliable. WF-03 uses only native n8n error data normalized by a Set node.

## Common Mistakes (from real development)

| Symptom | Fix |
|---|---|
| Email renders as raw HTML | Enable `sendHtml: true` on every Gmail node |
| Execution links in error emails are broken | Set `N8N_EDITOR_BASE_URL=https://your-domain.com` in `.env` |
| Empty string `""` passes the sinceId check | IF combinator must be `AND` (both `exists` AND `notEmpty`) |
| Workflow failures are silent | Register WF-03 (`gvhDaCea1oROHUrb`) as error workflow on every workflow |
| SQLite grows indefinitely | Set `EXECUTIONS_DATA_PRUNE` env var |
| Wrong sheet year in late December | Use Thursday-anchored ISO algorithm, not `getFullYear()` |

## Repository Layout

```
workflows/          # n8n JSON exports — the primary deployable artifacts
infrastructure/     # docker-compose.yml, Caddyfile.example, .env.example
scripts/            # vps_metrics.sh (cron, daily 07:00), update-n8n.sh (cron, Sunday 03:30)
docs/               # Per-workflow deep-dives, deployment guide, security reference
```

## Automated Cron Jobs (on the VPS)

| Time | Frequency | Script |
|---|---|---|
| 02:00 | Daily | Backup `n8n_data/` + 7-day rotation |
| 07:00 | Daily | `scripts/vps_metrics.sh` → `/home/adlin/metrics/vps_metrics.json` |
| 03:30 | Every Sunday | `scripts/update-n8n.sh` — backs up, pulls latest n8n image, restarts container |
