# Security

This document covers the security measures implemented on the production stack.
It serves as both a reference for operators and a transparency document for auditors.

---

## Network Layer

### Firewall (UFW)

Default policy: deny all inbound, allow all outbound.
Only three ports are open:

| Port | Protocol | Service |
|---|---|---|
| 22 | TCP | SSH |
| 80 | TCP | HTTP → redirected to HTTPS by Caddy |
| 443 | TCP | HTTPS |

n8n runs internally on port `5678` and is never exposed directly — all traffic goes through Caddy.

### TLS / SSL

Managed by Caddy with automatic certificate provisioning via Let's Encrypt / ZeroSSL.
Certificates auto-renew before expiry — no manual intervention required.

HTTP security headers enforced on all responses:

| Header | Value |
|---|---|
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` |
| `X-Frame-Options` | `SAMEORIGIN` |
| `X-Content-Type-Options` | `nosniff` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=()` |
| `Server` | Removed (`-Server` directive) — no version disclosure |

---

## SSH

| Setting | Value |
|---|---|
| Authentication | Public key only |
| Password authentication | Disabled (`PasswordAuthentication no`) |
| Root login | Key only (`PermitRootLogin prohibit-password`) |
| Authorized keys | 2 keys registered |

### Brute-force protection (Fail2Ban)

Fail2Ban monitors SSH login attempts and bans offending IPs automatically.

| Parameter | Value |
|---|---|
| Jail | `sshd` — active |
| Max retries | Default (5 attempts) |
| Ban duration | Default (10 minutes, escalating) |

---

## Docker

### Network isolation

All containers communicate over a dedicated bridge network (`n8n_network`).
No container ports are bound to `0.0.0.0` except through Caddy (80/443).

| Container | Internal port | External exposure |
|---|---|---|
| `n8n-container` | 5678 | Via Caddy only |
| `redis-container` | 6379 | None — internal network only |
| `caddy-proxy` | 80, 443 | Public |

### Redis authentication

Redis requires password authentication (`requirepass` via `.env`).
The password is never hardcoded — injected at runtime from the `.env` file.

Redis is not reachable from outside the Docker network.

### n8n resource limits

```yaml
deploy:
  resources:
    limits:
      memory: 4g
    reservations:
      memory: 256m
```

Prevents runaway memory consumption from affecting other services.

### Log rotation

All containers use `json-file` logging with rotation:

```yaml
logging:
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "3"
```

Maximum log footprint per container: 30 MB.

---

## Secrets Management

All secrets are stored in a `.env` file at `~/n8n-automation/.env`.

| Secret | Storage | Exposure |
|---|---|---|
| `N8N_ENCRYPTION_KEY` | `.env` | Never logged, never committed |
| `N8N_LICENSE_ACTIVATION_KEY` | `.env` | Never logged, never committed |
| `REDIS_PASSWORD` | `.env` | Never logged, never committed |
| OAuth2 credentials | n8n encrypted database | Encrypted at rest via `N8N_ENCRYPTION_KEY` |
| API keys (OpenRouter, Hostinger) | n8n encrypted database | Encrypted at rest |

`.env` is listed in `.gitignore` — it is never committed to the repository.
The repository contains only `.env.example` with empty values.

n8n credential storage is encrypted using AES-256 with the `N8N_ENCRYPTION_KEY`.

---

## File System Access

n8n's file system access is restricted via:

```env
N8N_RESTRICT_FILE_ACCESS_TO=/data/metrics
```

n8n can only read from `/data/metrics` — the directory mounted read-only from `/home/adlin/metrics` on the host. It cannot access any other path on the host file system.

---

## Malware Scanning (Monarx)

Monarx agent runs continuously on the host and scans for malware and suspicious activity.
Scan results are collected daily by `vps_metrics.sh` and evaluated by WF-04:

- `malicious > 0` → immediate alert (Gmail + Telegram)

---

## Automatic Security Updates

`unattended-upgrades` is configured and active.
Security patches are applied automatically without manual intervention.
Non-security updates remain manual to avoid uncontrolled regressions.

---

## Backups

| Parameter | Value |
|---|---|
| Frequency | Daily at 02:00 UTC |
| Target | `~/n8n-automation/n8n_data/` |
| Format | `tar.gz` — `n8n_backup_YYYYMMDD.tar.gz` |
| Retention | 7 days (older files deleted automatically) |
| Storage | Local only — `~/backups/` |

> **Known limitation:** Backups are stored on the same disk as the data.
> A full disk failure would result in data and backup loss simultaneously.
> Off-site backup (e.g. rclone → Google Drive or S3) is planned for v2.

### Pre-update backup

`update-n8n.sh` creates an additional timestamped backup before every n8n update.
If the backup fails, the update is aborted — the production instance is never touched without a safety net.

---

## Credential Rotation

| Credential | Recommended rotation | Notes |
|---|---|---|
| `N8N_ENCRYPTION_KEY` | On compromise only | Changing requires re-entering all credentials in n8n |
| `REDIS_PASSWORD` | Annually or on compromise | Update `.env` + restart stack |
| OAuth2 tokens | Managed by Google/Shopify | Auto-refreshed by n8n |
| OpenRouter API key | On compromise | Revoke and reissue from OpenRouter dashboard |
| Hostinger API key | Annually or on compromise | Revoke and reissue from Hostinger panel |
| SSH keys | On compromise or team change | Remove old key from `authorized_keys` |

---

## Known Limitations & Planned Improvements

| Limitation | Impact | Planned fix |
|---|---|---|
| Local backups only | Full loss on disk failure | Off-site backup via rclone (v2) |
| SQLite database | Performance degradation at scale | Migration to PostgreSQL (v2) |
| Telegram alerts disabled | Delayed alert delivery on Gmail failure | Enable after confirming chat ID |
| No intrusion detection beyond Fail2Ban | Limited visibility on non-SSH attacks | Evaluate auditd or OSSEC (v2) |

---

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it privately:

**Email:** aliboussechill@gmail.com  
**Subject:** `[SECURITY] shopify-order-n8n-automation`

Do not open a public GitHub issue for security vulnerabilities.

---

*Author: Ali Boussecsou — [ali-n8n.com](https://ali-n8n.com)*  
*Project: Shopify Order n8n Automation*
