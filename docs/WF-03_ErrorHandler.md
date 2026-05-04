# WF-03 — Centralized Error Handler

> **Status:** `stable — production` · **Version:** `1.0.0` · **n8n:** `2.15.1`  
> **Workflow ID:** `gvhDaCea1oROHUrb`

## Overview

Single entry point for all workflow failures across the n8n instance.
Any registered workflow that errors automatically routes its failure payload here —
no per-workflow error handling logic needed.

### Key Design Decisions

| Decision | Rationale |
|---|---|
| Single centralized handler | One place to update alert logic, one place to monitor |
| No AI in error handling | Deterministic code only — errors must be reported reliably |
| Fan-out to Gmail + Telegram | Gmail is primary; Telegram adds real-time mobile reach when enabled |
| Flat payload normalization | Raw n8n error objects are nested — normalizing makes alerts readable |

---

## Architecture

```
[Any registered workflow fails]
        │
        ▼
Error Trigger (receives raw n8n error payload)
        │
        ▼
Format Data (Set node — normalize payload)
        │
        ├──▶ Send Gmail Alert   (always active)
        │
        └──▶ Send Telegram Alert (currently DISABLED)
```

---

## Execution Flow

### 1. Error Trigger

Receives the raw n8n error payload from any registered workflow.
Fires automatically — no manual intervention required.

### 2. Format Data (Set Node)

Normalizes the raw nested error payload into a clean flat structure.

| Output field | Source | Notes |
|---|---|---|
| `wf_name` | `workflow.name` | Fallback: `'Workflow Inconnu'` |
| `error_msg` | `execution.error.message` | Fallback: `'Aucun message d'erreur détaillé.'` |
| `node_name` | `execution.lastNodeExecuted` | Fallback: `'N/A'` |
| `exec_url` | `execution.url` | Direct link to failed execution |
| `timestamp` | `$now` | Formatted `Europe/Paris` — `dd/MM/yyyy HH:mm:ss` |

### 3. Fan-out (Parallel)

Both alert nodes receive the same normalized payload simultaneously.

**Send Gmail Alert** — always active  
- Recipient: `aliboussechill@gmail.com`  
- Subject: `❌ Workflow Failure : {wf_name}`  
- Sender name: `n8n Monitor`  
- Body: `wf_name` / `node_name` / `timestamp` / `error_msg` (monospace block) / `VIEW EXECUTION` button

**Send Telegram Alert** — currently **DISABLED**  
- Format: Markdown message
- Includes: workflow name, error message, node name, execution link, timestamp

---

## Registered Workflows

| Workflow | ID | Registered |
|---|---|---|
| WF-01 — Shopify Order Manager | `WF-01_SOM_Main` | ✅ |
| WF-02 — Weekly Sheet Quality Controller | `WF-02_GoogleSheet_WeeklyControler` | ✅ |
| WF-04 — VPS & AI Monitoring | `WF-04_VPS_AI_Monitoring_Reporting` | ✅ |

> **Warning:** Any new workflow added to the instance must register `gvhDaCea1oROHUrb`
> as its error workflow. Without this, failures are silent.  
> In n8n: Workflow Settings → Error Workflow → select `wf-03-error-handler`.

---

## Telegram Setup (When Ready)

1. Open the `Send Telegram Alert` node
2. Replace `{votre_id_telegram}` with your real Telegram chat or group ID
3. Toggle the node **ON**

> The Telegram credential (`Artificial Telegram Credential`) must be properly
> configured in n8n credentials before enabling.

---

## Dependencies

| Service | Credential | Purpose |
|---|---|---|
| Gmail | OAuth2 `Gmail Credential #1` | `aliboussechill@gmail.com` — primary alert delivery |
| Telegram | Bot token `Artificial Telegram Credential` | Real-time alert (disabled — requires real `chatId`) |

---

## Relationship to Other Workflows

| Workflow | Relationship |
|---|---|
| WF-01 SOM Main | **Upstream** — registered as error workflow consumer |
| WF-02 Weekly Controller | **Upstream** — registered as error workflow consumer |
| WF-04 VPS Monitoring | **Upstream** — registered as error workflow consumer |

---

## Changelog

```
1.0.0 — 2026-05 — Initial production release
  • Centralized error handler for all instance workflows
  • Payload normalization (wf_name, error_msg, node_name, exec_url, timestamp)
  • Gmail alert always active
  • Telegram alert disabled by default — requires real chatId
```

---

*Author: Ali Boussecsou — [ali-n8n.com](https://ali-n8n.com)*  
*Project: Shopify Order n8n Automation*
