#!/bin/bash
# u5gmax-bandfix installer
# Usage: curl -sSL https://raw.githubusercontent.com/royrijpma/u5gmax-bandfix/main/install.sh | bash

set -euo pipefail

DATA_DIR="/data/u5gmax-bandfix"
CONFIG="$DATA_DIR/config"
SSH_KEY="$DATA_DIR/id_ed25519"
KNOWN_HOSTS="$DATA_DIR/known_hosts"
LOG_FILE="$DATA_DIR/band-fix.log"
CRON_FILE="/etc/cron.d/u5gmax-bandfix"
SCRIPT_SRC="https://raw.githubusercontent.com/royrijpma/u5gmax-bandfix/main/band-fix.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

msg()  { printf '%b%s%b\n' "$BOLD" "$*" "$NC"; }
ok()   { printf '%b✓ %s%b\n' "$GREEN" "$*" "$NC"; }
warn() { printf '%b⚠ %s%b\n' "$YELLOW" "$*" "$NC"; }
die()  { printf '%b✗ ERROR: %s%b\n' "$RED" "$*" "$NC" >&2; exit 1; }

# Cleanup temp files on exit
_TMP_DIR="$DATA_DIR/tmp"
_PASS_FILE=""
trap '[ -n "$_PASS_FILE" ] && rm -f "$_PASS_FILE"; [ -d "$_TMP_DIR" ] && rmdir "$_TMP_DIR" 2>/dev/null || true' EXIT

msg ""
msg "=== u5gmax-bandfix installer ==="
msg ""

# --- Common LTE / NR5G bands, for custom band selection ---
# "code:description" — covers the bands most FWA/CPE modems and carriers use
# worldwide. Not an exhaustive 3GPP list (mmWave bands omitted) — if a band
# you need isn't listed, use the "enter manually" option.
LTE_BAND_LIST=(
    "1:2100 MHz"            "2:1900 MHz (US PCS)"     "3:1800 MHz"
    "4:1700/2100 MHz (US/CA AWS)" "5:850 MHz"          "7:2600 MHz"
    "8:900 MHz"              "12:700 MHz (US)"        "13:700 MHz (US)"
    "14:700 MHz (US, public safety)" "20:800 MHz (EU digital dividend)"
    "25:1900 MHz (US)"       "26:850 MHz (US)"        "28:700 MHz (APT)"
    "29:700 MHz (US, SDL)"   "32:1500 MHz (SDL)"      "38:2600 MHz (TDD)"
    "40:2300 MHz (TDD)"      "41:2500 MHz (TDD)"      "42:3500 MHz (TDD)"
    "66:1700/2100 MHz (AWS-3)" "71:600 MHz (US)"
)
NR_BAND_LIST=(
    "1:2100 MHz"            "2:1900 MHz (US)"         "3:1800 MHz"
    "5:850 MHz"              "7:2600 MHz"              "8:900 MHz"
    "12:700 MHz (US)"        "20:800 MHz (EU)"         "25:1900 MHz (US)"
    "28:700 MHz (APT)"       "38:2600 MHz (TDD)"       "40:2300 MHz (TDD)"
    "41:2500 MHz (TDD)"      "48:3600 MHz (CBRS, US)"  "66:1700/2100 MHz (AWS-3)"
    "71:600 MHz (US)"        "77:3300-4200 MHz (C-band, TDD)"
    "78:3300-3800 MHz (C-band, TDD — most common global mid-band 5G)"
    "79:4400-5000 MHz (TDD)"
)

# select_bands <title> <preselected_csv> <"code:desc" entry> ...
# Interactive checklist. Prints the chosen comma-separated band list to stdout
# (all UI goes to stderr so it's safe to capture with $(...)).
select_bands() {
    local title="$1" preselect="$2"; shift 2
    local -a entries=("$@")
    local -a codes=() descs=() selected=()
    local i entry code desc
    local _sel_input _manual _tok _t _idx

    for entry in "${entries[@]}"; do
        code="${entry%%:*}"; desc="${entry#*:}"
        codes+=("$code"); descs+=("$desc")
        if printf ',%s,' "$preselect" | grep -q ",$code,"; then
            selected+=(1)
        else
            selected+=(0)
        fi
    done

    while true; do
        printf "\n${BOLD}%s${NC}\n" "$title" >&2
        for i in "${!codes[@]}"; do
            if [ "${selected[$i]}" = "1" ]; then
                printf "  %2d) ${GREEN}[x]${NC} %-4s %s\n" "$((i+1))" "${codes[$i]}" "${descs[$i]}" >&2
            else
                printf "  %2d) [ ] %-4s %s\n" "$((i+1))" "${codes[$i]}" "${descs[$i]}" >&2
            fi
        done
        printf "\n  Enter numbers to toggle (e.g. 1 3 7), 'a'=all, 'n'=none,\n" >&2
        printf "  'm'=enter band numbers manually, 'd'=done: " >&2
        read -r _sel_input

        case "$_sel_input" in
            d|D|"")
                break
                ;;
            a|A)
                for i in "${!selected[@]}"; do selected[$i]=1; done
                ;;
            n|N)
                for i in "${!selected[@]}"; do selected[$i]=0; done
                ;;
            m|M)
                read -r -p "  Enter band numbers, comma-separated (e.g. 1,3,7,20): " _manual >&2
                _manual=$(printf '%s' "$_manual" | tr -d '[:space:]')
                if ! printf '%s' "$_manual" | grep -qE '^[0-9]{1,3}(,[0-9]{1,3})*$'; then
                    printf "  ${RED}Invalid format — expected comma-separated band numbers, each 1-3 digits (e.g. 1,3,7,20). Did the commas get dropped?${NC}\n" >&2
                    continue
                fi
                printf '%s\n' "$_manual"
                return 0
                ;;
            *)
                for _tok in $_sel_input; do
                    _tok="${_tok//,/ }"
                    for _t in $_tok; do
                        if [[ "$_t" =~ ^[0-9]+$ ]] && [ "$_t" -ge 1 ] 2>/dev/null && [ "$_t" -le "${#codes[@]}" ] 2>/dev/null; then
                            _idx=$((_t - 1))
                            if [ "${selected[$_idx]}" = "1" ]; then selected[$_idx]=0; else selected[$_idx]=1; fi
                        fi
                    done
                done
                ;;
        esac
    done

    local out=""
    for i in "${!codes[@]}"; do
        [ "${selected[$i]}" = "1" ] && out="${out}${codes[$i]},"
    done
    printf '%s\n' "${out%,}"
}

# --- ISP profile selection ---
msg "Select your ISP profile:"
printf "  ${BOLD}1)${NC} Odido NL       — LTE B1/3/7/32/38, NR5G n1/3/7/38/78\n"
printf "  ${BOLD}2)${NC} Free Mobile FR — LTE B1/3/7/8/28, NR5G n1/28/78\n"
printf "  ${BOLD}3)${NC} Custom         — pick your own bands from a list\n"
printf "\n  Choose [1]: "
read -r _PROFILE_CHOICE

case "${_PROFILE_CHOICE:-1}" in
    1|"")
        PROFILE="odido"
        PROFILE_NAME="Odido NL"
        MODEM_MODEL="UMBBE630"
        LTE_REQUIRED="1,3,7,32,38"
        NR5G_SA_REQUIRED="1,3,7,38,78"
        NR5G_NSA_REQUIRED="1,3,7,38,78"
        ;;
    2)
        PROFILE="freemobile"
        PROFILE_NAME="Free Mobile FR"
        MODEM_MODEL="UMBBE631"
        LTE_REQUIRED="1,3,7,8,28"
        NR5G_SA_REQUIRED="1,28,78"
        NR5G_NSA_REQUIRED="1,28,78"
        ;;
    3)
        PROFILE="custom"
        PROFILE_NAME="Custom"
        MODEM_MODEL="auto-detected"
        msg ""
        msg "Pick exactly the bands your ISP/SIM actually supports. Enabling a band"
        msg "your ISP doesn't provide is harmless but won't help; check your ISP's"
        msg "published FWA/CPE band spec if you're not sure."
        LTE_REQUIRED=$(select_bands "LTE bands" "" "${LTE_BAND_LIST[@]}")
        [ -z "$LTE_REQUIRED" ] && die "No LTE bands selected — at least one is required"
        ok "LTE bands: $LTE_REQUIRED"

        NR5G_SA_REQUIRED=$(select_bands "NR5G SA bands" "" "${NR_BAND_LIST[@]}")
        [ -z "$NR5G_SA_REQUIRED" ] && die "No NR5G SA bands selected — at least one is required"
        ok "NR5G SA bands: $NR5G_SA_REQUIRED"

        printf "\n  Use the same bands for NR5G NSA? [Y/n]: "
        read -r _same_nsa
        case "${_same_nsa:-Y}" in
            [Yy]|"") NR5G_NSA_REQUIRED="$NR5G_SA_REQUIRED" ;;
            *) NR5G_NSA_REQUIRED=$(select_bands "NR5G NSA bands" "$NR5G_SA_REQUIRED" "${NR_BAND_LIST[@]}") ;;
        esac
        [ -z "$NR5G_NSA_REQUIRED" ] && die "No NR5G NSA bands selected — at least one is required"
        ok "NR5G NSA bands: $NR5G_NSA_REQUIRED"
        ;;
    *)
        die "Invalid choice — run install.sh again"
        ;;
esac
ok "Profile: $PROFILE_NAME"
msg ""

# --- Prerequisite checks ---
[ "$(id -u)" -eq 0 ] || die "Must run as root"
command -v mongo   >/dev/null 2>&1 || die "mongo client not found"
command -v ssh     >/dev/null 2>&1 || die "ssh not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

if ! command -v sshpass >/dev/null 2>&1; then
    warn "sshpass not found — attempting install..."
    apt-get install -y sshpass 2>/dev/null || \
        die "sshpass not found and could not install it. Run: apt-get install sshpass"
fi

mkdir -p "$DATA_DIR"
touch "$DATA_DIR/.write_test" 2>/dev/null || die "Cannot write to $DATA_DIR (check /data mount)"
rm -f "$DATA_DIR/.write_test"

# --- Validate IP helper ---
validate_ip() {
    local ip="$1"
    echo "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || \
        die "Invalid IP address from MongoDB: '$ip'"
}

# --- Validate SSH username helper ---
validate_ssh_user() {
    local user="$1"
    echo "$user" | grep -qE '^[a-zA-Z0-9_-]{1,32}$' || \
        die "Invalid SSH username: '$user'"
}

# --- Retrieve SSH credentials from MongoDB ---
msg "Reading SSH credentials from UniFi MongoDB..."
SSH_USER=$(mongo --quiet localhost:27117/ace \
    --eval "print(db.setting.findOne({key:'mgmt'}).x_ssh_username)" < /dev/null 2>/dev/null | tr -d '\r\n') || true
SSH_PASS=$(mongo --quiet localhost:27117/ace \
    --eval "print(db.setting.findOne({key:'mgmt'}).x_ssh_password)" < /dev/null 2>/dev/null | tr -d '\r\n') || true

[ -z "$SSH_USER" ] || [ "$SSH_USER" = "null" ] && \
    die "Could not read SSH username from MongoDB. Is SSH enabled in UniFi Network?"
[ -z "$SSH_PASS" ] || [ "$SSH_PASS" = "null" ] && \
    die "Could not read SSH password from MongoDB"

# Validate SSH_USER
validate_ssh_user "$SSH_USER"
ok "SSH user: $SSH_USER"

# --- Detect U5G-Max IP ---
msg "Querying MongoDB for U5G-Max IP..."
U5G_IP=$(mongo --quiet localhost:27117/ace \
    --eval 'var d=db.device.findOne({model:/^UMBBE/}); print(d ? d.ip : "null")' < /dev/null 2>/dev/null | tr -d '\r\n') || true

[ -z "$U5G_IP" ] || [ "$U5G_IP" = "null" ] && \
    die "U5G-Max (UMBBE*) not found in MongoDB — is the modem adopted?"

validate_ip "$U5G_IP"
ok "U5G-Max IP: $U5G_IP"

# --- Generate SSH key ---
msg "Generating SSH key..."
if [ -f "$SSH_KEY" ]; then
    warn "SSH key already exists at $SSH_KEY — skipping keygen"
else
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q -C "u5gmax-bandfix@$(hostname)"
    ok "SSH key generated: $SSH_KEY"
fi
# Always enforce correct permissions
chmod 600 "$SSH_KEY"
chmod 644 "$SSH_KEY.pub"

# --- Scan host key into local known_hosts ---
msg "Scanning U5G-Max host key..."
ssh-keyscan -T 10 "$U5G_IP" > "$KNOWN_HOSTS" 2>/dev/null || \
    die "Could not reach $U5G_IP for host key scan — is the modem online?"
chmod 600 "$KNOWN_HOSTS"
ok "Host key stored: $KNOWN_HOSTS"

SSH_STRICT_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS"

# --- Copy SSH public key to U5G-Max ---
msg "Installing SSH public key on U5G-Max (${SSH_USER}@${U5G_IP})..."

if ssh $SSH_STRICT_OPTS "${SSH_USER}@${U5G_IP}" "exit 0" < /dev/null 2>/dev/null; then
    warn "SSH key already installed on U5G-Max — skipping"
else
    # Write password to temp file — avoids exposing it in the process list via -p
    mkdir -p "$_TMP_DIR"
    chmod 700 "$_TMP_DIR"
    _PASS_FILE=$(mktemp "$_TMP_DIR/.udm-sshpass-XXXXXX")
    chmod 600 "$_PASS_FILE"
    printf '%s' "$SSH_PASS" > "$_PASS_FILE"

    sshpass -f "$_PASS_FILE" ssh-copy-id \
        -i "$SSH_KEY.pub" \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o ConnectTimeout=10 \
        "${SSH_USER}@${U5G_IP}" < /dev/null 2>/dev/null || \
        die "ssh-copy-id failed — check password and connectivity to $U5G_IP"

    rm -f "$_PASS_FILE"; _PASS_FILE=""

    # Verify keyless SSH works
    ssh $SSH_STRICT_OPTS "${SSH_USER}@${U5G_IP}" "exit 0" < /dev/null || \
        die "Keyless SSH failed after key copy"

    ok "SSH key installed successfully"
fi

# --- Retrieve ICCID ---
msg "Reading ICCID from U5G-Max SIM..."
ICCID=$(printf '{"method":"get-sim-state"}' \
    | ssh $SSH_STRICT_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']['iccid'])" 2>/dev/null) || true

[ -z "$ICCID" ] && die "Could not read ICCID — SIM initialized? Try again in 2 minutes."

# Validate ICCID: must be 18-20 digits
echo "$ICCID" | grep -qE '^[0-9]{18,20}$' || die "Unexpected ICCID format: '$ICCID'"
ok "ICCID: $ICCID"

# --- Write config ---
msg "Writing config file..."
cat > "$CONFIG" << EOF
# u5gmax-bandfix config — written by install.sh $(date)
SSH_USER="$SSH_USER"
SSH_PASS="$SSH_PASS"
ICCID_CACHE="$ICCID"
PROFILE="$PROFILE"
PROFILE_NAME="$PROFILE_NAME"
MODEM_MODEL="$MODEM_MODEL"
LTE_REQUIRED="$LTE_REQUIRED"
NR5G_SA_REQUIRED="$NR5G_SA_REQUIRED"
NR5G_NSA_REQUIRED="$NR5G_NSA_REQUIRED"
EOF
chmod 600 "$CONFIG"
printf '%s\n' "$U5G_IP" > "$DATA_DIR/last_ip.txt"
ok "Config written: $CONFIG"

# --- Install band-fix.sh ---
msg "Installing band-fix.sh..."
SCRIPT_DEST="$DATA_DIR/band-fix.sh"
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd 2>/dev/null)" || INSTALLER_DIR=""
if [ -f "$INSTALLER_DIR/band-fix.sh" ]; then
    cp "$INSTALLER_DIR/band-fix.sh" "$SCRIPT_DEST"
elif command -v curl >/dev/null 2>&1; then
    curl -sSL "$SCRIPT_SRC" -o "$SCRIPT_DEST" || die "Download of band-fix.sh failed"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$SCRIPT_DEST" "$SCRIPT_SRC" || die "Download of band-fix.sh failed"
else
    die "Cannot install band-fix.sh — no curl/wget and not running from local repo"
fi
chmod +x "$SCRIPT_DEST"
ok "band-fix.sh installed: $SCRIPT_DEST"

# --- Install cron job ---
msg "Installing cron job..."
cat > "$CRON_FILE" << 'EOF'
# u5gmax-bandfix: ISP band enforcement for U5G-Max (profile: $PROFILE_NAME)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# On boot: poll until modem online, then apply fix (also restores this cron if wiped)
@reboot root /data/u5gmax-bandfix/on-boot.sh >> /data/u5gmax-bandfix/band-fix.log 2>&1
# Hourly check to catch controller-pushed band resets (offset 5min to avoid UniFi controller's own :00 MongoDB activity)
5 * * * * root /data/u5gmax-bandfix/band-fix.sh >> /data/u5gmax-bandfix/band-fix.log 2>&1
EOF
chmod 644 "$CRON_FILE"
ok "Cron job installed: $CRON_FILE (on-boot + hourly)"

# --- Install u5gmax-bandfix CLI command ---
msg "Installing u5gmax-bandfix command..."
CLI_DEST="/usr/local/sbin/u5gmax-bandfix"
CLI_SRC="https://raw.githubusercontent.com/royrijpma/u5gmax-bandfix/main/u5gmax-bandfix.sh"
if [ -f "$INSTALLER_DIR/u5gmax-bandfix.sh" ]; then
    cp "$INSTALLER_DIR/u5gmax-bandfix.sh" "$CLI_DEST"
elif command -v curl >/dev/null 2>&1; then
    curl -sSL "$CLI_SRC" -o "$CLI_DEST" || warn "Could not download u5gmax-bandfix.sh"
fi
[ -f "$CLI_DEST" ] && chmod +x "$CLI_DEST" && ok "CLI installed: type 'u5gmax-bandfix' to manage"

# --- Install on-boot.sh to /data/ ---
msg "Installing on-boot.sh..."
ON_BOOT_DEST="$DATA_DIR/on-boot.sh"
ON_BOOT_SRC_URL="https://raw.githubusercontent.com/royrijpma/u5gmax-bandfix/main/on-boot.sh"
if [ -f "$INSTALLER_DIR/on-boot.sh" ]; then
    cp "$INSTALLER_DIR/on-boot.sh" "$ON_BOOT_DEST"
elif command -v curl >/dev/null 2>&1; then
    curl -sSL "$ON_BOOT_SRC_URL" -o "$ON_BOOT_DEST" || warn "Could not download on-boot.sh"
fi
[ -f "$ON_BOOT_DEST" ] && chmod +x "$ON_BOOT_DEST" && ok "on-boot.sh installed: $ON_BOOT_DEST"

# --- Install uninstall.sh to /data/ ---
msg "Installing uninstall.sh..."
UNINSTALL_DEST="$DATA_DIR/uninstall.sh"
UNINSTALL_SRC_URL="https://raw.githubusercontent.com/royrijpma/u5gmax-bandfix/main/uninstall.sh"
if [ -f "$INSTALLER_DIR/uninstall.sh" ]; then
    cp "$INSTALLER_DIR/uninstall.sh" "$UNINSTALL_DEST"
elif command -v curl >/dev/null 2>&1; then
    curl -sSL "$UNINSTALL_SRC_URL" -o "$UNINSTALL_DEST" || warn "Could not download uninstall.sh"
fi
[ -f "$UNINSTALL_DEST" ] && chmod +x "$UNINSTALL_DEST" && ok "uninstall.sh installed: $UNINSTALL_DEST"

# --- Install reboot-modem.sh to /data/ ---
msg "Installing reboot-modem.sh..."
REBOOT_DEST="$DATA_DIR/reboot-modem.sh"
REBOOT_SRC_URL="https://raw.githubusercontent.com/royrijpma/u5gmax-bandfix/main/reboot-modem.sh"
if [ -f "$INSTALLER_DIR/reboot-modem.sh" ]; then
    cp "$INSTALLER_DIR/reboot-modem.sh" "$REBOOT_DEST"
elif command -v curl >/dev/null 2>&1; then
    curl -sSL "$REBOOT_SRC_URL" -o "$REBOOT_DEST" || warn "Could not download reboot-modem.sh"
fi
[ -f "$REBOOT_DEST" ] && chmod +x "$REBOOT_DEST" && ok "reboot-modem.sh installed: $REBOOT_DEST"

# --- Initial run ---
msg ""
msg "Running initial band fix..."
"$SCRIPT_DEST"

# --- Summary ---
printf '\n'
ok "u5gmax-bandfix installed!"
printf '\n'
printf '  Config:      %s\n' "$CONFIG"
printf '  Log file:    %s\n' "$LOG_FILE"
printf '  Cron:        on-boot (polls until modem ready) + hourly\n'
printf '  U5G-Max:     %s\n' "$U5G_IP"
printf '  ICCID:       %s\n' "$ICCID"
printf '\n'
printf 'Monitor:       tail -f %s\n' "$LOG_FILE"
printf 'Manual run:    %s\n' "$SCRIPT_DEST"
printf 'Uninstall:     bash /data/u5gmax-bandfix/uninstall.sh\n'
printf '\n'