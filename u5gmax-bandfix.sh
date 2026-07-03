#!/bin/bash
# u5gmax-bandfix — interactive CLI for managing ISP band restrictions on U5G-Max
# Installed to /usr/local/sbin/u5gmax-bandfix

set -euo pipefail

VERSION="1.3.1"
DATA_DIR="/data/u5gmax-bandfix"
CONFIG="$DATA_DIR/config"
SSH_KEY="$DATA_DIR/id_ed25519"
KNOWN_HOSTS="$DATA_DIR/known_hosts"
LOG_FILE="$DATA_DIR/band-fix.log"
CRON_FILE="/etc/cron.d/u5gmax-bandfix"
BAND_FIX="$DATA_DIR/band-fix.sh"
REBOOT_CRON_FILE="/etc/cron.d/u5gmax-reboot"

# ISP profile — PROFILE is authoritative. Band lists are always derived here, never
# trusted from a persisted config value, so a version update propagates new band specs
# without requiring a manual "switch profile" round-trip.
_resolve_band_profile() {
    : "${PROFILE:=odido}"
    case "$PROFILE" in
        freemobile)
            PROFILE_NAME="Free Mobile FR"
            MODEM_MODEL="UMBBE631"
            LTE_REQUIRED="1,3,7,8,28"
            NR5G_SA_REQUIRED="1,28,78"
            NR5G_NSA_REQUIRED="1,28,78"
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
}

# Load config early so MODEM_MODEL and profile vars are available globally
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG" || true
_resolve_band_profile

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'; NC='\033[0m'
BOLD='\033[1m'

# ── Helpers ───────────────────────────────────────────────────────────────────
die()  { printf "${R}✗ ERROR: %s${NC}\n" "$*" >&2; exit 1; }
pause() { printf "\nPress Enter to continue..."; read -r; }

get_ip() {
    timeout 30 mongo --quiet localhost:27117/ace \
        --eval 'var d=db.device.findOne({model:/^UMBBE/}); print(d ? d.ip : "null")' < /dev/null 2>/dev/null | tr -d '\r\n' || echo ""
}

get_last_run() {
    if [ -f "$LOG_FILE" ]; then
        grep -E "^\[" "$LOG_FILE" | tail -1 | grep -oE '^\[[0-9 :-]+\]' | tr -d '[]' || echo "never"
    else
        echo "never"
    fi
}

get_last_result() {
    [ -f "$LOG_FILE" ] || { printf "—"; return; }
    local line
    line=$(grep -E "\] (OK:|VERIFIED:|ERROR:|WARNING:)" "$LOG_FILE" | tail -1)
    [ -z "$line" ] && { printf "—"; return; }
    if echo "$line" | grep -q "OK:"; then
        printf "${G}✓ ${PROFILE_NAME}-compliant${NC}"
    elif echo "$line" | grep -q "VERIFIED:"; then
        printf "${G}✓ Fixed & verified${NC}"
    elif echo "$line" | grep -q "WARNING: SSH"; then
        printf "${Y}⚠ Modem offline${NC}"
    elif echo "$line" | grep -q "WCDMA"; then
        printf "${Y}⚠ WCDMA recovery${NC}"
    elif echo "$line" | grep -q "timed out\|timeout"; then
        printf "${Y}⚠ MongoDB timeout${NC}"
    elif echo "$line" | grep -q "ERROR:"; then
        printf "${R}✗ Error — see logs${NC}"
    else
        printf "${Y}⚠ Unknown${NC}"
    fi
}

cron_status() {
    if [ -f "$CRON_FILE" ]; then
        local min
        min=$(grep -E "^[0-9]+ \* \* \* \* root /data/u5gmax-bandfix/band-fix" "$CRON_FILE" | awk '{print $1}' | head -1)
        printf 'active (hourly at :%02d)' "${min:-0}"
    else
        echo "NOT INSTALLED"
    fi
}

get_reboot_status() {
    source "$CONFIG" 2>/dev/null || true
    local _rtime="${REBOOT_TIME:-}"
    local _rsched="${REBOOT_SCHEDULE:-}"
    if [ -z "$_rtime" ]; then
        printf "not scheduled"
    else
        printf "${Y}⚠ scheduled %s %s (%s)" "$_rsched" "$_rtime" "$(date +%Z)"
    fi
}

ssh_opts() {
    echo "-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS"
}

load_config() {
    [ -f "$CONFIG" ] || die "Not installed. Run install.sh first."
    # shellcheck source=/dev/null
    source "$CONFIG"
    : "${SSH_USER:?}"
    _resolve_band_profile
}

# ── Header ────────────────────────────────────────────────────────────────────
print_header() {
    local u5g_ip cron last_run result reboot_status
    u5g_ip=$(get_ip)
    [ -z "$u5g_ip" ] || [ "$u5g_ip" = "null" ] && u5g_ip="${R}offline${NC}"
    cron=$(cron_status)
    last_run=$(get_last_run)
    result=$(get_last_result)
    reboot_status=$(get_reboot_status)

    clear
    printf "${C}"
    printf '╔══════════════════════════════════════════════╗\n'
    printf '║            u5gmax-bandfix  v%-5s            ║\n' "$VERSION"
    printf '║   %-42s ║\n' "${PROFILE_NAME} — UniFi U5G-Max"
    printf '╠══════════════════════════════════════════════╣\n'
    printf "${NC}"
    printf "  ${W}U5G-Max IP:${NC}  ${u5g_ip}\n"
    printf "  ${W}Cron:${NC}        %s\n" "$cron"
    printf "  ${W}Last run:${NC}    %s\n" "$last_run"
    printf "  ${W}Result:${NC}      %s\n" "$result"
    printf "  ${W}Reboot:${NC}      %s\n" "$reboot_status"
    printf "${C}"
    printf '╠══════════════════════════════════════════════╣\n'
    printf "${NC}"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
print_menu() {
    printf "  ${W}1)${NC} Force band check now\n"
    printf "  ${W}2)${NC} Show current band status\n"
    printf "  ${W}3)${NC} Switch ISP profile\n"
    printf "  ${W}4)${NC} Show logs\n"
    printf "  ${W}5)${NC} Reinstall SSH key on U5G-Max\n"
    printf "  ${W}6)${NC} Update to latest version\n"
    printf "  ${W}7)${NC} Uninstall\n"
    printf "  ${W}8)${NC} Schedule one-time reboot\n"
    printf "  ${W}0)${NC} Exit\n"
    printf "${C}"
    printf '╚══════════════════════════════════════════════╝\n'
    printf "${NC}"
}

# ── Actions ───────────────────────────────────────────────────────────────────

action_force_check() {
    printf "\n${Y}Running band check...${NC}\n\n"
    [ -f "$BAND_FIX" ] || die "band-fix.sh not found at $BAND_FIX"
    bash "$BAND_FIX" && printf "\n${G}✓ Done.${NC}\n" || printf "\n${R}✗ Check failed — see logs.${NC}\n"
    pause
}

action_band_status() {
    load_config
    local u5g_ip iccid current
    u5g_ip=$(get_ip)
    [ -z "$u5g_ip" ] || [ "$u5g_ip" = "null" ] && { printf "\n${R}U5G-Max not found in MongoDB.${NC}\n"; pause; return; }

    printf "\n${Y}Querying U5G-Max band configuration...${NC}\n"

    # Try SSH — if it fails, rescan host key (modem reboot regenerates host keys on tmpfs)
    _try_ssh() {
        local _ip="$1"
        ssh $(ssh_opts) "${SSH_USER}@${_ip}" "exit 0" < /dev/null 2>/dev/null
    }

    _reinstall_ssh_key() {
        local _ip="$1"
        local _pass; _pass=$(. "$CONFIG" 2>/dev/null; printf '%s' "${SSH_PASS:-}")
        [ -z "$_pass" ] && _pass=$(mongo --quiet localhost:27117/ace \
            --eval 'var s=db.setting.findOne({key:"mgmt"}); print(s ? s.x_ssh_password : "null")' \
            < /dev/null 2>/dev/null | tr -d '\r\n') || true
        [ -z "$_pass" ] || [ "$_pass" = "null" ] && return 1
        local _pf; _pf=$(mktemp /tmp/.cli-pw-XXXXXX)
        chmod 600 "$_pf"
        printf '%s' "$_pass" > "$_pf"
        sshpass -f "$_pf" ssh-copy-id \
            -i "$SSH_KEY.pub" \
            -o StrictHostKeyChecking=yes \
            -o UserKnownHostsFile="$KNOWN_HOSTS" \
            -o ConnectTimeout=10 \
            "${SSH_USER}@${_ip}" < /dev/null 2>/dev/null
        local _rc=$?
        rm -f "$_pf"
        return $_rc
    }

    if ! _try_ssh "$u5g_ip"; then
        printf "${Y}SSH failed — rescanning host key (modem may have rebooted)...${NC}\n"
        ssh-keyscan -T 10 "$u5g_ip" > "$KNOWN_HOSTS" 2>/dev/null || true
        if ! _try_ssh "$u5g_ip"; then
            printf "${Y}SSH key lost (modem tmpfs wiped) — reinstalling key...${NC}\n"
            if _reinstall_ssh_key "$u5g_ip" && _try_ssh "$u5g_ip"; then
                printf "${G}SSH key reinstalled successfully.${NC}\n"
            else
                printf "${Y}Still unreachable — waiting for modem to come online (max 5 min)...${NC}\n"
                local attempt=1
                while [ "$attempt" -le 10 ]; do
                    printf "  Attempt %d/10 — retrying in 30s...\r" "$attempt"
                    sleep 30
                    u5g_ip=$(get_ip)
                    [ -n "$u5g_ip" ] && [ "$u5g_ip" != "null" ] || { attempt=$((attempt+1)); continue; }
                    ssh-keyscan -T 10 "$u5g_ip" > "$KNOWN_HOSTS" 2>/dev/null || true
                    _reinstall_ssh_key "$u5g_ip" 2>/dev/null || true
                    _try_ssh "$u5g_ip" && break
                    attempt=$((attempt+1))
                done
                if ! _try_ssh "$u5g_ip"; then
                    printf "\n${R}U5G-Max did not come online within 5 minutes.${NC}\n"
                    pause; return
                fi
            fi
        fi
        printf "${G}Connected to %s${NC}\n" "$u5g_ip"
    fi

    # Get live ICCID
    iccid=$(printf '{"method":"get-sim-state"}' \
        | ssh $(ssh_opts) "${SSH_USER}@${u5g_ip}" "uiwwand-ctl" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']['iccid'])" 2>/dev/null) || iccid="${ICCID_CACHE:-}"

    [ -z "$iccid" ] && { printf "${R}Could not read ICCID.${NC}\n"; pause; return; }

    current=$(printf '{"method":"get-radio-pref","params":{"iccid":"%s"}}' "$iccid" \
        | ssh $(ssh_opts) "${SSH_USER}@${u5g_ip}" "uiwwand-ctl" 2>/dev/null) || \
        { printf "${R}Could not read band config from modem.${NC}\n"; pause; return; }

    printf "\n${W}ICCID:${NC} %s\n\n" "$iccid"

    python3 - "$current" "$LTE_REQUIRED" "$NR5G_SA_REQUIRED" "$NR5G_NSA_REQUIRED" << 'PYEOF'
import json, sys

def _bands(s):
    return {int(b) for b in s.split(",") if b.strip().isdigit()}

REQUIRED = {
    "lte_band":      _bands(sys.argv[2]),
    "nr5g_sa_band":  _bands(sys.argv[3]),
    "nr5g_nsa_band": _bands(sys.argv[4]),
}

GREEN = "\033[0;32m"
RED   = "\033[0;31m"
BOLD  = "\033[1m"
NC    = "\033[0m"

ok = True
try:
    data = json.loads(sys.argv[1])
    result = data.get("result", {})
    labels = {
        "lte_band":      "LTE bands    ",
        "nr5g_sa_band":  "NR5G SA bands",
        "nr5g_nsa_band": "NR5G NSA bands",
    }
    for key, req in REQUIRED.items():
        val = result.get(key, "")
        actual = {int(b) for b in val.split(",") if b.strip().isdigit()} if val else set()
        extra = sorted(actual - req)
        missing = sorted(req - actual)
        if actual == req:
            status = f"{GREEN}✓ compliant{NC}"
        else:
            parts = []
            if extra:   parts.append(f"extra={extra}")
            if missing: parts.append(f"missing={missing}")
            status = f"{RED}✗ Non-compliant — {', '.join(parts)}{NC}"
            ok = False
        print(f"  {BOLD}{labels[key]}:{NC} {val or '(empty)'}")
        print(f"               → {status}")
        print()
except Exception as e:
    print(f"Parse error: {e}")
    ok = False

sys.exit(0 if ok else 1)
PYEOF
    local _pyrc=$?
    if [ "$_pyrc" -ne 0 ]; then
        read -r -p "  Bands are non-compliant. Apply ${PROFILE_NAME} fix now? [Y/n] " _confirm
        case "${_confirm:-Y}" in
            [Yy]|"") bash "$BAND_FIX" && printf "\n${G}✓ Fix applied.${NC}\n" || printf "\n${R}✗ Fix failed — see logs.${NC}\n" ;;
            *) printf "Skipped.\n" ;;
        esac
    fi
    pause
}

_write_profile_to_config() {
    # Only PROFILE is persisted — PROFILE_NAME/MODEM_MODEL/band lists are always
    # re-derived from PROFILE via _resolve_band_profile, so a version update that
    # changes a profile's band spec applies on the next run without a manual switch.
    {
        grep -v "^PROFILE=\|^PROFILE_NAME=\|^MODEM_MODEL=\|^LTE_REQUIRED=\|^NR5G_SA_REQUIRED=\|^NR5G_NSA_REQUIRED=" "$CONFIG"
        printf 'PROFILE="%s"\n' "$PROFILE"
    } > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
    chmod 600 "$CONFIG"
}

action_switch_profile() {
    load_config

    printf "\n${Y}Switch ISP profile${NC}\n\n"
    printf "  ${W}1)${NC} Odido NL       — LTE B1/3/7/32/38, NR5G n1/3/7/38/78\n"
    printf "  ${W}2)${NC} Free Mobile FR — LTE B1/3/7/8/28,  NR5G n1/28/78\n"
    printf "  ${W}0)${NC} Cancel\n"
    printf "\n  Current: ${W}${PROFILE_NAME}${NC}\n\n"
    read -r -p "  Choose: " _PCHOICE

    case "${_PCHOICE}" in
        1) PROFILE="odido" ;;
        2) PROFILE="freemobile" ;;
        0) return ;;
        *) printf "${R}Invalid choice.${NC}\n"; pause; return ;;
    esac
    _resolve_band_profile

    _write_profile_to_config
    printf "\n${G}✓ Profile switched to ${PROFILE_NAME}.${NC}\n"
    printf "  LTE bands:     ${W}%s${NC}\n" "$LTE_REQUIRED"
    printf "  NR5G SA bands: ${W}%s${NC}\n" "$NR5G_SA_REQUIRED"
    printf "  NR5G NSA bands:${W}%s${NC}\n" "$NR5G_NSA_REQUIRED"
    read -r -p "  Run band check now? [Y/n] " _run
    case "${_run:-Y}" in
        [Yy]|"") action_force_check ;;
    esac
}

action_show_logs() {
    printf "\n${Y}Last 50 lines of %s:${NC}\n\n" "$LOG_FILE"
    if [ -f "$LOG_FILE" ]; then
        tail -50 "$LOG_FILE"
    else
        printf "(no log file yet)\n"
    fi
    printf "\n"
    read -r -p "Follow log live? [y/N] " FOLLOW
    if [[ "$FOLLOW" =~ ^[Yy]$ ]]; then
        printf "${Y}Ctrl+C to stop.${NC}\n\n"
        tail -f "$LOG_FILE"
    fi
}

action_reinstall_key() {
    load_config
    local u5g_ip ssh_pass
    u5g_ip=$(get_ip)
    [ -z "$u5g_ip" ] || [ "$u5g_ip" = "null" ] && { printf "\n${R}U5G-Max not online.${NC}\n"; pause; return; }

    printf "\n${Y}Reinstalling SSH key on U5G-Max ($u5g_ip)...${NC}\n"
    printf "Reading password from MongoDB...\n"
    ssh_pass=$(timeout 30 mongo --quiet localhost:27117/ace \
        --eval "print(db.setting.findOne({key:'mgmt'}).x_ssh_password)" < /dev/null 2>/dev/null | tr -d '\r\n') || true
    [ -z "$ssh_pass" ] || [ "$ssh_pass" = "null" ] && { printf "${R}Could not read password from MongoDB.${NC}\n"; pause; return; }

    # Re-scan host key (IP may have changed)
    ssh-keyscan -T 10 "$u5g_ip" > "$KNOWN_HOSTS" 2>/dev/null || true

    _PASS_FILE=$(mktemp /tmp/.udm-sshpass-XXXXXX)
    chmod 600 "$_PASS_FILE"
    printf '%s' "$ssh_pass" > "$_PASS_FILE"

    sshpass -f "$_PASS_FILE" ssh-copy-id \
        -i "$SSH_KEY.pub" \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o ConnectTimeout=10 \
        "${SSH_USER}@${u5g_ip}" 2>/dev/null && \
        printf "${G}✓ SSH key reinstalled.${NC}\n" || \
        printf "${R}✗ Failed — check connectivity.${NC}\n"

    rm -f "$_PASS_FILE"
    printf '%s\n' "$u5g_ip" > "$DATA_DIR/last_ip.txt"
    pause
}

action_schedule_reboot() {
    load_config
    
    # Re-source config to get current reboot settings
    source "$CONFIG" 2>/dev/null || true
    local _rtime=""
    local _rsched=""
    
    # If already scheduled, show management submenu
    if [ -n "${REBOOT_TIME:-}" ] && [ -f "$REBOOT_CRON_FILE" ]; then
        printf "\nScheduled: %s %s (UTC)\n\n" "$REBOOT_SCHEDULE" "$REBOOT_TIME"
        printf "  1) Cancel scheduled reboot\n"
        printf "  2) Change time\n"
        if [ "${REBOOT_SCHEDULE:-}" = "once" ]; then
            printf "  3) Change to daily\n"
        else
            printf "  3) Change to once\n"
        fi
        printf "  0) Back\n"
        printf "\n  Choose: "
        read -r _sub
        case "${_sub}" in
            1)
                rm -f "$REBOOT_CRON_FILE"
                grep -v "^REBOOT_" "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
                printf "\n✓ Scheduled reboot cancelled.\n"
                pause; return ;;
            2)
                _rtime="$REBOOT_TIME" ;;  # fall through to schedule new time below
            3)
                if [ "${REBOOT_SCHEDULE:-}" = "once" ]; then _rsched="daily"; else _rsched="once"; fi
                _rtime="$REBOOT_TIME" ;;  # keep time, change type — fall through to write
            0) return ;;
            *) printf "\nInvalid choice.\n"; pause; return ;;
        esac
    fi
    
    # Choose schedule type (only if not changing type from submenu)
    if [ -z "${_rsched:-}" ] || [ "${_sub:-}" != "3" ]; then
        printf "\n  Schedule type:\n"
        printf "  1) Once       — reboot one time, then remove schedule\n"
        printf "  2) Daily      — reboot every 24h at this time\n"
        printf "  0) Cancel\n"
        printf "\n  Choose: "
        read -r _tchoice
        case "${_tchoice}" in
            1) _rsched="once" ;;
            2) _rsched="daily" ;;
            0) return ;;
            *) printf "\nInvalid choice.\n"; pause; return ;;
        esac
    fi
    
    # Enter time (if not already set from type-change)
    if [ -z "${_rtime:-}" ]; then
        _now_disp="$(date +"%H:%M %Z")"
        printf "\n  System time now: %s\n" "$_now_disp"
        printf "  Enter reboot time (HH:MM, %s): " "$(date +%Z)"
        read -r _rtime
        # Accept single-digit hour (4:00 → 04:00)
        case "$_rtime" in [0-9]:*) _rtime="0$_rtime" ;; esac
        if ! printf "%s" "$_rtime" | grep -qE "^([01][0-9]|2[0-3]):[0-5][0-9]$"; then
            printf "\nInvalid time format. Use HH:MM or H:MM (e.g. 04:30).\n"
            pause; return
        fi
    fi
    
    # Write REBOOT_TIME and REBOOT_SCHEDULE to config
    local _h _m
    _h=$(printf "%s" "$_rtime" | cut -d: -f1)
    _m=$(printf "%s" "$_rtime" | cut -d: -f2)
    
    grep -v "^REBOOT_" "$CONFIG" > "$CONFIG.tmp"
    printf 'REBOOT_TIME="%s"\n' "$_rtime" >> "$CONFIG.tmp"
    printf 'REBOOT_SCHEDULE="%s"\n' "$_rsched" >> "$CONFIG.tmp"
    mv "$CONFIG.tmp" "$CONFIG"
    chmod 600 "$CONFIG"
    
    # Write cron entry
    if [ "$_rsched" = "once" ]; then
        # Determine today or tomorrow
        local _now_hm _today_d _today_m _tomorrow _req_hm _label
        _now_hm=$(date +%H%M)
        _req_hm=$(printf "%s" "$_rtime" | tr -d :)
        if [ "$_req_hm" -gt "$_now_hm" ] 2>/dev/null; then
            _today_d=$(date +%d)
            _today_m=$(date +%m)
            _label="today"
        else
            _today_d=$(date -d "+1 day" +%d)
            _today_m=$(date -d "+1 day" +%m)
            _label="tomorrow"
        fi
        printf "SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n%s %s %s %s * root /data/u5gmax-bandfix/reboot-modem.sh >> /data/u5gmax-bandfix/band-fix.log 2>&1\n" "$_m" "$_h" "$_today_d" "$_today_m" > "$REBOOT_CRON_FILE"
        printf "\n✓ Reboot scheduled: %s %s (%s) — once\n" "$_label" "$_rtime" "$(date +%Z)"
    else
        printf "SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n%s %s * * * root /data/u5gmax-bandfix/reboot-modem.sh >> /data/u5gmax-bandfix/band-fix.log 2>&1\n" "$_m" "$_h" > "$REBOOT_CRON_FILE"
        printf "\n✓ Reboot scheduled: daily %s (%s)\n" "$_rtime" "$(date +%Z)"
    fi
    chmod 644 "$REBOOT_CRON_FILE"
    pause
}

action_update() {
    local BASE="https://raw.githubusercontent.com/royrijpma/u5gmax-bandfix/main"
    local ok=0 fail=0

    printf "\n${Y}Updating all u5gmax-bandfix scripts from GitHub...${NC}\n\n"

    if ! command -v curl >/dev/null 2>&1; then
        printf "${R}curl not available.${NC}\n"; pause; return
    fi

    _update_file() {
        local url="$1" dest="$2" mode="$3"
        if curl -sSL "$url" -o "$dest.new" && mv "$dest.new" "$dest" && chmod "$mode" "$dest"; then
            printf "  ${G}✓${NC} %s\n" "$dest"
            ok=$((ok+1))
        else
            rm -f "$dest.new"
            printf "  ${R}✗${NC} %s\n" "$dest"
            fail=$((fail+1))
        fi
    }

    _update_file "$BASE/band-fix.sh"        "$DATA_DIR/band-fix.sh"              "+x"
    _update_file "$BASE/on-boot.sh"         "$DATA_DIR/on-boot.sh"               "+x"
    _update_file "$BASE/uninstall.sh"       "$DATA_DIR/uninstall.sh"             "+x"
    _update_file "$BASE/reboot-modem.sh"    "$DATA_DIR/reboot-modem.sh"          "+x"
    _update_file "$BASE/u5gmax-bandfix.sh"  "$DATA_DIR/u5gmax-bandfix.sh"        "+x"
    _update_file "$BASE/u5gmax-bandfix.sh"  "/usr/local/sbin/u5gmax-bandfix"     "+x"

    printf "\n"
    if [ "$fail" -eq 0 ]; then
        printf "${G}✓ All scripts updated.${NC}\n"
        exit 0
    else
        printf "${Y}⚠ %d updated, %d failed.${NC}\n" "$ok" "$fail"
        pause
    fi
}

action_uninstall() {
    printf "\n${R}${BOLD}WARNING: This will remove u5gmax-bandfix completely.${NC}\n"
    printf "The U5G-Max will revert to all-bands on next reboot.\n\n"
    read -r -p "Type 'yes' to confirm: " CONFIRM
    [ "$CONFIRM" = "yes" ] || { printf "Cancelled.\n"; pause; return; }

    local UNINSTALL
    UNINSTALL="$(dirname "$BAND_FIX")/uninstall.sh"
    # Try local uninstall.sh first, then fall back to same dir as this script
    [ -f "$UNINSTALL" ] || UNINSTALL="/usr/local/sbin/u5gmax-bandfix-uninstall"

    if [ -f "$UNINSTALL" ]; then
        bash "$UNINSTALL"
        rm -f /usr/local/sbin/u5gmax-bandfix
        printf "\n${G}Done. u5gmax-bandfix removed.${NC}\n"
        exit 0
    else
        printf "${R}Uninstall script not found at %s${NC}\n" "$UNINSTALL"
        pause
    fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
# Non-interactive mode: u5gmax-bandfix check|status|profile|logs|update|uninstall
if [ $# -gt 0 ]; then
    case "$1" in
        check)     action_force_check ;;
        status)    action_band_status ;;
        profile)   action_switch_profile ;;
        logs)      action_show_logs ;;
        update)    action_update ;;
        uninstall) action_uninstall ;;
        reboot-schedule) action_schedule_reboot ;;
        *)
            printf "Usage: u5gmax-bandfix [check|status|profile|logs|update|uninstall|reboot-schedule]\n"
            printf "       u5gmax-bandfix          (interactive menu)\n"
            exit 1
            ;;
    esac
    exit 0
fi

# Interactive menu
while true; do
    print_header
    print_menu
    printf "\n  ${W}Choose:${NC} "
    read -r CHOICE

    case "$CHOICE" in
        1) action_force_check ;;
        2) action_band_status ;;
        3) action_switch_profile ;;
        4) action_show_logs ;;
        5) action_reinstall_key ;;
        6) action_update ;;
        7) action_uninstall ;;
        8) action_schedule_reboot ;;
        0) clear; exit 0 ;;
        *) printf "\n${R}Invalid choice.${NC}\n"; sleep 1 ;;
    esac
done
