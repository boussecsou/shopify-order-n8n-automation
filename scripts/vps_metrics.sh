#!/bin/bash
# ============================================================
# vps_metrics.sh — VPS system metrics collector
# Author : Ali Boussecsou — ali-n8n.com
# Cron   : 0 7 * * * (daily at 07:00)
# Output : /home/adlin/metrics/vps_metrics.json
# ============================================================

OUTPUT="/home/adlin/metrics/vps_metrics.json"
UPDATE_LOG="/root/logs/n8n-update.log"

# ── DISK ─────────────────────────────────────────────────
# df -h returns human-readable disk usage
# Filtered on "/" — main partition
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')   # e.g. "15G"
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')  # e.g. "96G"
DISK_PCT=$(df / | awk 'NR==2 {print $5}')        # e.g. "16%"

# ── RAM ──────────────────────────────────────────────────
# free -m returns RAM in megabytes
RAM_USED=$(free -m | awk 'NR==2 {print $3}')     # e.g. 1024
RAM_TOTAL=$(free -m | awk 'NR==2 {print $2}')    # e.g. 7985

# ── UPTIME ───────────────────────────────────────────────
# uptime -p returns human-readable format: "up 13 days, 2 hours"
UPTIME=$(uptime -p)

# ── KERNEL ───────────────────────────────────────────────
# uname -r returns the exact running kernel version
KERNEL=$(uname -r)

# ── PENDING UPDATES ──────────────────────────────────────
# Count packages with available updates
UPDATES_PENDING=$(apt list --upgradable 2>/dev/null | grep -c upgradable)

# ── REBOOT REQUIRED ──────────────────────────────────────
# Ubuntu creates this file when a reboot is needed after a kernel update
REBOOT_REQUIRED="false"
[ -f /var/run/reboot-required ] && REBOOT_REQUIRED="true"

# ── DOCKER CONTAINERS ────────────────────────────────────
# Retrieve name, status and image for each container
CONTAINERS=$(docker ps -a --format '{"name":"{{.Names}}","status":"{{.Status}}","image":"{{.Image}}"}' \
  | paste -sd, | sed 's/^/[/' | sed 's/$/]/')

# ── LAST BACKUP ──────────────────────────────────────────
# Find the most recent backup archive in ~/backups/
LAST_BACKUP=$(ls -t /root/backups/*.tar.gz 2>/dev/null | head -1)
if [ -z "$LAST_BACKUP" ]; then
  BACKUP_STATUS="no backup found"
  BACKUP_DATE="N/A"
else
  BACKUP_STATUS="ok"
  # stat -c %y returns the file last modification date
  BACKUP_DATE=$(stat -c %y "$LAST_BACKUP" | cut -d'.' -f1)
fi

# ── FAIL2BAN ─────────────────────────────────────────────
# Check that fail2ban service is active
FAIL2BAN=$(systemctl is-active fail2ban)

# ── N8N UPDATE INFO ──────────────────────────────────────
# Read n8n version directly from Docker — more reliable than parsing logs
# Log lines follow this format:
#   "[20260420_030012] ✅ n8n updated: 2.15.1 → 2.17.6"
#   "[20260420_030012] ✅ n8n already up to date (version 2.17.6)"
#   "[20260420_030012] ❌ ERROR — container not started"

N8N_VERSION=$(docker exec n8n-container n8n --version 2>/dev/null || echo "unknown")

if [ -f "$UPDATE_LOG" ]; then
  # Find the last line containing a final result (✅ or ❌)
  LAST_UPDATE_LINE=$(grep -E "✅|❌" "$UPDATE_LOG" | tail -1)

  if [ -n "$LAST_UPDATE_LINE" ]; then
    # Extract date from [YYYYMMDD_HHMMSS] format
    LAST_UPDATE_RAW=$(echo "$LAST_UPDATE_LINE" | grep -oP '\[\K[^\]]+' | head -1)

    # Reformat to readable date: YYYYMMDD_HHMMSS → YYYY-MM-DD HH:MM:SS
    LAST_UPDATE_DATE=$(echo "$LAST_UPDATE_RAW" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')

    # Determine status from emoji
    if echo "$LAST_UPDATE_LINE" | grep -q "✅"; then
      UPDATE_STATUS="ok"
    else
      UPDATE_STATUS="failed"
    fi

    # Extract message — escape quotes to avoid breaking JSON
    UPDATE_MESSAGE=$(echo "$LAST_UPDATE_LINE" \
      | sed 's/\[[^]]*\] //' \
      | sed 's/"/\\"/g' \
      | tr -d '\n')
  else
    # Log file exists but no result line found
    LAST_UPDATE_DATE="N/A"
    UPDATE_STATUS="unknown"
    UPDATE_MESSAGE="Log present but no result found"
  fi
else
  # Log file does not exist — update-n8n.sh has never run
  LAST_UPDATE_DATE="N/A"
  UPDATE_STATUS="never run"
  UPDATE_MESSAGE="update-n8n.sh has not run yet"
fi

# ── TIMESTAMP ────────────────────────────────────────────
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# ── JSON OUTPUT ──────────────────────────────────────────
# Numeric values (RAM, updates) are unquoted to remain valid JSON numbers.
# All other values are strings.
cat > "$OUTPUT" << EOF
{
  "generated_at": "$TIMESTAMP",
  "system": {
    "kernel": "$KERNEL",
    "uptime": "$UPTIME",
    "updates_pending": $UPDATES_PENDING,
    "reboot_required": $REBOOT_REQUIRED
  },
  "resources": {
    "disk_used": "$DISK_USED",
    "disk_total": "$DISK_TOTAL",
    "disk_percent": "$DISK_PCT",
    "ram_used_mb": $RAM_USED,
    "ram_total_mb": $RAM_TOTAL
  },
  "containers": $CONTAINERS,
  "backup": {
    "status": "$BACKUP_STATUS",
    "last_backup": "$BACKUP_DATE"
  },
  "services": {
    "fail2ban": "$FAIL2BAN"
  },
  "n8n": {
    "version": "$N8N_VERSION",
    "last_update_date": "$LAST_UPDATE_DATE",
    "last_update_status": "$UPDATE_STATUS",
    "last_update_message": "$UPDATE_MESSAGE"
  }
}
EOF

echo "[$TIMESTAMP] Metrics written to $OUTPUT"
