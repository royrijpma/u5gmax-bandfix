#!/bin/bash
# reboot-modem.sh — scheduled one-time, daily, or weekly U5G-Max reboot
# Called by /etc/cron.d/u5gmax-reboot

set -euo pipefail
exec </dev/null

DATA_DIR="/data/u5gmax-bandfix"
CONFIG="$DATA_DIR/config"
LOG_FILE="$DATA_DIR/band-fix.log"
CRON_REBOOT="/etc/cron.d/u5gmax-reboot"
BAND_FIX="$DATA_DIR/band-fix.sh"
TMP_DIR="$DATA_DIR/tmp"
SSH_KEY="$DATA_DIR/id_ed25519"
KNOWN_HOSTS="$DATA_DIR/known_hosts"

log() {
    printf '[%s] reboot-modem: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

mkdir -p "$TMP_DIR"
chmod 700 "$TMP_DIR"
trap 'rm -f "$TMP_DIR"/reboot-* 2>/dev/null || true' EXIT

# --- Load config ---
[ -f "$CONFIG" ] || { log "ERROR: config not found at $CONFIG — aborting"; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG"
: "${SSH_USER:?CONFIG missing SSH_USER}"
: "${REBOOT_SCHEDULE:?CONFIG missing REBOOT_SCHEDULE}"

# --- One-time: self-delete cron entry + clean config ---
if [ "$REBOOT_SCHEDULE" = "once" ]; then
    rm -f "$CRON_REBOOT"
    grep -v '^REBOOT_' "$CONFIG" > "$TMP_DIR/reboot-config.tmp" && mv "$TMP_DIR/reboot-config.tmp" "$CONFIG"
    log "One-time schedule executed — cron entry removed"
else
    log "Recurring ($REBOOT_SCHEDULE) schedule — keeping cron entry"
fi

# --- Get modem IP ---
U5G_IP=""
[ -f "$DATA_DIR/last_ip.txt" ] && U5G_IP=$(tr -d '\r\n' < "$DATA_DIR/last_ip.txt")
[ -z "$U5G_IP" ] && { log "ERROR: no cached IP in last_ip.txt — aborting"; exit 1; }

SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS"

# --- SSH helper: bg+SIGKILL (20s), stdin from tempfile ---
# timeout/signals do not work in UCG Fiber cron — must use background+SIGKILL
_ssh_bg() {
    local _out="$1"; shift
    local _rc=0 _in="$TMP_DIR/reboot-ssh-stdin-$$"
    cat > "$_in"
    : > "$_out"
    ssh "$@" < "$_in" > "$_out" 2>/dev/null &
    local _pid=$!
    ( sleep 20 && kill -9 "$_pid" 2>/dev/null ) &
    local _kpid=$!
    { wait "$_pid" 2>/dev/null; } || _rc=$?
    kill "$_kpid" 2>/dev/null; wait "$_kpid" 2>/dev/null || true
    rm -f "$_in"
    return $_rc
}

# --- Send reboot command ---
log "Sending reboot command to U5G-Max at $U5G_IP..."
_rout="$TMP_DIR/reboot-out.txt"

# Try uiwwand-ctl {"method":"reboot"} first
printf '{"method":"reboot"}\n' | _ssh_bg "$_rout" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" || true
_resp=$(cat "$_rout" 2>/dev/null || echo "")

if printf '%s' "$_resp" | grep -q '"result"'; then
    log "Reboot command accepted via uiwwand-ctl"
else
    log "uiwwand-ctl reboot failed (response: ${_resp:-empty}) — trying SSH reboot..."
    printf '' | _ssh_bg "$_rout" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "reboot" || true
    log "SSH reboot command sent"
fi
rm -f "$_rout"

# --- Wait for modem shutdown (minimum boot time is 5 minutes) ---
log "Waiting 300s for modem to complete reboot cycle..."
sleep 300

# --- Poll SSH until modem is back online (max 600s additional = 15 min total) ---
log "Polling for U5G-Max to come back online (max 10 min)..."
_elapsed=0
_online=0
_chk="$TMP_DIR/reboot-chk.txt"

while [ "$_elapsed" -lt 600 ]; do
    printf '' | _ssh_bg "$_chk" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "exit 0" && _online=1 || _online=0
    rm -f "$_chk"

    if [ "$_online" -eq 1 ]; then
        log "U5G-Max is back online after $((300 + _elapsed))s"
        break
    fi

    log "Not yet online — retrying in 15s (${_elapsed}s into poll phase)..."
    sleep 15
    _elapsed=$((_elapsed + 15))
done

if [ "$_online" -eq 0 ]; then
    log "WARNING: U5G-Max did not come back online within 15 min — band-fix will run at next hourly cron (:05)"
    exit 0
fi

# --- Run band-fix after reboot ---
log "Running post-reboot band-fix..."
[ -f "$BAND_FIX" ] || { log "ERROR: band-fix.sh not found at $BAND_FIX"; exit 1; }
bash "$BAND_FIX" >> "$LOG_FILE" 2>&1 || true
log "Post-reboot band-fix complete"
