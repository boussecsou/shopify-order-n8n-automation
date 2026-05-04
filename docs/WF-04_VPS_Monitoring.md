# WF-04 — VPS & AI Infrastructure Monitoring

> **Status:** `stable — production` · **Version:** `1.0.0` · **n8n:** `2.15.1`  
> **Instance timezone:** `Africa/Casablanca`

## Overview

Centralized health monitoring for the ali-n8n.com production stack.
Two independent tracks run on separate schedules: a daily VPS health audit
and a bi-hourly AI credit watch. Delivers a daily HTML report via Gmail
and real-time alerts when the OpenRouter balance drops critically low.

### Key Design Decisions

| Decision | Rationale |
|---|---|
| 07:10 AM trigger offset | 10-minute buffer after `vps_metrics.sh` cron at 07:00 AM — eliminates race condition on file write |
| Data freshness guard (30min) | If the JSON is stale, no report is sent — a bad report is worse than no report |
| Hostinger API + local metrics | Combines host-level data (snapshots, Monarx) with OS-level data (disk, RAM, Docker) |
| Silent exit when balance healthy | Track B generates zero noise — alerts only when actionable |
| No AI in alert logic | Thresholds are deterministic code — monitoring must be reliable unconditionally |

---

## Architecture

```
TRACK A — Daily System Health Audit
──────────────────────────────────────────────────────────────
Every day at 07:10 AM
        │
        ├──▶ Read VPS Metrics (file: /data/metrics/vps_metrics.json)
        │    └── Extract from File (binary → JSON)
        │
        ├──▶ List VPS Backups (Hostinger API)
        ├──▶ Get Generic VPS Information (Hostinger API)
        └──▶ Get Generic Monarx Information (Hostinger API)
                │
                ▼
        Build VPS Report (Code — 8 thresholds + freshness guard)
                │
                ▼
        Send VPS Report (Gmail)
        └── on failure → Fallback Telegram (disabled) → StopAndError


TRACK B — Bi-hourly AI Credit Watch
──────────────────────────────────────────────────────────────
Every 2 hours
        │
        ▼
Get OpenRouter credits (HTTP GET /v1/credits)
        │
        ▼
Remaining Credits (Code)
  remaining_balance = total_credits − total_usage
        │
        ▼
Is Balance Below $2? (IF node)
  ├── FALSE → silent exit
  └── TRUE  → Send AI Credits Alert (Gmail)
               └── Fallback Telegram (disabled) → StopAndError
```

---

## Track A — Daily System Health Audit

### Schedule & Timing

| Component | Schedule | Rationale |
|---|---|---|
| `vps_metrics.sh` (cron) | 07:00 AM daily | Collects OS-level metrics, writes JSON |
| This workflow (Track A) | 07:10 AM daily | 10-minute buffer — JSON guaranteed written |

> **Warning:** If you reschedule the cron job, update the Schedule Trigger accordingly.  
> **Warning:** If the server reboots around 07:00 AM, the JSON may not be generated.
> The 30-minute freshness guard catches this and fires the global error workflow.

### Data Sources (Parallel)

| Source | Node | Data collected |
|---|---|---|
| `/data/metrics/vps_metrics.json` | Read VPS Metrics → Extract from File | Disk, RAM, Docker status, backup status, n8n update status |
| Hostinger API | Get Generic VPS Information | VPS state, plan, public IP |
| Hostinger API | List VPS Backups | Snapshot history and age |
| Hostinger API | Get Generic Monarx Information | Malware scan results |

> `vps_metrics.json` is written by `vps_metrics.sh` running via cron on the host.  
> Output path: `/data/metrics/vps_metrics.json` (mounted read-only into n8n container at `/data/metrics`)  
> Logs: `/home/adlin/metrics/vps_metrics.log`

### Build VPS Report (Code Node)

Aggregates all data sources and evaluates 8 alert conditions sequentially.
Each triggered condition appends to an `alerts[]` array.
Final alert count drives the email subject prefix and header color.

#### Data Freshness Guard

Runs **before** all threshold checks.

```
If vps_metrics.json generated_at age > 30 min
  → throws immediately
  → no report is sent
  → StopAndError → global error workflow fires
```

#### Alert Thresholds

| Condition | Level | Threshold |
|---|---|---|
| Disk usage | 🔴 Critical | ≥ 80% |
| RAM usage | 🔴 Critical | ≥ 85% |
| Pending OS updates | 🟡 Warning | > 20 packages |
| Hostinger snapshot age | 🔴 Critical | > 8 days |
| Docker container status | 🔴 Critical | Any container not starting with `"Up"` |
| n8n auto-update status | 🔴 Critical | `status === "failed"` |
| Local n8n backup status | 🔴 Critical | `status !== "ok"` |
| Monarx malware scan | 🔴 Critical | `malicious > 0` |

#### Email Output

| State | Subject prefix | Header color |
|---|---|---|
| All clear | `✅ VPS Nominal` | Green `#27ae60` |
| Alert(s) | `🔴 N issue(s) detected` | Red `#e74c3c` |

- Sender name: `ali-n8n.com Reporting & Monitoring`
- Recipient: `aliboussechill@gmail.com`

---

## Track B — Bi-hourly AI Credit Watch

### Schedule

Fires every 2 hours. Independent from Track A.

### Logic (Remaining Credits — Code Node)

```javascript
remaining_balance = total_credits - total_usage
is_low_balance    = remaining_balance < 2.00
```

### Routing

```
Is Balance Below $2? (IF node)
  TRUE  → Send AI Credits Alert (Gmail)
          Subject: ⚠️ ALERT: OpenRouter Balance Critical (< $2.00)
        → Fallback Telegram — AI Credits (DISABLED)
        → StopAndError → global error workflow
  FALSE → silent exit — no output, no noise
```

> **Warning:** Alert fires every 2 hours while balance stays low.  
> If alert spam becomes an issue, add a Redis cooldown flag before the Gmail node.

---

## Error Handling

| Layer | Mechanism |
|---|---|
| Global | Error workflow `gvhDaCea1oROHUrb` registered on this workflow |
| Gmail nodes | `onError: continueErrorOutput` → Telegram fallback → StopAndError |
| API nodes | `retryOnFail` — 3 attempts, 5s delay |
| Data freshness | `generated_at` age > 30min → immediate throw → global error workflow |

---

## Telegram Fallback (Disabled by Default)

Both Telegram nodes (`Fallback Telegram — VPS Report` and `Fallback Telegram — AI Credits`)
are currently disabled and contain the placeholder `YOUR_TELEGRAM_CHAT_ID`.

**To enable:**
1. Replace `YOUR_TELEGRAM_CHAT_ID` with your real Telegram chat or group ID in both nodes
2. Toggle each node ON independently

> **Warning:** Do not enable without replacing the placeholder — the node will error on every run.

---

## Dependencies

| Service | Credential | Purpose |
|---|---|---|
| Hostinger API | API credential | VPS state, backups, Monarx (VM ID: `1101276`) |
| Gmail | OAuth2 | `aliboussechill@gmail.com` — report + alert delivery |
| OpenRouter | API key | `GET /v1/credits` — balance check (Track B) |
| Telegram | Bot token | Fallback alerts (disabled — requires real `chatId`) |
| `vps_metrics.sh` | Cron on host | Generates `/data/metrics/vps_metrics.json` at 07:00 AM |

---

## Schedule Summary

| Track | Trigger | Cadence |
|---|---|---|
| A — VPS Health | Schedule Trigger | Every day at 07:10 AM |
| B — AI Credits | Schedule Trigger | Every 2 hours |
| Manual | Manual Trigger | On demand (testing) |

---

## Relationship to Other Workflows

| Workflow | Relationship |
|---|---|
| WF-03 Error Handler | **Downstream** — receives failures via error workflow registration |

---

## Changelog

```
1.0.0 — 2026-05 — Initial production release
  • Dual-track architecture (daily health audit + bi-hourly credit watch)
  • 8-condition threshold engine with data freshness guard
  • Hostinger API integration (VPS state, backups, Monarx)
  • Gmail delivery + Telegram fallback (disabled by default)
  • Silent exit on healthy balance — zero noise when all is well
```

---

*Author: Ali Boussecsou — [ali-n8n.com](https://ali-n8n.com)*  
*Project: Shopify Order n8n Automation*
