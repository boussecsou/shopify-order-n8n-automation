# WF-01 — Shopify Order Manager (Main)

> **Status:** `stable — production` · **Version:** `1.0.0` · **n8n:** `2.15.1`

## Overview

Core ingestion and reporting pipeline for Shopify paid orders.
Polls incrementally every 30 minutes → writes one row per line item to a rotating weekly Google Sheets tab → delivers an AI-generated HTML email report after each run.

### Key Design Decisions

| Decision | Rationale |
|---|---|
| Polling over webhooks | Deterministic, retryable, no public endpoint exposure |
| `sinceId` cursor over date filtering | Monotonically increasing — immune to clock drift and timezone issues |
| One row per line item | Avoids aggregation duplication; enables per-SKU analysis |
| Redis over n8n Static Data | Survives container restarts and redeploys; already in the stack |
| ISO 8601 week (Thursday anchor) | Standard week definition — unambiguous across year boundaries |

---

## Architecture

Two tracks execute in parallel on every trigger. Track A ensures the correct weekly tab exists before Track B writes any data.

```
Schedule Trigger (every 30min)
├── TRACK A — Sheet Week Management
│   ├── Read sheet name from Redis
│   ├── Compute ISO week (UTC)
│   └── week_changed?
│       ├── FALSE → no-op
│       └── TRUE  → Create tab → Write headers → Format → Update Redis
│
└── TRACK B — Order Data Pipeline
    ├── Read sheet name from Redis
    ├── Read sinceId cursor from Redis
    ├── sinceId exists?
    │   ├── YES → Incremental fetch (sinceId param, ≤250 orders)
    │   └── NO  → Full fetch (first run or post-reset, ≤250 orders)
    ├── Has Orders?
    │   ├── FALSE → 0-order alert (Gmail + Telegram) → stop
    │   └── TRUE  → SplitInBatches loop (batch size: 1)
    │       ├── [batching] Split line items → Append row to sheet → loop
    │       └── [done] ─┬─ Get max sinceId → Set sinceId in Redis (no TTL)
    │                   └─ Aggregate Orders → AI Report → Gmail
    │                       └── Volume alert routing (≥50 / ≥100)
```

---

## Outputs

| Output | Trigger | Channel |
|---|---|---|
| Google Sheets row(s) | Every run with orders | Weekly rotating tab |
| AI run report email | Every successful run | Gmail (HTML) |
| Volume alert | orders ≥ 50 or ≥ 100 per run | Gmail + Telegram |
| 0-order alert | No new orders returned | Gmail + Telegram |

---

## Track A — Sheet Week Management

Runs on every trigger in parallel with Track B.
Ensures the correct weekly tab exists before Track B writes rows.

### Week Naming Format

```
WEEK{n}_{year}

Examples:
  WEEK16_2026
  WEEK52_2026
  WEEK1_2027   ← year follows ISO week year, NOT calendar year
```

> **Warning:** Week 1 of 2027 can start in late December 2026. This is correct ISO 8601 behavior — do not "fix" it.

### Execution Flow

1. Read stored tab name from Redis (`shopify:sheet:name`)
2. Compute current ISO 8601 week using Thursday-anchored algorithm (UTC)
   - Outputs: `computed_name`, `week_changed` (boolean)
3. **`week_changed = false`** → exit, existing tab is reused
4. **`week_changed = true`** →
   1. Create new tab in Google Sheets
   2. Write 20-column headers via HTTP PUT (`/values/{tab}!A1:T1`)
   3. Format header row via HTTP batchUpdate:
      - Dark green background / white bold text / frozen row / per-column widths
   4. Set new tab name in Redis

### Column Schema (A → T)

| Col | Field | Col | Field |
|-----|-------|-----|-------|
| A | `inserted_at` | K | `tags` |
| B | `order_id` | L | `line_item_id` |
| C | `order_number` | M | `product_name` |
| D | `created_at` | N | `variant` |
| E | `customer_name` | O | `sku` |
| F | `customer_email` | P | `quantity` |
| G | `is_vip` | Q | `unit_price` |
| H | `shipping_country` | R | `total_line_price` |
| I | `payment_method` | S | `total_discount` |
| J | `currency` | T | `is_custom_item` |

---

## Track B — Order Data Pipeline

### Entry

1. Read active sheet name from Redis (`shopify:sheet:name`)
2. Read sinceId cursor from Redis (`shopify:sinceid`)
3. **`sinceId` exists?**
   - **YES** → incremental fetch (sinceId param, up to 250 paid orders)
   - **NO** → full fetch (first run or post-reset, up to 250 paid orders)

### Shopify Order Parser (Code Node)

Normalizes raw Shopify payload to a typed schema.

| Field | Detail |
|---|---|
| Reference currency | `shop_money` (USD via `price_set.shop_money`) |
| Presentment currency | `display_currency` — tracked for reference only |
| VIP detection | `customer.tags` includes `"VIP"` (comma-split, case-sensitive) |
| Custom item flag | `product_id === null` |

### Has Orders? (IF Node)

> `"Get many orders with sinceId"` has `alwaysOutputData: true` — the workflow continues with an empty payload when 0 new orders exist. `"Has Orders?"` is the explicit guard for this path.

- **FALSE** → 0-order alert email + Telegram → stop
- **TRUE** → SplitInBatches loop (batch size: 1)

### SplitInBatches Loop

```
batching branch → Split Line Items & Sheet Row Parser → Append row → loop back
done branch     → (parallel)
                   • Get Max sinceId → Set sinceId in Redis (no TTL)
                   • Aggregate Orders for Email → AI report chain
```

### Split Line Items & Sheet Row Parser (Code Node)

- One row per line item — order metadata repeated on every row
- Timestamps converted to `Europe/Paris` before insert
- `sheet_name` injected into each row from `Compute & Check Sheet Week` output

---

## AI Report & Volume Alerts

### Aggregation

`"Aggregate Orders for Email"` computes per run:

```
orders_count       total_revenue      total_discounts
vip_count          total_line_items   custom_items_count
volume_alert       (nullable string — set when threshold is breached)
```

### Volume Alert Routing

```
Count Orders
└── Is count_order >= 100?
    ├── TRUE  → Send >100 Alert (Gmail + Telegram fallback)
    └── FALSE → Is count_order >= 50?
                ├── TRUE  → Send >50 Alert (Gmail + Telegram fallback)
                └── FALSE → silent exit
```

> **Warning:** The `volume_alert` threshold constant in `"Aggregate Orders for Email"` is hardcoded at `50`. If you change the IF node thresholds, update that constant too.

### AI Email Generation

| Parameter | Value |
|---|---|
| Primary LLM | Grok 4 Fast (OpenRouter) |
| Fallback LLM | Claude Haiku 4.5 (`needsFallback: true`, auto-activates on failure) |
| Template | Fixed HTML skeleton with hardcoded colors |
| Content policy | Real data only — no invented content, no hallucinated metrics |
| `volume_alert` | Passed directly to LLM when threshold is breached |

Output → `"Create subject"` (Set node) → `"Send run report"` (Gmail)

### Gmail Error Path

```
Send run report
├── branch 0 (success) → silent
└── branch 1 (failure) → Fallback Telegram — Run Report → StopAndError
```

---

## Redis State Reference

### `shopify:sinceid`

Monotonically increasing Shopify order ID used as pagination cursor.

| Operation | Node | Effect |
|---|---|---|
| GET | `"Get last sinceId"` | Drives the sinceId IF branch |
| SET | `"Set max sinceId (NoTTL)"` | Updated each successful run, no TTL |
| DEL | `"Reset sinceId"` | Clears cursor → next run = full fetch |

> **Warning:** No TTL is intentional. Cursor survives restarts and redeploys.  
> **Warning:** Shopify returns max 250 orders per call. If >250 orders arrive between two runs, some will be missed. Volume alerts exist to surface this.  
> **Warning:** Cursor stale or corrupted → run `"Reset sinceId"` from canvas (manual only).

### `shopify:sheet:name`

Active Google Sheets tab name (e.g. `"WEEK16_2026"`).
Read by both tracks independently at the start of every run.

| Operation | Node | Effect |
|---|---|---|
| GET | `"Get actual sheet name from Redis (1st Branch)"` | Track A week check |
| GET | `"Get sheet name for branch2 from Redis"` | Track B sheet target |
| SET | `"Set sheet name"` | Only when `week_changed = true` |
| SET (manual) | `"Reset sheet_name"` | See Resets section |

---

## Error Handling

| Layer | Mechanism |
|---|---|
| Global | Error workflow `gvhDaCea1oROHUrb` registered on this workflow |
| Gmail nodes | `onError: continueErrorOutput` → Telegram fallback → StopAndError |
| API nodes (Shopify, Redis, Sheets) | `retryOnFail` — 3 attempts, 5s delay |

---

## Manual Operations (Canvas Only)

> These nodes are **not connected** to the main flow. Execute them individually from the n8n canvas when explicitly needed.

### Reset sinceId
Deletes `shopify:sinceid` from Redis.  
**Effect:** next run performs a full fetch (up to 250 paid orders).  
**Use when:** cursor is stale, corrupted, or a full re-sync is needed.

### Reset sheet_name
Sets `shopify:sheet:name` to the current ISO week name.  
Value is computed dynamically — always resolves to the correct `WEEK{n}_{year}`.  
**Use when:** Redis key is lost, corrupted, or after a manual rollback.

---

## Dependencies

| Service | Credential | Purpose |
|---|---|---|
| Redis | Docker internal (`n8n_network`) | `sinceId` cursor, sheet name state |
| Google Sheets | OAuth2 | `ShopifyPaidOrders_Spreadsheet` |
| Shopify | OAuth2 `n8n-acess1_oauth2` | Paid orders, any fulfillment status |
| Gmail | OAuth2 | `aliboussechill@gmail.com` |
| OpenRouter | API key | Grok 4 Fast / Claude Haiku 4.5 |
| Telegram | Bot token | Volume + error fallback alerts (requires `chatId`) |

---

## Schedule

| Trigger | Cadence | Purpose |
|---|---|---|
| Schedule Trigger | Every 30 minutes | Production polling |
| Manual Trigger | On demand | Testing only |

---

## Changelog

```
1.0.0 — 2026-05 — Initial production release
  • sinceId polling architecture (webhooks evaluated and rejected)
  • One row per line item data model
  • ISO 8601 week rotation with Redis state
  • AI report chain with primary/fallback LLM
  • Volume alerts (≥50 / ≥100 orders per run)
  • Global error workflow + Telegram fallback on all Gmail nodes
```

---

*Author: Ali Boussecsou — [ali-n8n.com](https://ali-n8n.com)*  
*Project: Shopify Order n8n Automation*
