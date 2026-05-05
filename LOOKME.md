<img width="1707" height="507" alt="LOOKME_HelloBanner" src="https://github.com/user-attachments/assets/b104dfeb-da63-4e16-940f-41198177a6a0" />

# System Architecture & Engineering Showcase

**Shopify Order n8n Automation** — a production-grade, self-hosted automation pipeline
built on n8n, Redis, Docker, and Caddy. Designed as a publishable technical reference.

---

## 📄 Download the Showcase

> A 10-page visual document covering the full system architecture, all 4 workflows
> with annotated canvas screenshots, engineering decisions, security posture,
> skills matrix, and v2 roadmap.

### [⬇️ Download LOOKME.pdf](./docs/LOOKME.pdf)

---

## What's inside the PDF

| Page | Content |
|---|---|
| 1 | Cover — project identity |
| 2 | Architecture tiers — Hardware → Network → Runtime → App → APIs |
| 3 | Security & resilience — UFW, SSH, Caddy headers, Docker isolation, cron ops |
| 4 | WF-01 Track A — sheet week management, Redis state, ISO 8601 rotation |
| 5 | WF-01 Track B — sinceId cursor, order parser, SplitInBatches loop, AI report |
| 6 | Engineering decisions — polling vs webhooks, sinceId, Redis, AI segregation |
| 7 | WF-02 — 7-check JS audit engine, LLM formatting protocol |
| 8 | WF-03 — centralized error handler, hub-and-spoke fan-out pattern |
| 9 | WF-04 — VPS health audit (8 thresholds) + bi-hourly credit watch |
| 10 | Skills matrix + v2 evolution roadmap |

---

## Quick links

- 📘 [README](./README.md) — full project documentation
- 🗂️ [docs/](./docs/) — workflow docs, deployment guide, security reference
- ⚙️ [workflows/](./workflows/) — all 4 n8n workflow JSON exports
- 🔧 [infrastructure/](./infrastructure/) — docker-compose, Caddyfile, .env.example
- 📜 [scripts/](./scripts/) — vps_metrics.sh, update-n8n.sh

---

*Author: Ali Boussecsou — [ali-n8n.com](https://ali-n8n.com) · [@boussecsou](https://github.com/boussecsou)*
