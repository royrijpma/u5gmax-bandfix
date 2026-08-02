#!/bin/bash
# u5gmax-bandfix: Enforce ISP band restrictions on U5G-Max from Cloud Gateway
# Band configuration and ISP profile are loaded from config (set by install.sh or CLI)

set -euo pipefail
exec </dev/null

DATA_DIR="/data/u5gmax-bandfix"
TMP_DIR="$DATA_DIR/tmp"
LOG_FILE="$DATA_DIR/band-fix.log"
CONFIG="$DATA_DIR/config"
SSH_KEY="$DATA_DIR/id_ed25519"
KNOWN_HOSTS="$DATA_DIR/known_hosts"
LAST_IP_FILE="$DATA_DIR/last_ip.txt"

# Max log size before rotation (bytes)
LOG_MAX_BYTES=524288  # 512 KB

# Strip non-printable characters
strip_nonprintable() {
    printf '%s' "$1" | tr -cd '[:print:]'
}

log() {
    local msg line
    msg=$(strip_nonprintable "$*")
    line="$(printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg")"
    printf '%s\n' "$line" >> "$LOG_FILE"
    [ -t 1 ] && printf '%s\n' "$line" || true
}

die() {
    log "ERROR: $*"
    exit 1
}

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
        tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "Log rotated (kept last 500 lines)"
    fi
}

validate_ip() {
    local ip="$1"
    ip=$(strip_nonprintable "$ip")
    if ! printf '%s' "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        die "Invalid IP address from MongoDB: '$ip' — possible injection attempt"
    fi
}

validate_ssh_user() {
    local user="$1"
    if ! printf '%s' "$user" | grep -qE '^[a-zA-Z0-9_-]{1,32}$'; then
        die "Invalid SSH_USER in config: '$user' — must be 1-32 alphanumeric/underscore/dash chars"
    fi
}

# --- Helper: run mongo with guaranteed termination via background+SIGKILL ---
# `timeout` and SSH ConnectTimeout do not work in UCG Fiber cron: the cron
# environment does not propagate signals to child processes reliably.
# Background process + explicit kill -9 works in all environments.
_query_mongo_ip() {
    local _out="$TMP_DIR/mongo_ip.txt"
    local _rc=0
    : > "$_out"
    mongo --quiet localhost:27117/ace \
        --eval 'var d=db.device.findOne({model:/^UMBBE/}); print(d ? d.ip : "null")' \
        < /dev/null > "$_out" 2>/dev/null &
    local _pid=$!
    ( sleep 30 && kill -9 "$_pid" 2>/dev/null ) &
    local _kpid=$!
    { wait "$_pid" 2>/dev/null; } || _rc=$?
    kill "$_kpid" 2>/dev/null; wait "$_kpid" 2>/dev/null || true
    tr -d '\r\n' < "$_out"
    rm -f "$_out"
    return $_rc
}

# --- Helper: run SSH with guaranteed termination via background+SIGKILL (20s max) ---
# Usage: _ssh_bg <outfile> [ssh args...] (stdin from caller via redirect)
# Output captured to outfile; returns ssh exit code.
#
# IMPORTANT: bash redirects background process stdin to /dev/null when job
# control is disabled (cron, non-interactive). We save the caller's stdin to a
# tempfile BEFORE backgrounding, then pass it explicitly so ssh/uiwwand-ctl
# gets the JSON payload.
_ssh_bg() {
    local _out="$1"; shift
    local _rc=0 _in="$TMP_DIR/ssh_bg_stdin_$$"
    cat > "$_in"        # drain caller's stdin NOW (foreground — inherits caller's redirect)
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

# --- Helper: update known_hosts when IP changes ---
# ssh-keyscan uses SIGALRM internally for its -T timeout, which does not
# fire reliably in the UCG Fiber cron container namespace — wrap it in the
# same background+SIGKILL pattern used for mongo and ssh.
_update_known_hosts() {
    local _old="$1" _new="$2" _rc=0
    log "IP changed ($_old → $_new) — updating known_hosts..."
    if [ -f "$KNOWN_HOSTS" ] && [ -n "$_old" ]; then
        ssh-keygen -R "$_old" -f "$KNOWN_HOSTS" 2>/dev/null || true
    fi
    : > "$TMP_DIR/known_hosts.tmp"
    ssh-keyscan -T 10 "$_new" > "$TMP_DIR/known_hosts.tmp" 2>/dev/null &
    local _kspid=$!
    ( sleep 15 && kill -9 "$_kspid" 2>/dev/null ) &
    local _kkpid=$!
    { wait "$_kspid" 2>/dev/null; } || _rc=$?
    kill "$_kkpid" 2>/dev/null; wait "$_kkpid" 2>/dev/null || true
    if [ $_rc -ne 0 ] || [ ! -s "$TMP_DIR/known_hosts.tmp" ]; then
        rm -f "$TMP_DIR/known_hosts.tmp"
        die "Could not scan SSH host key for $_new (timeout or no keys returned)"
    fi
    mv "$TMP_DIR/known_hosts.tmp" "$KNOWN_HOSTS"
    printf '%s\n' "$_new" > "$LAST_IP_FILE"
}

# --- Helper: reinstall SSH key using controller credentials (self-heal after modem reboot) ---
# Modem tmpfs is wiped on reboot: authorized_keys + host keys are lost.
# This reads the controller SSH password from MongoDB, rescans the host key,
# and runs ssh-copy-id — same as install.sh does on first install.
_reinstall_key() {
    local _ip="$1" _rc=0
    log "Attempting SSH key reinstall via controller credentials..."

    if ! command -v sshpass >/dev/null 2>&1; then
        log "sshpass not available — cannot self-heal (re-run install.sh)"
        return 1
    fi

    # Try cached password from config first (written by install.sh, no MongoDB needed)
    local _pass=""
    if [ -f "$CONFIG" ]; then
        _pass=$(. "$CONFIG" 2>/dev/null; printf '%s' "${SSH_PASS:-}")
    fi

    # Fall back to MongoDB if cache is missing or empty
    if [ -z "$_pass" ] || [ "$_pass" = "null" ]; then
        log "No cached SSH password in config — querying MongoDB..."
        local _pw_out="$TMP_DIR/reinstall_pw.txt"
        local _attempt _mpid _mkpid
        for _attempt in 1 2; do
            : > "$_pw_out"
            mongo --quiet localhost:27117/ace \
                --eval 'var d=db.setting.findOne({key:"mgmt"}); print(d ? d.x_ssh_password : "null")' \
                < /dev/null > "$_pw_out" 2>/dev/null &
            _mpid=$!
            ( sleep 30 && kill -9 "$_mpid" 2>/dev/null ) &
            _mkpid=$!
            { wait "$_mpid" 2>/dev/null; } || true
            kill "$_mkpid" 2>/dev/null; wait "$_mkpid" 2>/dev/null || true
            _pass=$(tr -d '\r\n' < "$_pw_out")
            rm -f "$_pw_out"
            [ -n "$_pass" ] && [ "$_pass" != "null" ] && break
            [ "$_attempt" -eq 1 ] && log "MongoDB password query returned empty — retrying in 10s..." && sleep 10
        done
    fi

    if [ -z "$_pass" ] || [ "$_pass" = "null" ]; then
        log "Could not retrieve controller SSH password — cannot self-heal (re-run install.sh)"
        return 1
    fi

    log "Rescanning host key for $_ip (modem reboot regenerates host keys on tmpfs)..."
    : > "$TMP_DIR/reinstall_kh.tmp"
    ssh-keyscan -T 10 "$_ip" > "$TMP_DIR/reinstall_kh.tmp" 2>/dev/null &
    local _kspid=$!
    ( sleep 15 && kill -9 "$_kspid" 2>/dev/null ) &
    local _kkpid=$!
    { wait "$_kspid" 2>/dev/null; } || true
    kill "$_kkpid" 2>/dev/null; wait "$_kkpid" 2>/dev/null || true

    if [ ! -s "$TMP_DIR/reinstall_kh.tmp" ]; then
        rm -f "$TMP_DIR/reinstall_kh.tmp"
        log "Host key scan failed — modem unreachable at $_ip"
        return 1
    fi
    mv "$TMP_DIR/reinstall_kh.tmp" "$KNOWN_HOSTS"
    log "Host key updated"

    local _pf="$TMP_DIR/reinstall_pf_$$"
    printf '%s' "$_pass" > "$_pf"
    chmod 600 "$_pf"

    _rc=0
    sshpass -f "$_pf" ssh-copy-id \
        -i "${SSH_KEY}.pub" \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o ConnectTimeout=10 \
        "${SSH_USER}@${_ip}" < /dev/null > /dev/null 2>/dev/null &
    local _scpid=$!
    ( sleep 30 && kill -9 "$_scpid" 2>/dev/null ) &
    local _sckpid=$!
    { wait "$_scpid" 2>/dev/null; } || _rc=$?
    kill "$_sckpid" 2>/dev/null; wait "$_sckpid" 2>/dev/null || true
    rm -f "$_pf"

    if [ $_rc -ne 0 ]; then
        log "ssh-copy-id failed (rc=$_rc) — wrong password or sshd configuration changed"
        return 1
    fi

    log "SSH key reinstalled on $_ip"
    return 0
}

# --- Log rotation ---
rotate_log

# --- Create temp directory ---
mkdir -p "$TMP_DIR"
chmod 700 "$TMP_DIR"

# --- Singleton guard (atomic via mkdir) ---
LOCK_DIR="$DATA_DIR/.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Another instance is running — exiting"
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null; rm -f "$TMP_DIR"/u5gmax-bandfix-* "$TMP_DIR"/mongo_ip.txt "$TMP_DIR"/ssh_*.txt "$TMP_DIR"/ssh_bg_stdin_* "$TMP_DIR"/known_hosts.tmp "$TMP_DIR"/reinstall_*' EXIT

# --- Load config ---
[ -f "$CONFIG" ] || die "Config not found: $CONFIG (run install.sh first)"
# shellcheck source=/dev/null
source "$CONFIG"
: "${SSH_USER:?CONFIG missing SSH_USER}"
validate_ssh_user "$SSH_USER"

# ISP profile — PROFILE is authoritative. Band lists for the *built-in* profiles
# are always derived here, never trusted from a persisted config value, so a
# version update propagates new band specs without requiring a manual "switch
# profile" round-trip. The "custom" profile is the one exception: by
# definition its band lists only exist in config (the user chose them), so
# they're read from config and strictly validated before use.
validate_band_list() {
    local label="$1" value="$2"
    printf '%s' "$value" | grep -qE '^[0-9]{1,3}(,[0-9]{1,3})*$' || \
        die "Invalid $label in config: '$value' — expected comma-separated band numbers, each 1-3 digits"
}

: "${PROFILE:=odido}"
case "$PROFILE" in
    freemobile)
        PROFILE_NAME="Free Mobile FR"
        MODEM_MODEL="UMBBE631"
        LTE_REQUIRED="1,3,7,8,28"
        NR5G_SA_REQUIRED="1,28,78"
        NR5G_NSA_REQUIRED="1,28,78"
        ;;
    custom)
        PROFILE_NAME="Custom"
        MODEM_MODEL="${MODEM_MODEL:-auto-detected}"
        : "${LTE_REQUIRED:?CONFIG missing LTE_REQUIRED for custom profile}"
        : "${NR5G_SA_REQUIRED:?CONFIG missing NR5G_SA_REQUIRED for custom profile}"
        : "${NR5G_NSA_REQUIRED:?CONFIG missing NR5G_NSA_REQUIRED for custom profile}"
        validate_band_list "LTE_REQUIRED" "$LTE_REQUIRED"
        validate_band_list "NR5G_SA_REQUIRED" "$NR5G_SA_REQUIRED"
        validate_band_list "NR5G_NSA_REQUIRED" "$NR5G_NSA_REQUIRED"
        ;;
    *)
        PROFILE="odido"
        PROFILE_NAME="Odido NL"
        MODEM_MODEL="UMBBE630"
        LTE_REQUIRED="1,3,7,32,38"
        NR5G_SA_REQUIRED="1,3,7,38,78"
        NR5G_NSA_REQUIRED="1,3,7,38,78"
        ;;
esac

# --- Get current U5G-Max IP (cache-first: skip mongo on normal cron runs) ---
LAST_IP=""
[ -f "$LAST_IP_FILE" ] && LAST_IP=$(tr -d '\r\n' < "$LAST_IP_FILE")

U5G_IP=""
if printf '%s' "$LAST_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' 2>/dev/null; then
    U5G_IP="$LAST_IP"
    log "U5G-Max IP (cached): $U5G_IP"
else
    log "No cached IP — querying MongoDB..."
    U5G_IP=$(_query_mongo_ip)
    log "MongoDB result: '$U5G_IP'"
    [ -z "$U5G_IP" ] && die "MongoDB unavailable and no cached IP"
    [ "$U5G_IP" = "null" ] && die "U5G-Max (UMBBE*) not found in MongoDB — is the modem adopted?"
    validate_ip "$U5G_IP"
    _update_known_hosts "" "$U5G_IP"
fi

SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS"

# --- SSH connectivity check (if cached IP fails: poll MongoDB for new IP, then self-heal key) ---
log "Checking SSH connectivity..."
_chk="$TMP_DIR/ssh_chk.txt"
if ! _ssh_bg "$_chk" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "exit 0"; then
    log "SSH failed at $U5G_IP — polling MongoDB for updated IP (up to 5 attempts)..."
    _fresh="" _poll=1
    while [ "$_poll" -le 5 ]; do
        _fresh=$(_query_mongo_ip) || true
        if printf '%s' "$_fresh" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            break
        fi
        log "MongoDB IP query returned empty (attempt $_poll/5) — retrying in 15s..."
        sleep 15
        _poll=$((_poll + 1))
    done
    if printf '%s' "$_fresh" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' && \
            [ "$_fresh" != "$U5G_IP" ]; then
        _update_known_hosts "$U5G_IP" "$_fresh"
        U5G_IP="$_fresh"
    fi
    if ! _ssh_bg "$_chk" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "exit 0"; then
        if _reinstall_key "$U5G_IP"; then
            if ! _ssh_bg "$_chk" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "exit 0"; then
                log "WARNING: SSH to U5G-Max failed even after key reinstall — device offline or network issue"
                exit 0
            fi
        else
            log "WARNING: SSH to U5G-Max failed — device offline or unreachable"
            exit 0
        fi
    fi
else
    # SSH to cached IP succeeded — check if MongoDB has a newer IP and switch immediately
    if [ -n "$LAST_IP" ]; then
        _mongo_ip=$(_query_mongo_ip 2>/dev/null) || true
        if printf '%s' "$_mongo_ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' && \
                [ "$_mongo_ip" != "$U5G_IP" ]; then
            log "INFO: IP changed ($U5G_IP → $_mongo_ip) — switching to new IP now"
            if ( _update_known_hosts "$U5G_IP" "$_mongo_ip" ); then
                U5G_IP="$_mongo_ip"
                log "INFO: Now using $U5G_IP for remainder of this run"
            else
                log "WARNING: Could not scan host key for $_mongo_ip — continuing with $U5G_IP (still reachable)"
            fi
        fi
    fi
fi

# --- Fetch ICCID live from modem (not from static config — survives SIM swaps) ---
log "Reading ICCID from modem..."
_tmpfile="$TMP_DIR/u5gmax-bandfix-$(date +%s%N)-sim.json"
_ssh_out="$TMP_DIR/ssh_sim.txt"
printf '%s\n' '{"method":"get-sim-state"}' > "$_tmpfile"
_ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || true
_sim_out=$(cat "$_ssh_out")
rm -f "$_tmpfile" "$_ssh_out"
ICCID=$(printf '%s' "$_sim_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']['iccid'])" 2>/dev/null) || true

if [ -z "$ICCID" ]; then
    [ -n "${ICCID_CACHE:-}" ] && ICCID="$ICCID_CACHE" || \
        die "Could not read ICCID from modem and no cache available"
    log "WARNING: Using cached ICCID (modem may still be initializing)"
fi

ICCID=$(strip_nonprintable "$ICCID")
if ! printf '%s' "$ICCID" | grep -qE '^[0-9]{18,20}$'; then
    die "Invalid ICCID: '$ICCID'"
fi
log "ICCID: $ICCID"

if [ "${ICCID_CACHE:-}" != "$ICCID" ]; then
    if grep -q "^ICCID_CACHE=" "$CONFIG" 2>/dev/null; then
        sed -i "s/^ICCID_CACHE=.*/ICCID_CACHE=\"$ICCID\"/" "$CONFIG"
    else
        printf 'ICCID_CACHE="%s"\n' "$ICCID" >> "$CONFIG"
    fi
fi

# --- Fetch current band configuration ---
log "Fetching current band config..."
_tmpfile="$TMP_DIR/u5gmax-bandfix-$(date +%s%N)-get.json"
_ssh_out="$TMP_DIR/ssh_get.txt"
printf '{"method":"get-radio-pref","params":{"iccid":"%s"}}\n' "$ICCID" > "$_tmpfile"
_ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || \
    { rm -f "$_tmpfile" "$_ssh_out"; die "get-radio-pref failed"; }
CURRENT=$(cat "$_ssh_out")
rm -f "$_tmpfile" "$_ssh_out"

if [ -z "$CURRENT" ]; then
    log "WARNING: uiwwand-ctl returned empty response — modem still initializing, cron will retry"
    exit 0
fi
log "Current: $CURRENT"

# --- Fetch current RAT mode ---
_tmpfile="$TMP_DIR/u5gmax-bandfix-$(date +%s%N)-rat-st.json"
_ssh_out="$TMP_DIR/ssh_rat_st.txt"
printf '%s\n' '{"method":"get-radio-status"}' > "$_tmpfile"
_ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || true
RAT_STATUS=$(cat "$_ssh_out")
rm -f "$_tmpfile" "$_ssh_out"
RAT_MODE=$(printf '%s' "$RAT_STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('rat-mode-active',''))" 2>/dev/null) || true
RAT_MODE=$(strip_nonprintable "$RAT_MODE")

if [ "$RAT_MODE" = "WCDMA" ]; then
    log "WARNING: WCDMA detected — modem stuck on 3G, forcing reregistration to 4G/5G"
    _tmpfile="$TMP_DIR/u5gmax-bandfix-$(date +%s%N)-rat.json"
    _ssh_out="$TMP_DIR/ssh_rat_set.txt"
    printf '%s\n' '{"method":"set-radio-pref","params":{"iccid":"'"$ICCID"'","mode":"5gnr,lte"}}' > "$_tmpfile"
    _ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || true
    RESULT=$(cat "$_ssh_out")
    rm -f "$_tmpfile" "$_ssh_out"
    if echo "$RESULT" | grep -q '"result":{}'; then
        log "SUCCESS: RAT mode reconfiguration triggered"
    else
        log "WARNING: RAT mode reconfiguration attempted but unexpected response: $RESULT"
    fi
    log "Waiting 60s for modem to reregister..."
    sleep 60
    _tmpfile="$TMP_DIR/u5gmax-bandfix-$(date +%s%N)-rat-st2.json"
    _ssh_out="$TMP_DIR/ssh_rat_st2.txt"
    printf '%s\n' '{"method":"get-radio-status"}' > "$_tmpfile"
    _ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || true
    RAT_STATUS=$(cat "$_ssh_out")
    rm -f "$_tmpfile" "$_ssh_out"
    RAT_MODE=$(printf '%s' "$RAT_STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('rat-mode-active',''))" 2>/dev/null) || true
    RAT_MODE=$(strip_nonprintable "$RAT_MODE")
    if [ "$RAT_MODE" = "WCDMA" ]; then
        log "WCDMA persists after reregistration — modem may need manual intervention, skipping band fix this run"
        exit 0
    fi
    _tmpfile="$TMP_DIR/u5gmax-bandfix-$(date +%s%N)-get2.json"
    _ssh_out="$TMP_DIR/ssh_get2.txt"
    printf '{"method":"get-radio-pref","params":{"iccid":"%s"}}\n' "$ICCID" > "$_tmpfile"
    _ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || \
        { rm -f "$_tmpfile" "$_ssh_out"; die "get-radio-pref failed"; }
    CURRENT=$(cat "$_ssh_out")
    rm -f "$_tmpfile" "$_ssh_out"
    if [ -z "$CURRENT" ]; then
        log "WARNING: uiwwand-ctl returned empty after WCDMA recovery — modem still initializing, cron will retry"
        exit 0
    fi
    log "Current: $CURRENT"
fi

# --- Check compliance: compare against ISP profile spec ---
check_compliance() {
    local json="$1"
    python3 - "$json" "$LTE_REQUIRED" "$NR5G_SA_REQUIRED" "$NR5G_NSA_REQUIRED" << 'PYEOF'
import json, sys

def parse_bands(s):
    return {int(b.strip()) for b in s.split(",") if b.strip().isdigit()}

try:
    current = json.loads(sys.argv[1])
    result = current.get("result", {})
    required = {
        "lte_band":      parse_bands(sys.argv[2]),
        "nr5g_sa_band":  parse_bands(sys.argv[3]),
        "nr5g_nsa_band": parse_bands(sys.argv[4]),
    }
    mismatches = []
    # Check mode — must be exactly "5gnr,lte"
    actual_mode = result.get("mode", "")
    if actual_mode != "5gnr,lte":
        mismatches.append(f"  mode: is '{actual_mode}', must be '5gnr,lte'")
    for key, req_bands in required.items():
        actual_str = result.get(key, "")
        actual_bands = parse_bands(actual_str) if actual_str else set()
        if actual_bands != req_bands:
            extra   = sorted(actual_bands - req_bands)
            missing = sorted(req_bands - actual_bands)
            parts = []
            if extra:   parts.append(f"extra={extra}")
            if missing: parts.append(f"missing={missing}")
            mismatches.append(f"  {key}: {', '.join(parts)}")
    if mismatches:
        for m in mismatches:
            print(m)
    sys.exit(0)
except Exception as e:
    print(f"Parse error: {e} — raw input: {sys.argv[1][:200]}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

MISMATCHES=$(check_compliance "$CURRENT")
if [ -z "$MISMATCHES" ]; then
    log "OK: Band configuration matches ${PROFILE_NAME} spec — nothing to do"
    exit 0
fi

log "Non-compliant configuration detected:"
while IFS= read -r line; do
    log "$line"
done <<< "$MISMATCHES"

# --- Apply band fix ---
log "Applying ${PROFILE_NAME}-spec band configuration..."

PAYLOAD=$(printf \
    '{"method":"set-radio-pref","params":{"iccid":"%s","mode":"5gnr,lte","lte_band":"%s","nr5g_sa_band":"%s","nr5g_nsa_band":"%s"}}' \
    "$ICCID" "$LTE_REQUIRED" "$NR5G_SA_REQUIRED" "$NR5G_NSA_REQUIRED")

_tmpfile="$TMP_DIR/u5gmax-bandfix-$(date +%s%N).json"
_ssh_out="$TMP_DIR/ssh_set.txt"
printf '%s\n' "$PAYLOAD" > "$_tmpfile"
_ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || \
    { rm -f "$_tmpfile" "$_ssh_out"; die "set-radio-pref command failed"; }
RESULT=$(cat "$_ssh_out")
rm -f "$_tmpfile" "$_ssh_out"

if echo "$RESULT" | grep -q '"result":{}'; then
    log "SUCCESS: Band configuration applied"
else
    die "Unexpected response from set-radio-pref: $RESULT"
fi

# --- Verify ---
log "Verifying..."
_tmpfile="$TMP_DIR/u5gmax-bandfix-$(date +%s%N)-verify.json"
_ssh_out="$TMP_DIR/ssh_verify.txt"
printf '{"method":"get-radio-pref","params":{"iccid":"%s"}}\n' "$ICCID" > "$_tmpfile"
_ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || \
    die "verify get-radio-pref failed"
VERIFY=$(cat "$_ssh_out")
rm -f "$_tmpfile" "$_ssh_out"
REMAINING=$(check_compliance "$VERIFY")
if [ -n "$REMAINING" ]; then
    die "Fix applied but config still non-compliant:$REMAINING"
fi

log "VERIFIED: ${PROFILE_NAME}-compliant band configuration confirmed"
log "Done."
