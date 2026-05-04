#!/bin/bash
# ============================================================
# update-n8n.sh — Automatic n8n update (production-grade)
# Author  : Ali Boussecsou — ali-n8n.com
# Cron    : 30 3 * * 0 (every Sunday at 03:30)
# ============================================================

# ── CONFIG ───────────────────────────────────────────────
N8N_DIR="$HOME/n8n-automation"
BACKUP_DIR="$HOME/backups"
LOG_FILE="$HOME/logs/n8n-update.log"
EMAIL="aliboussechill@gmail.com"
DATE=$(date +%Y%m%d_%H%M%S)

# ── INIT ─────────────────────────────────────────────────
mkdir -p "$BACKUP_DIR" "$HOME/logs"

# Redirect stdout and stderr to log file
exec >> "$LOG_FILE" 2>&1

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[$DATE] Starting n8n update"

# ── CURRENT VERSION ──────────────────────────────────────
# Capture version before update for comparison after
CURRENT=$(docker exec n8n-container n8n --version 2>/dev/null)
echo "Current version: ${CURRENT:-unknown}"

# ── BACKUP ───────────────────────────────────────────────
# Back up n8n_data BEFORE touching anything.
# If the backup fails, the script stops immediately —
# the production instance is never updated without a safety net.
echo "Running backup..."
tar -czf "$BACKUP_DIR/n8n_backup_$DATE.tar.gz" -C "$N8N_DIR" n8n_data/ \
  && echo "Backup OK: n8n_backup_$DATE.tar.gz" \
  || {
    echo "ERROR: backup failed — aborting update."
    echo "❌ n8n backup failed — update aborted. Check: $LOG_FILE" \
      | mail -s "⚠️ n8n Update ABORTED — ali-n8n.com" "$EMAIL" 2>/dev/null
    exit 1
  }

# Rotation: keep only the 7 most recent backups
ls -t "$BACKUP_DIR"/n8n_backup_*.tar.gz | tail -n +8 | xargs -r rm
echo "Backup rotation OK (7 most recent kept)"

# ── PULL NEW IMAGE ───────────────────────────────────────
cd "$N8N_DIR" || { echo "ERROR: directory $N8N_DIR not found"; exit 1; }

echo "Pulling new Docker image..."
docker compose pull

# ── RESTART N8N ONLY ─────────────────────────────────────
# --no-deps ensures ONLY n8n is restarted.
# Caddy and Redis remain running — no reverse proxy interruption
# and no risk to Redis state during an active workflow run.
echo "Restarting n8n service (Caddy and Redis untouched)..."
docker compose up -d --no-deps n8n

# ── WAIT FOR REAL STARTUP ────────────────────────────────
# A fixed sleep is too fragile — n8n loads custom nodes and
# can take longer than expected. Loop until n8n responds to
# --version, with a 60-second timeout (12 × 5s).
echo "Waiting for n8n to start..."
NEW=""
STATUS=""
for i in $(seq 1 12); do
  sleep 5
  STATUS=$(docker inspect -f '{{.State.Status}}' n8n-container 2>/dev/null)
  NEW=$(docker exec n8n-container n8n --version 2>/dev/null)

  # As soon as n8n responds to --version, it is truly ready
  if [ -n "$NEW" ]; then
    echo "n8n ready after $((i * 5)) seconds."
    break
  fi

  echo "Waiting... $((i * 5))s / 60s (status: ${STATUS:-unknown})"
done

# ── FINAL CHECK ──────────────────────────────────────────
echo "Version after update : ${NEW:-not detected}"
echo "Container status     : ${STATUS:-unknown}"

if [ "$STATUS" = "running" ] && [ -n "$NEW" ]; then
  # Success — log and notify
  if [ "$NEW" = "$CURRENT" ]; then
    MSG="✅ n8n already up to date (version $NEW) — no change."
  else
    MSG="✅ n8n successfully updated: $CURRENT → $NEW"
  fi
  echo "[$DATE] $MSG"
  echo "$MSG" | mail -s "n8n Update OK — ali-n8n.com" "$EMAIL" 2>/dev/null

else
  # Failure — log and send urgent alert
  echo "[$DATE] ❌ ERROR — container not started or n8n not responding."
  echo "❌ n8n update failed — container: ${STATUS:-unknown}. Check: $LOG_FILE" \
    | mail -s "⚠️ n8n Update FAILED — ali-n8n.com" "$EMAIL" 2>/dev/null
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
