#!/bin/bash
# u5gmax-bandfix uninstaller

set -euo pipefail

DATA_DIR="/data/u5gmax-bandfix"
CRON_FILE="/etc/cron.d/u5gmax-bandfix"
SSH_KEY="$DATA_DIR/id_ed25519"
KNOWN_HOSTS="$DATA_DIR/known_hosts"
CONFIG="$DATA_DIR/config"

[ "$(id -u)" -eq 0 ] || { echo "Must run as root" >&2; exit 1; }

echo "=== u5gmax-bandfix uninstaller ==="
echo ""

# --- Remove SSH key from U5G-Max (best-effort, do this BEFORE deleting the key) ---
if [ -f "$CONFIG" ] && [ -f "$SSH_KEY" ] && [ -f "$KNOWN_HOSTS" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG"
    U5G_IP=$(su - postgres -c "psql -p 5434 -d unifi-network -v ON_ERROR_STOP=1 -Atc \
        \"SELECT coalesce((SELECT ip FROM config.device WHERE model LIKE 'UMBBE%' AND ip IS NOT NULL ORDER BY last_seen DESC NULLS LAST LIMIT 1),'null')\"" \
        2>/dev/null | tr -d '\r\n') || true

    if [ -n "$U5G_IP" ] && [ "$U5G_IP" != "null" ] && \
       echo "$U5G_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        echo "Removing SSH key from U5G-Max ($U5G_IP)..."
        PUB_KEY=$(awk '{print $1, $2}' "$SSH_KEY.pub" 2>/dev/null) || true
        if [ -n "$PUB_KEY" ]; then
            # Write pub key to temp file to avoid shell quoting issues
            _TMP=$(mktemp /tmp/.udm-uninstall-XXXXXX)
            printf '%s\n' "$PUB_KEY" > "$_TMP"
            ssh -i "$SSH_KEY" \
                -o BatchMode=yes \
                -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=yes \
                -o UserKnownHostsFile="$KNOWN_HOSTS" \
                "${SSH_USER}@${U5G_IP}" \
                "grep -vxFf - ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp \
                 && mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys" \
                < "$_TMP" 2>/dev/null && echo "SSH key removed from U5G-Max" || \
                echo "Warning: could not remove key from U5G-Max (offline?)"
            rm -f "$_TMP"
        fi
    fi
fi

# --- Remove cron job ---
[ -f "$CRON_FILE" ] && rm -f "$CRON_FILE" && echo "Cron job removed"

# --- Remove CLI command ---
[ -f "/usr/local/sbin/u5gmax-bandfix" ] && rm -f "/usr/local/sbin/u5gmax-bandfix" && echo "CLI command removed"

# --- Remove data directory ---
[ -d "$DATA_DIR" ] && rm -rf "$DATA_DIR" && echo "Removed $DATA_DIR"

echo ""
echo "Done. u5gmax-bandfix uninstalled."
echo "Note: U5G-Max band configuration is NOT reverted — it will reset on next modem reboot."