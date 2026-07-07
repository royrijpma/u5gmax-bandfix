# u5gmax-bandfix

Automatically enforce ISP band restrictions on the UniFi U5G-Max modem — persistently, from the Cloud Gateway.

Supports **Odido NL** and **Free Mobile FR** out of the box. Switching profiles takes one command.

The modem is detected automatically by searching for any `UMBBE*` model in MongoDB — works regardless of hardware revision (UMBBE630, UMBBE631, or future variants).

> Inspired by [udm-iptv](https://github.com/fabianishere/udm-iptv)

---

## Changelog

### v1.3.2 (2026-07-07)
- **Live serving band & signal in the CLI header**: a new `Signal:` line shows the modem's actual current LTE/NR5G band(s) and signal quality (e.g. `5G n78+n1, LTE B3 · 85% (Good)`), sourced from `get-radio-status` (fields previously unused: `mode`, `ca-lte`, `ca-nr`, `signal-percent`, `signal`). This is the band the modem is actually camping on right now, as distinct from the *allowed* band list shown by "Show current band status". Fetched once when the interactive menu starts (not on every redraw) to avoid adding cellular-link latency to every keypress.

### v1.3.1 (2026-07-03)
- **Odido NL profile: added LTE Band 32** (SDL, 1500 MHz carrier aggregation layer). `LTE_REQUIRED` is now `1,3,7,32,38`. No NR5G equivalent is required — `NR5G_SA_REQUIRED`/`NR5G_NSA_REQUIRED` remain `1,3,7,38,78`.

### v1.3.0 (2026-07-01)
- **Scheduled one-time or daily modem reboot** (menu option 8): schedule the U5G-Max to reboot at a specific time, once or every 24h. After the reboot, band-fix runs automatically. See [Scheduling a Modem Reboot](#scheduling-a-modem-reboot) for why this is useful.

### v1.2.0 (2026-06-24)
- **Multi-ISP profile support**: install.sh asks which ISP during setup; profile is stored in config and used by all scripts
- **Supported profiles**: Odido NL and Free Mobile FR
- **Automatic modem detection**: U5G-Max detected by `UMBBE*` model prefix — works for all hardware revisions
- **Switch ISP profile**: option 3 in the interactive menu, or `u5gmax-bandfix profile` from the shell
- **Backwards compatible**: existing installs without a profile in config default to Odido NL automatically

### v1.1.0 (2026-06-20)
- **Self-healing after modem reboot**: automatically rescans host key and reinstalls SSH key when modem tmpfs is wiped
- **IP change recovery**: polls MongoDB for updated IP when SSH fails, handles WAN IP changes on reboot
- **Interactive CLI** (`u5gmax-bandfix`): menu with force check, band status, profile switch, logs, key reinstall, update, uninstall
- **Band status with fix prompt**: option 2 detects non-compliant bands and offers to fix immediately
- **Auto-update**: option 6 downloads latest scripts from GitHub and exits cleanly
- **CLI auto-restore after firmware update**: `on-boot.sh` restores `/usr/local/sbin/u5gmax-bandfix` from local `/data/` copy if wiped by a UniFi OS update
- **WCDMA excluded via mode lock**: radio preference is forced to `5gnr,lte` — WCDMA/3G is disabled at the modem level, not just detected at runtime
- **WCDMA recovery**: detects 3G fallback and forces reregistration to 4G/5G (failsafe if modem ignores the mode lock)

### v1.0.0 (2026-06-16)
- Initial release: hourly cron enforcement of Odido NL band spec on UCG Fiber
- Automated install via MongoDB credential lookup
- SSH key-based auth, log rotation, singleton lock

---

## The Problem

ISPs that offer FWA (Fixed Wireless Access) over 5G publish a hardware specification that defines exactly which bands must be **active** and which must be permanently **disabled**. The U5G-Max supports band selection via `uiwwand-ctl` over SSH, but:

- The UniFi controller intentionally does not expose band steering or band locking options for the U5G-Max — Ubiquiti has stated this is by design, as band selection is considered a carrier-managed setting, not an end-user setting.
- On every adoption or reconfiguration event, the UniFi controller pushes a full radio config to the modem that resets all band selections back to default (all bands enabled). This happens silently in the background.
- The modem API (`uiwwand-ctl`) does support `set-radio-pref`, but this interface is undocumented and not exposed through the UniFi UI.
- Community requests for band locking in the UniFi forum have been open since 2022 without a committed fix.
- The U5G-Max runs on tmpfs — any config written to it is lost on reboot, and the `/etc/persistent/cfg/` partition has only ~100 bytes free — too small for scripts.

**Result**: every time the Cloud Gateway or U5G-Max reboots, all bands come back and your ISP connection stops working until the bands are manually reset.

## ISP Profiles

### Odido NL

| Radio | Required active bands | Must be disabled |
|-------|----------------------|-----------------|
| LTE (FDD) | B1, B3, B7 | B8, B20, B28 |
| LTE (TDD) | B38 | — |
| LTE (SDL) | B32 | — |
| NR5G SA/NSA (FDD) | n1, n3, n7 | n8, n20, n28 |
| NR5G SA/NSA (TDD) | n38, n78 | — |

*Source: [Odido 5G Internet hardware specificaties en voorwaarden](https://assets.odido.nl/x/f4aba6813e/5g-internet-hardware-specificaties-voorwaarden.pdf) (3GPP Release 16)*

> **Note (v1.3.1):** B32 (Supplemental Downlink, LTE carrier aggregation only) was added to the enforced LTE band set — confirmed usable on Odido NL as of 2026-07-03. It is not listed in the hardware-spec PDF above; verify against your own account/modem if you rely on this. No NR5G equivalent is enforced for B32.

### Free Mobile FR

| Radio | Required active bands | Must be disabled |
|-------|----------------------|-----------------|
| LTE (FDD) | B1, B3, B7, B8, B28 | B20, B38 |
| NR5G SA/NSA (FDD) | n1, n28 | n3, n7, n8, n20, n38 |
| NR5G SA/NSA (TDD) | n78 | — |

*Source: [Free Mobile France spectrum allocation](https://www.spectrum-tracker.com/France/Free-Mobile) (ARCEP licensed bands). No official FWA hardware spec document published by Free Mobile.*

---

## WCDMA Recovery

Sometimes the U5G-Max gets stuck on 3G (WCDMA/UMTS) even when 4G/5G coverage is available. This happens after reboots or when the controller pushes a config reset that disrupts the active radio mode. u5gmax-bandfix detects this automatically via `get-radio-status` on every run. If WCDMA is detected, it sends a mode override (`5gnr,lte`) to kick the modem back to 4G/5G, waits 60 seconds for reregistration, then checks if it succeeded. If the modem is still on WCDMA after 60s, the band fix is skipped for that run and the cron will retry the next hour — this prevents hammering the modem with repeated resets. The event is logged as `"WCDMA detected — forcing reregistration"` in the log file.

## How it Works

u5gmax-bandfix runs as a cron job **on the Cloud Gateway** (not on the modem). Every hour it:

1. Looks up the current U5G-Max IP in the UniFi MongoDB database (the IP is a dynamic public 5G WAN address that changes on reboot)
2. Connects over SSH using a persistent key pair stored in `/data/`
3. Reads the current band config via `uiwwand-ctl`
4. Compares it against the ISP profile spec stored in config
5. If it doesn't match → applies the correct configuration
6. Verifies the result and logs everything to `/data/u5gmax-bandfix/band-fix.log`

```
Cloud Gateway (/data/ persistent)
│
├── id_ed25519         SSH private key
├── config             SSH user, ICCID, ISP profile + bands
├── band-fix.sh        Runs hourly via cron
└── band-fix.log       Audit log
         │
         │ SSH (key-based, no password)
         ▼
U5G-Max (any UMBBE* model — auto-detected)
│
└── uiwwand-ctl        Band configuration tool
```

The ICCID of the active SIM is required by `uiwwand-ctl set-radio-pref`. It's read live from the modem on every run and cached in config as a fallback.

## Tested Environment

| Component | Version |
|-----------|---------|
| Cloud Gateway Fiber firmware | v5.1.19 |
| U5G-Max firmware | 7.4.1.19032 |
| UniFi Network | 10.4.57 |
| ISP | Odido 5G Internet (FWA, NL) |

## Requirements

- UniFi Cloud Gateway (UDM Pro, UDM SE, or Cloud Gateway Fiber)
- U5G-Max (any `UMBBE*` model) adopted in UniFi Network — detected automatically
- SSH enabled in **UniFi Network → Settings → Advanced → SSH**
- `sshpass` available on the Cloud Gateway (for one-time key install)
- `python3` available on the Cloud Gateway (for JSON parsing)

## Installation

```bash
curl -sSL https://raw.githubusercontent.com/royrijpma/u5gmax-bandfix/main/install.sh | bash
```

Run as root on the Cloud Gateway. The installer will:

1. **Ask which ISP profile** to use (Odido NL or Free Mobile FR)
2. Read the SSH username and password from MongoDB (no manual input needed)
3. Detect the U5G-Max IP from MongoDB
4. Generate an SSH key pair at `/data/u5gmax-bandfix/id_ed25519`
5. Copy the public key to the U5G-Max (uses the MongoDB password — one time only)
6. Read the SIM ICCID from the modem and cache it
7. Install `/data/u5gmax-bandfix/band-fix.sh`
8. Create `/etc/cron.d/u5gmax-bandfix` (runs hourly)
9. Apply the fix immediately and show the result

### Local install (from cloned repo)

```bash
git clone https://github.com/royrijpma/u5gmax-bandfix
cd u5gmax-bandfix
bash install.sh
```

## Usage

After installation, type `u5gmax-bandfix` in the shell to open the interactive menu:

```
╔══════════════════════════════════════════════╗
║            u5gmax-bandfix  v1.2.0            ║
║   Odido NL — UniFi U5G-Max                   ║
╠══════════════════════════════════════════════╣
  U5G-Max IP:  178.x.x.x
  Cron:        active (hourly at :05)
  Last run:    2026-06-24 09:05:01
  Result:      ✓ Odido NL-compliant
╠══════════════════════════════════════════════╣
  1) Force band check now
  2) Show current band status
  3) Switch ISP profile
  4) Show logs
  5) Reinstall SSH key on U5G-Max
  6) Update to latest version
  7) Uninstall
  0) Exit
╚══════════════════════════════════════════════╝
```

You can also run commands directly from the shell without the menu:

```bash
u5gmax-bandfix check      # force band check
u5gmax-bandfix status     # show band status
u5gmax-bandfix profile    # switch ISP profile
u5gmax-bandfix logs       # show logs
u5gmax-bandfix update     # update to latest version
u5gmax-bandfix uninstall  # uninstall
```

### Switching ISP profile

Use option 3 in the menu or `u5gmax-bandfix profile` from the shell. The profile selection updates the config and optionally runs a band check immediately.

### Self-healing after modem reboot

After a modem reboot, the U5G-Max loses its SSH keys and host keys (tmpfs). The tool recovers automatically:

1. **Cron** (band-fix.sh): detects SSH failure → rescans host key → reinstalls SSH key via sshpass → applies band fix
2. **CLI** (option 2): detects SSH failure → rescans host key → reinstalls SSH key → shows band status with option to fix immediately

If bands are non-compliant, option 2 asks:
```
Bands are non-compliant. Apply <ISP profile> fix now? [Y/n]
```

### Scheduling a Modem Reboot

**Menu option 8 — Schedule one-time reboot** (new in v1.3.0)

Some FWA ISPs renew your public IP address every 24 hours at the exact time you first activated your connection. If you activated at 20:00, your IP changes every night at 20:00 — causing a 2–3 minute connection drop at that time, every day.

By scheduling a one-time reboot of the U5G-Max just before or at a convenient low-traffic time (e.g. 04:00), the modem re-registers with the network and the 24-hour IP renewal cycle resets to that new time. After the one-time reboot, future IP renewals happen at 04:00 instead of 20:00 — while you're asleep.

After the scheduled reboot, `reboot-modem.sh` automatically:
1. Waits for the modem to come back online (boot takes ~5 minutes)
2. Runs a band-fix to re-apply your ISP's band configuration

To schedule a reboot, use option 8 in the menu or:

```bash
u5gmax-bandfix reboot-schedule
```

The time you enter is in your **local system timezone** (shown on screen). A one-time schedule removes itself after executing — no cleanup needed.

### Check logs

```bash
tail -f /data/u5gmax-bandfix/band-fix.log
```

### Run manually

```bash
/data/u5gmax-bandfix/band-fix.sh
```

### Verify band configuration on the modem

```bash
# From the Cloud Gateway
ICCID=$(grep ICCID_CACHE /data/u5gmax-bandfix/config | cut -d'"' -f2)
U5G_IP=$(mongo --quiet localhost:27117/ace --eval 'var d=db.device.findOne({model:/^UMBBE/}); print(d ? d.ip : "null")')
SSH_USER=$(grep SSH_USER /data/u5gmax-bandfix/config | cut -d'"' -f2)
printf '{"method":"get-radio-pref","params":{"iccid":"%s"}}' "$ICCID" \
  | ssh -i /data/u5gmax-bandfix/id_ed25519 "${SSH_USER}@${U5G_IP}" uiwwand-ctl
```

Expected output (Odido NL-compliant):

```json
{"result":{"net_sel_pref":"automatic","mode":"5gnr,lte","lte_band":"1,3,7,32,38","nr5g_sa_band":"1,3,7,38,78","nr5g_nsa_band":"1,3,7,38,78"}}
```

## Uninstall

```bash
bash /data/u5gmax-bandfix/uninstall.sh
```

This removes the cron job, all files in `/data/u5gmax-bandfix/`, and the SSH key from the modem. It does **not** revert the band configuration — it will reset to "all" on the next modem reboot anyway.

## Security

- SSH uses ed25519 key-based auth only — no passwords used after install
- The MongoDB SSH password is cached in `/data/u5gmax-bandfix/config` (mode `600`, root-only) to enable self-healing after modem reboots without requiring MongoDB access
- All files in `/data/u5gmax-bandfix/` are root-only (chmod 600 for config and key)
- The fix only runs read/write over SSH — no arbitrary code execution on the modem
- All external input (SSH_USER from MongoDB, IP, ICCID) is strictly validated with regex before use — e.g., `SSH_USER` must match `^[a-zA-Z0-9_-]{1,32}$` or the script aborts
- All values retrieved from the modem are sanitized (stripped of non-printable characters) before logging or further processing
- Temporary files in `band-fix.sh` are created in `/data/u5gmax-bandfix/tmp/` (mode `700`, root-only); short-lived CLI tempfiles use `/tmp/` and are removed immediately after use
- `known_hosts` updates are atomic: written to a `.tmp` file and moved into place, eliminating race-condition risks
- Fully POSIX-compliant: avoids bash-specific constructs like `[[ =~ ]]` for compatibility with `/bin/sh`

## License

MIT — see [LICENSE](LICENSE)

## Built with AI

This tool was entirely vibe-coded with [Claude](https://claude.ai) — from architecture to debugging the UCG Fiber cron environment quirks. Every script, fix, and edge case was developed through conversation.

---

*Not affiliated with Ubiquiti, Odido, or Free Mobile. Use at your own risk.*  
*Band specifications: Odido 5G Internet hardware specificaties en voorwaarden · Free Mobile FWA documentation (3GPP Release 16).*
