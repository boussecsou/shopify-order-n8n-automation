# WF-02 — Weekly Sheet Quality Controller

> **Status:** `stable — production` · **Version:** `1.0.0` · **n8n:** `2.15.1`  
> **Depends on:** WF-01 (tab creation), Redis (sheet name state)

## Overview

Weekly automated audit of Shopify order data stored in Google Sheets.
Every Monday at 06:00 UTC, reads the previous ISO week tab, runs a 7-check
pure JS audit engine, and delivers a structured HTML quality report via Gmail.

### Key Design Decisions

| Decision | Rationale |
|---|---|
| Runs Monday 06:00 UTC | WF-01 has had the full week to accumulate data |
| Targets previous week (now − 7 days) | Audits completed data, not in-progress week |
| Pure JS audit engine, zero dependencies | No external calls — deterministic, fast, portable |
| LLM for report formatting only | AI never evaluates data — only formats the audit JSON into HTML |
| Tab creation delegated to WF-01 | Single source of truth for sheet structure |

---

## Architecture

```
Schedule Trigger (Monday 06:00 UTC)
│
├── Compute Previous Week Sheet Name (Code)
│   └── output: { current_week_sheet: "WEEK{n-1}_{year}" }
│
├── Get line items from Sheet (Google Sheets)
│   └── reads all rows from target tab
│
├── Weekly Sheet Quality Audit (Code — pure JS)
│   └── output: { status, summary, flagged rows per category }
│
├── Audit Report Email Generator (LLM Chain)
│   ├── Primary  : Grok 4 Fast (OpenRouter)
│   └── Fallback : Claude Haiku 4.5 (auto-activates on failure)
│
└── Send audit report (Gmail)
    └── on failure → Telegram fallback (disabled) → StopAndError
```

---

## Execution Flow

### 1. Compute Previous Week Sheet Name (Code)

Computes the target tab name using ISO 8601 (now − 7 days, UTC).

```
Output: { current_week_sheet: "WEEK16_2026" }
```

> **Warning:** Uses ISO week year, not calendar year.  
> Week 1 of 2027 can start in late December 2026 — this is correct.  
> Running manually mid-week targets the previous week, not the current one.

### 2. Get line items from Sheet (Google Sheets)

Reads all rows from the dynamically resolved tab in `ShopifyPaidOrders_Spreadsheet`.

- Sheet name sourced from step 1 output (`$json.current_week_sheet`)
- Retry: 2 attempts, 5s apart

> **Warning:** If the tab does not exist, this node errors — it does not create it.  
> Tab creation is handled exclusively by WF-01 Track A.  
> Root cause of a missing tab: WF-01 failed or never ran for that week.

### 3. Weekly Sheet Quality Audit (Code)

Core audit engine. Pure JS, zero external dependencies.

**Input:** all rows from the target weekly tab  
**Output:** single JSON object

```
{
  status:   "✅ ALL CLEAR" | "⚠️ ANOMALIES DETECTED",
  summary:  { check_name: flagged_count, ... },
  sheet_name, row_count, order_count,
  [per-category arrays of flagged rows]
}
```

#### 7 Audit Checks

| # | Check | Flag Condition |
|---|---|---|
| 1 | Duplicate `line_item_id` | Same ID appears more than once |
| 2 | Duplicate `order_id` | Full order written more than once |
| 3 | Financial consistency | `unit_price × qty ≠ total_line_price` (tolerance ±0.02) |
| 4 | Missing critical fields | Empty values in required columns |
| 5 | Customer consistency | Conflicting metadata within same `order_id` |
| 6 | Date out of window | `inserted_at` outside expected ISO week range |
| 7 | `is_custom_item` vs SKU | Custom flag inconsistent with SKU presence |

#### Tuneable Constants

| Constant | Default | Description |
|---|---|---|
| `PRICE_THRESHOLD` | `50000` | Flags `unit_price` above this value as financial anomaly. Adjust for high-ticket catalogues. |
| Price math tolerance | `±0.02` | Covers Shopify float rounding on line totals. Do not reduce — will produce false positives. |

> **Warning:** If anomaly arrays exceed ~100 rows, truncate before the LLM node to avoid token overflow (max_tokens: 6000).

### 4. Audit Report Email Generator (LLM Chain)

Sends the full audit JSON to LLM → returns raw inline-CSS HTML.

| Parameter | Value |
|---|---|
| Primary LLM | Grok 4 Fast (`x-ai/grok-4-fast`) via OpenRouter |
| Fallback LLM | Claude Haiku 4.5 (`anthropic/claude-haiku-4.5`) — `needsFallback: true` |
| Max tokens | 6000 (covers ~30 anomaly rows comfortably) |
| Temperature | 0.7 |
| Timeout | 360s |
| Content policy | Raw HTML only — no markdown, no backticks |

### 5. Send audit report (Gmail)

Sends the HTML report to `aliboussechill@gmail.com`.

**Subject format:**
```
✅ Audit WEEK16_2026 — ALL CLEAR (247 rows / 89 orders)
⚠️ Audit WEEK16_2026 — 3 anomalies (247 rows / 89 orders)
```

- Retry: 2 attempts, 5s apart
- Sender name: `Shopify Orders Manager`
- `onError: continueErrorOutput` → Telegram fallback → StopAndError

---

## Error Handling

| Layer | Mechanism |
|---|---|
| Global | Error workflow `gvhDaCea1oROHUrb` registered on this workflow |
| Gmail node | `onError: continueErrorOutput` → Telegram → StopAndError |

---

## Telegram Fallback (Disabled by Default)

Reached only when Gmail send fails.

**To enable:**
1. Set `chatId` to your real Telegram chat or group ID in the Telegram node
2. Adjust the message template if needed
3. Toggle the node ON

> **Warning:** `StopAndError` fires regardless of Telegram status — Gmail failures are always surfaced in execution logs.

---

## Dependencies

| Service | Credential | Purpose |
|---|---|---|
| Redis | Docker internal (`n8n_network`) | `shopify:sheet:name` — previous week tab resolution |
| Google Sheets | OAuth2 | `ShopifyPaidOrders_Spreadsheet` — source data |
| Gmail | OAuth2 | `aliboussechill@gmail.com` — report delivery |
| OpenRouter | API key | Grok 4 Fast / Claude Haiku 4.5 |
| Telegram | Bot token | Gmail failure fallback (disabled — requires real `chatId`) |

---

## Schedule

| Trigger | Cadence | Purpose |
|---|---|---|
| Schedule Trigger | Every Monday at 06:00 UTC | Production audit |
| Manual Trigger | On demand | Testing without waiting for weekly cadence |

---

## Relationship to Other Workflows

| Workflow | Relationship |
|---|---|
| WF-01 SOM Main | **Upstream dependency** — creates and populates the tabs this workflow audits |
| WF-03 Error Handler | **Downstream** — receives failures via error workflow registration |

---

## Changelog

```
1.0.0 — 2026-05 — Initial production release
  • 7-check pure JS audit engine (zero external dependencies)
  • LLM report generation with primary/fallback chain
  • Gmail delivery + Telegram fallback (disabled by default)
  • ISO 8601 previous-week targeting (UTC)
```

---

*Author: Ali Boussecsou — [ali-n8n.com](https://ali-n8n.com)*  
*Project: Shopify Order n8n Automation*
