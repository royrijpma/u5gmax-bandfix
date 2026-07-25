#!/bin/bash
# on-boot.sh — u5gmax-bandfix boot-time band enforcement
# Called via @reboot cron entry — not via on_boot.d (not available on UCG Fiber)
# Waits for U5G-Max to appear in MongoDB, then runs immediate band fix.

set -euo pipefail
exec </dev/null

SCRIPT_DEST="/data/u5gmax-bandfix/band-fix.sh"
CRON_FILE="/etc/cron.d/u5gmax-bandfix"
LOG_FILE="/data/u5gmax-bandfix/band-fix.log"
TMP_DIR="/data/u5gmax-bandfix/tmp"

log() {
    printf '[%s] on-boot: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

[ -f "$SCRIPT_DEST" ] || { log "band-fix.sh not found — skipping"; exit 0; }

mkdir -p "$TMP_DIR"
chmod 700 "$TMP_DIR"
trap 'rm -f "$TMP_DIR/on-boot-ip.txt"' EXIT

# Restore cron job if wiped by a firmware update
if [ ! -f "$CRON_FILE" ]; then
    log "Cron job missing — restoring..."
    cat > "$CRON_FILE" << 'EOF'
# u5gmax-bandfix: Odido NL band enforcement for U5G-Max
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
@reboot root /data/u5gmax-bandfix/on-boot.sh >> /data/u5gmax-bandfix/band-fix.log 2>&1
5 * * * * root /data/u5gmax-bandfix/band-fix.sh >> /data/u5gmax-bandfix/band-fix.log 2>&1
EOF
    chmod 644 "$CRON_FILE"
    log "Cron job restored"
fi

# Restore scheduled reboot cron entry if wiped by a firmware update
REBOOT_CRON_FILE="/etc/cron.d/u5gmax-reboot"
CONFIG_FILE="/data/u5gmax-bandfix/config"
if [ ! -f "$REBOOT_CRON_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    _rtime="" _rsched="" _rdays=""
    # shellcheck source=/dev/null
    . "$CONFIG_FILE" 2>/dev/null || true
    _rtime="${REBOOT_TIME:-}"
    _rsched="${REBOOT_SCHEDULE:-}"
    _rdays="${REBOOT_DAYS:-}"
    if [ -n "$_rtime" ] && [ -n "$_rsched" ]; then
        _h=$(printf '%s' "$_rtime" | cut -d: -f1)
        _m=$(printf '%s' "$_rtime" | cut -d: -f2)
        if [ "$_rsched" = "daily" ]; then
            printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n%s %s * * * root /data/u5gmax-bandfix/reboot-modem.sh >> /data/u5gmax-bandfix/band-fix.log 2>&1\n' \
                "$_m" "$_h" > "$REBOOT_CRON_FILE"
            chmod 644 "$REBOOT_CRON_FILE"
            log "Reboot schedule restored: daily $_rtime (UTC)"
        elif [ "$_rsched" = "weekly" ] && [ -n "$_rdays" ]; then
            printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n%s %s * * %s root /data/u5gmax-bandfix/reboot-modem.sh >> /data/u5gmax-bandfix/band-fix.log 2>&1\n' \
                "$_m" "$_h" "$_rdays" > "$REBOOT_CRON_FILE"
            chmod 644 "$REBOOT_CRON_FILE"
            log "Reboot schedule restored: weekly ($_rdays) $_rtime (UTC)"
        fi
        # one-time schedules are not restored on boot — the scheduled time has likely passed
    fi
fi

# Restore CLI command if wiped by a firmware update
CLI_DEST="/usr/local/sbin/u5gmax-bandfix"
CLI_SRC="/data/u5gmax-bandfix/u5gmax-bandfix.sh"
if [ ! -f "$CLI_DEST" ]; then
    log "CLI command missing — restoring..."
    if [ -f "$CLI_SRC" ]; then
        cp "$CLI_SRC" "$CLI_DEST"
        chmod +x "$CLI_DEST"
        log "CLI restored from $CLI_SRC"
    elif command -v curl >/dev/null 2>&1; then
        curl -sSL "https://raw.githubusercontent.com/royrijpma/u5gmax-bandfix/main/u5gmax-bandfix.sh" \
            -o "$CLI_DEST" 2>/dev/null && chmod +x "$CLI_DEST" && \
            log "CLI restored from GitHub" || log "CLI restore from GitHub failed"
    else
        log "CLI restore failed — no local copy and no curl"
    fi
fi

# Poll MongoDB until U5G-Max appears (max 10 min — modem may boot slower than gateway)
# Uses tempfile instead of pipeline: mongo 3.6 hangs in pipelines without a TTY even
# with < /dev/null, because it keeps its stdout-end of the pipe open indefinitely.
log "Waiting for U5G-Max to appear in MongoDB..."
_ip_out="$TMP_DIR/on-boot-ip.txt"
i=1
while [ $i -le 20 ]; do
    : > "$_ip_out"
    mongo --quiet localhost:27117/ace \
        --eval 'var d=db.device.findOne({model:"UMBBE630"}); print(d ? d.ip : "null")' \
        < /dev/null > "$_ip_out" 2>/dev/null &
    _mongo_pid=$!
    ( sleep 30 && kill -9 "$_mongo_pid" 2>/dev/null ) &
    _kpid=$!
    wait "$_mongo_pid" 2>/dev/null || true
    kill "$_kpid" 2>/dev/null; wait "$_kpid" 2>/dev/null || true
    IP=$(tr -d '\r\n' < "$_ip_out")
    if [ -n "$IP" ] && [ "$IP" != "null" ] && printf '%s' "$IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        log "U5G-Max online at $IP — running band-fix..."
        "$SCRIPT_DEST" >> "$LOG_FILE" 2>&1 && \
            log "Boot fix applied successfully" || \
            log "band-fix exited with error (will retry via hourly cron)"
        exit 0
    fi
    log "Not ready yet (attempt $i/20) — waiting 30s..."
    sleep 30
    i=$((i+1))
done

log "U5G-Max did not appear within 10 minutes — band-fix will run via hourly cron"
