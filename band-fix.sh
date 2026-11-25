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

# --- UniFi Network database (UniFi OS 6 / Network >= 10.6) ---
# The controller moved from MongoDB (localhost:27117/ace) to PostgreSQL: cluster
# "apps", port 5434, database "unifi-network", schema "config". Tables used:
#   device  (ip, model, version, last_seen)  — the U5G-Max
#   setting (key='mgmt', dynamic_part jsonb) — device SSH credentials
# Queries run as root via `su - postgres` over the unix socket. psql is bounded
# by its own connect/statement timeouts (an orphaned psql self-terminates even
# if the su wrapper is SIGKILLed by the cron guard below); the background+SIGKILL
# pattern is kept because `timeout` and signals do not propagate reliably in
# UniFi OS cron environments.
_PG_QUERY_TIMEOUT_MS=10000

_pg_query() {
    # _pg_query <sql> — prints single-column result via psql -At, "" on failure
    local _out="$TMP_DIR/pg_out_$$" _rc=0
    : > "$_out"
    printf '%s' "$1" | su - postgres -c \
        "PGCONNECT_TIMEOUT=10 PGOPTIONS='-c statement_timeout=$_PG_QUERY_TIMEOUT_MS' psql -p 5434 -d unifi-network -v ON_ERROR_STOP=1 -Atf -" \
        > "$_out" 2>/dev/null &
    local _pid=$!
    # Guard detached from stdout: a helper running inside $( ) must not keep the
    # substitution's stdout pipe open for the guard's full sleep (blocking every call)
    ( sleep 30 && kill -9 "$_pid" 2>/dev/null ) > /dev/null 2>&1 &
    local _kpid=$!
    { wait "$_pid" 2>/dev/null; } || _rc=$?
    kill "$_kpid" 2>/dev/null; wait "$_kpid" 2>/dev/null || true
    tr -d '\r\n' < "$_out"
    rm -f "$_out"
    return $_rc
}

_query_pg_ip() {
    _pg_query "SELECT coalesce((SELECT ip FROM config.device WHERE model LIKE 'UMBBE%' AND ip IS NOT NULL ORDER BY last_seen DESC NULLS LAST LIMIT 1),'null')"
}

# Compact pretty JSON to a single line for the log (falls back to raw on parse error)
_json_compact() {
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))' 2>/dev/null || printf '%s' "$1"
}

# --- Helper: run SSH with guaranteed termination via background+SIGKILL (20s max) ---
# Usage: _ssh_bg <outfile> [ssh args...] (stdin from caller via redirect)
# Output captured to outfile; returns ssh exit code.
#
# IMPORTANT: bash redirects background process stdin to /dev/null when job
# control is disabled (cron, non-interactive). We save the caller's stdin to a
# tempfile BEFORE backgrounding, then pass it explicitly so ssh stays stable.
_ssh_bg() {
    local _out="$1"; shift
    local _rc=0 _in="$TMP_DIR/ssh_bg_stdin_$$"
    cat > "$_in"        # drain caller's stdin NOW (foreground — inherits caller's redirect)
    : > "$_out"
    ssh "$@" < "$_in" > "$_out" 2>/dev/null &
    local _pid=$!
    # Guard detached from stdout — see _pg_query
    ( sleep 20 && kill -9 "$_pid" 2>/dev/null ) > /dev/null 2>&1 &
    local _kpid=$!
    { wait "$_pid" 2>/dev/null; } || _rc=$?
    kill "$_kpid" 2>/dev/null; wait "$_kpid" 2>/dev/null || true
    rm -f "$_in"
    return $_rc
}

# --- Helper: modem command via ubus (U5G-Max firmware >= 8.0.4) ---
# The old `echo <json> | ssh modem uiwwand-ctl` socket protocol is gone: the
# daemon logs "ctl: Could not parse payload" and answers empty. Firmware 8.x
# exposes the same JSON methods via ubus instead:
#   ssh modem "ubus call uiwwand call '<json>'"
# Response shape ({"result":...} / {"error":-1}) and all field names unchanged.
# Payloads are generated internally from validated numerics/enums and never
# contain single quotes — the guard below is defense in depth.
_wwan_cmd() {
    # _wwan_cmd <json-payload> — prints the modem's response JSON
    case "$1" in *"'"*) die "wwan payload must not contain single quotes: $1";; esac
    local _out="$TMP_DIR/wwan_out_$$" _rc=0
    _ssh_bg "$_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "ubus call uiwwand call '$1'" || _rc=$?
    cat "$_out"
    rm -f "$_out"
    return $_rc
}

# --- Helper: update known_hosts when IP changes ---
# ssh-keyscan uses SIGALRM internally for its -T timeout, which does not
# fire reliably in the UniFi OS cron container namespace — wrap it in the
# same background+SIGKILL pattern used for the database queries and ssh.
_update_known_hosts() {
    local _old="$1" _new="$2" _rc=0
    log "IP changed ($_old → $_new) — updating known_hosts..."
    if [ -f "$KNOWN_HOSTS" ] && [ -n "$_old" ]; then
        ssh-keygen -R "$_old" -f "$KNOWN_HOSTS" 2>/dev/null || true
    fi
    : > "$TMP_DIR/known_hosts.tmp"
    ssh-keyscan -T 10 "$_new" > "$TMP_DIR/known_hosts.tmp" 2>/dev/null &
    local _kspid=$!
    ( sleep 15 && kill -9 "$_kspid" 2>/dev/null ) > /dev/null 2>&1 &
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

# --- Helper: follow credential changes in UniFi (the device SSH user/password can be rotated) ---
# The config caches SSH_USER/SSH_PASS from install time. When UniFi changes them (new adoption, firmware, rotation) the cached pair
# is stale and every key reinstall fails ("ssh-copy-id failed rc=5") although the modem is online. Re-read them from MongoDB and,
# when they differ, rewrite the config (values single-quoted, so any password survives `. config`).
_refresh_credentials() {
    local _u _p _cu _cp
    _u=$(_pg_query "SELECT coalesce(dynamic_part->>'x_ssh_username','null') FROM config.setting WHERE key='mgmt'") || true
    _p=$(_pg_query "SELECT coalesce(dynamic_part->>'x_ssh_password','null') FROM config.setting WHERE key='mgmt'") || true
    if [ -z "$_u" ] || [ "$_u" = "null" ] || [ -z "$_p" ] || [ "$_p" = "null" ]; then
        log "Could not read the current SSH credentials from UniFi — keeping the cached ones"
        return 0
    fi
    if ! printf '%s' "$_u" | grep -qE '^[a-zA-Z0-9_-]{1,32}$'; then
        log "UniFi reports an SSH user with unexpected characters — keeping the cached credentials"
        return 0
    fi
    _cu="$SSH_USER"; _cp=$(. "$CONFIG" 2>/dev/null; printf '%s' "${SSH_PASS:-}")
    [ "$_u" = "$_cu" ] && [ "$_p" = "$_cp" ] && return 0
    log "UniFi's SSH credentials changed (user: $_cu -> $_u${_p:+, password updated}) — updating the config"
    local _tmp="$CONFIG.new"
    grep -vE '^(SSH_USER|SSH_PASS)=' "$CONFIG" > "$_tmp" 2>/dev/null || : > "$_tmp"
    printf 'SSH_USER=%s\n' "'$_u'" >> "$_tmp"
    printf "SSH_PASS='%s'\n" "$(printf '%s' "$_p" | sed "s/'/'\\\\''/g")" >> "$_tmp"
    chmod 600 "$_tmp"; mv "$_tmp" "$CONFIG"
    SSH_USER="$_u"
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

    # Fall back to the UniFi database if cache is missing or empty
    if [ -z "$_pass" ] || [ "$_pass" = "null" ]; then
        log "No cached SSH password in config — querying UniFi database..."
        _pass=$(_pg_query "SELECT coalesce(dynamic_part->>'x_ssh_password','null') FROM config.setting WHERE key='mgmt'") || true
        if [ -z "$_pass" ] || [ "$_pass" = "null" ]; then
            log "UniFi database password query returned empty — retrying in 10s..."
            sleep 10
            _pass=$(_pg_query "SELECT coalesce(dynamic_part->>'x_ssh_password','null') FROM config.setting WHERE key='mgmt'") || true
        fi
    fi

    if [ -z "$_pass" ] || [ "$_pass" = "null" ]; then
        log "Could not retrieve controller SSH password — cannot self-heal (re-run install.sh)"
        return 1
    fi

    log "Rescanning host key for $_ip (modem reboot regenerates host keys on tmpfs)..."
    : > "$TMP_DIR/reinstall_kh.tmp"
    ssh-keyscan -T 10 "$_ip" > "$TMP_DIR/reinstall_kh.tmp" 2>/dev/null &
    local _kspid=$!
    ( sleep 15 && kill -9 "$_kspid" 2>/dev/null ) > /dev/null 2>&1 &
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
    ( sleep 30 && kill -9 "$_scpid" 2>/dev/null ) > /dev/null 2>&1 &
    local _sckpid=$!
    { wait "$_scpid" 2>/dev/null; } || _rc=$?
    kill "$_sckpid" 2>/dev/null; wait "$_sckpid" 2>/dev/null || true
    rm -f "$_pf"

    if [ $_rc -ne 0 ]; then
        log "ssh-copy-id failed (rc=$_rc) — wrong password or sshd configuration changed"
        return 1
    fi

    # Firmware >= 8.0.4: dropbear reads /etc/dropbear/authorized_keys, not the
    # ~/.ssh/authorized_keys that ssh-copy-id writes — install the key in both
    # locations (the extra file is ignored on older firmware).
    _PUB=$(cut -d' ' -f1,2 "${SSH_KEY}.pub")
    sshpass -f "$_pf" ssh \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o ConnectTimeout=10 \
        "${SSH_USER}@${_ip}" \
        "mkdir -p /etc/dropbear && { grep -qxF '$_PUB' /etc/dropbear/authorized_keys 2>/dev/null || printf '%s\n' '$_PUB' >> /etc/dropbear/authorized_keys; }" \
        < /dev/null > /dev/null 2>&1 || \
        log "WARNING: could not update /etc/dropbear/authorized_keys on modem"

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
trap 'rmdir "$LOCK_DIR" 2>/dev/null; rm -f "$TMP_DIR"/u5gmax-bandfix-* "$TMP_DIR"/pg_out_* "$TMP_DIR"/wwan_out_* "$TMP_DIR"/ssh_*.txt "$TMP_DIR"/ssh_bg_stdin_* "$TMP_DIR"/known_hosts.tmp "$TMP_DIR"/reinstall_*' EXIT

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

# --- Get current U5G-Max IP (cache-first: skip the database on normal cron runs) ---
LAST_IP=""
[ -f "$LAST_IP_FILE" ] && LAST_IP=$(tr -d '\r\n' < "$LAST_IP_FILE")

U5G_IP=""
if printf '%s' "$LAST_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' 2>/dev/null; then
    U5G_IP="$LAST_IP"
    log "U5G-Max IP (cached): $U5G_IP"
else
    log "No cached IP — querying UniFi database..."
    U5G_IP=$(_query_pg_ip)
    log "UniFi database result: '$U5G_IP'"
    [ -z "$U5G_IP" ] && die "UniFi database unavailable and no cached IP"
    [ "$U5G_IP" = "null" ] && die "U5G-Max (UMBBE*) not found in the UniFi database — is the modem adopted?"
    validate_ip "$U5G_IP"
    _update_known_hosts "" "$U5G_IP"
fi

SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS"

# --- SSH connectivity check (if cached IP fails: poll MongoDB for new IP, then self-heal key) ---
log "Checking SSH connectivity..."
_chk="$TMP_DIR/ssh_chk.txt"
if ! _ssh_bg "$_chk" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "exit 0"; then
    log "SSH failed at $U5G_IP — polling UniFi database for updated IP (up to 5 attempts)..."
    _fresh="" _poll=1
    while [ "$_poll" -le 5 ]; do
        _fresh=$(_query_pg_ip) || true
        if printf '%s' "$_fresh" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            break
        fi
        log "UniFi database IP query returned empty (attempt $_poll/5) — retrying in 15s..."
        sleep 15
        _poll=$((_poll + 1))
    done
    if printf '%s' "$_fresh" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' && \
            [ "$_fresh" != "$U5G_IP" ]; then
        _update_known_hosts "$U5G_IP" "$_fresh"
        U5G_IP="$_fresh"
    fi
    _refresh_credentials
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
    # SSH to cached IP succeeded — check if the UniFi database has a newer IP and switch immediately
    if [ -n "$LAST_IP" ]; then
        _fresh_ip=$(_query_pg_ip 2>/dev/null) || true
        if printf '%s' "$_fresh_ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' && \
                [ "$_fresh_ip" != "$U5G_IP" ]; then
            log "INFO: IP changed ($U5G_IP → $_fresh_ip) — switching to new IP now"
            if ( _update_known_hosts "$U5G_IP" "$_fresh_ip" ); then
                U5G_IP="$_fresh_ip"
                log "INFO: Now using $U5G_IP for remainder of this run"
            else
                log "WARNING: Could not scan host key for $_fresh_ip — continuing with $U5G_IP (still reachable)"
            fi
        fi
    fi
fi

# --- Fetch ICCID live from modem (not from static config — survives SIM swaps) ---
log "Reading ICCID from modem..."
_sim_out=$(_wwan_cmd '{"method":"get-sim-state"}') || true
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
CURRENT=$(_wwan_cmd "{\"method\":\"get-radio-pref\",\"params\":{\"iccid\":\"$ICCID\"}}") || \
    die "get-radio-pref failed"

if [ -z "$CURRENT" ]; then
    log "WARNING: modem returned empty response — still initializing, cron will retry"
    exit 0
fi
log "Current: $(_json_compact "$CURRENT")"

# --- Fetch current RAT mode ---
RAT_STATUS=$(_wwan_cmd '{"method":"get-radio-status"}') || true
RAT_MODE=$(printf '%s' "$RAT_STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('rat-mode-active',''))" 2>/dev/null) || true
RAT_MODE=$(strip_nonprintable "$RAT_MODE")

if [ "$RAT_MODE" = "WCDMA" ]; then
    log "WARNING: WCDMA detected — modem stuck on 3G, forcing reregistration to 4G/5G"
    RESULT=$(_wwan_cmd "{\"method\":\"set-radio-pref\",\"params\":{\"iccid\":\"$ICCID\",\"mode\":\"5gnr,lte\"}}") || true
    if echo "$RESULT" | grep -q '"result":[[:space:]]*{}'; then
        log "SUCCESS: RAT mode reconfiguration triggered"
    else
        log "WARNING: RAT mode reconfiguration attempted but unexpected response: $(_json_compact "$RESULT")"
    fi
    log "Waiting 60s for modem to reregister..."
    sleep 60
    RAT_STATUS=$(_wwan_cmd '{"method":"get-radio-status"}') || true
    RAT_MODE=$(printf '%s' "$RAT_STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('rat-mode-active',''))" 2>/dev/null) || true
    RAT_MODE=$(strip_nonprintable "$RAT_MODE")
    if [ "$RAT_MODE" = "WCDMA" ]; then
        log "WCDMA persists after reregistration — modem may need manual intervention, skipping band fix this run"
        exit 0
    fi
    CURRENT=$(_wwan_cmd "{\"method\":\"get-radio-pref\",\"params\":{\"iccid\":\"$ICCID\"}}") || \
        die "get-radio-pref failed"
    if [ -z "$CURRENT" ]; then
        log "WARNING: modem returned empty after WCDMA recovery — still initializing, cron will retry"
        exit 0
    fi
    log "Current: $(_json_compact "$CURRENT")"
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

RESULT=$(_wwan_cmd "$PAYLOAD") || die "set-radio-pref command failed"

if echo "$RESULT" | grep -q '"result":[[:space:]]*{}'; then
    log "SUCCESS: Band configuration applied"
else
    die "Unexpected response from set-radio-pref: $(_json_compact "$RESULT")"
fi

# --- Verify ---
log "Verifying..."
VERIFY=$(_wwan_cmd "{\"method\":\"get-radio-pref\",\"params\":{\"iccid\":\"$ICCID\"}}") || \
    die "verify get-radio-pref failed"
REMAINING=$(check_compliance "$VERIFY")
if [ -n "$REMAINING" ]; then
    die "Fix applied but config still non-compliant:$REMAINING"
fi

log "VERIFIED: ${PROFILE_NAME}-compliant band configuration confirmed"
log "Done."
