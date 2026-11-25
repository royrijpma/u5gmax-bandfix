#!/bin/bash
# udm-audit.sh — Code audit agent voor udm-bandfix
# Volledig via Ollama — geen Claude tokens.
#
# Gebruik:
#   ./udm-audit.sh              # alle audits
#   ./udm-audit.sh --security   # alleen security
#   ./udm-audit.sh --code       # alleen code kwaliteit
#   ./udm-audit.sh --qa         # alleen QA / edge cases

set -euo pipefail

MODEL="gemma4:31b-cloud"
OLLAMA_URL="http://localhost:11434/api/generate"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT_FILE="$PROJECT_DIR/audit-report-$(date +%Y-%m-%d).md"

RUN_ALL=true
RUN_SECURITY=false; RUN_CODE=false; RUN_QA=false

for arg in "$@"; do
    RUN_ALL=false
    case "$arg" in
        --security) RUN_SECURITY=true ;;
        --code)     RUN_CODE=true ;;
        --qa)       RUN_QA=true ;;
        --all)      RUN_ALL=true ;;
    esac
done

if $RUN_ALL; then
    RUN_SECURITY=true; RUN_CODE=true; RUN_QA=true
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
ask_ollama() {
    local model="$1"
    local prompt="$2"
    local tmpfile
    tmpfile=$(mktemp /tmp/udm-audit-XXXXXX.json)

    python3 - "$tmpfile" "$model" "$prompt" << 'PYEOF'
import json, sys
tmpfile = sys.argv[1]
model   = sys.argv[2]
prompt  = sys.argv[3]
payload = {
    "model": model,
    "prompt": prompt,
    "stream": True,
    "options": {"num_ctx": 16384}
}
with open(tmpfile, 'w') as f:
    json.dump(payload, f)
PYEOF

    curl -s --max-time 300 "$OLLAMA_URL" \
        -H "Content-Type: application/json" \
        -d @"$tmpfile" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if line:
        try:
            d = json.loads(line)
            if 'response' in d:
                print(d['response'], end='', flush=True)
        except: pass
print()
"
    rm -f "$tmpfile"
}

read_file() {
    local f="$1"
    if [ -f "$f" ]; then
        echo "=== $(basename "$f") ==="
        cat "$f"
        echo ""
    fi
}

section() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔍 $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Report header ─────────────────────────────────────────────────────────────
{
echo "# udm-bandfix Audit Report"
echo "> Datum: $(date '+%Y-%m-%d %H:%M')"
echo "> Model: $MODEL"
echo "> Geen Claude tokens gebruikt."
echo ""
echo "---"
} > "$REPORT_FILE"

echo "📋 udm-bandfix Audit Agent"
echo "   Model:  $MODEL"
echo "   Report: $REPORT_FILE"
echo ""

# Laad de scripts eenmalig in
BAND_FIX=$(read_file "$PROJECT_DIR/src/band-fix.sh")
INSTALL=$(read_file "$PROJECT_DIR/install.sh")
UNINSTALL=$(read_file "$PROJECT_DIR/uninstall.sh")
ALL_CODE="$BAND_FIX
$INSTALL
$UNINSTALL"

# ── Security Audit ────────────────────────────────────────────────────────────
if $RUN_SECURITY; then
    section "Security Audit"

    PROMPT="Je bent een security auditor gespecialiseerd in shell scripts en embedded Linux.
Analyseer de volgende bash scripts van udm-bandfix — een tool die via SSH op een UniFi U5G-Max modem bandinstellingen beheert.

Context:
- Draait als root op een UniFi Cloud Gateway
- Verbindt via SSH (key-based) met de U5G-Max modem
- Leest credentials (SSH user/password) uit de UniFi Network PostgreSQL-database
- ICCID van de SIM wordt gecached in een config file

Zoek naar:
- Command injection risico's (variabelen in SSH commando's, psql queries, printf)
- Credential handling (wordt het SSH wachtwoord ooit gelogd of opgeslagen?)
- SSH key beveiliging (permissions, StrictHostKeyChecking)
- Privilege escalation (draait als root, welke aanvalsoppervlakken?)
- Log injection (kan een kwaadaardige IP/ICCID de log bevuilen?)
- Race conditions in PID file handling
- Onveilige temp files

CODE:
$ALL_CODE

Geef maximaal 10 bevindingen als: KRITIEK / HOOG / MEDIUM / LAAG met uitleg en concrete fix."

    echo "## Security Audit" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    RESULT=$(ask_ollama "$MODEL" "$PROMPT")
    echo "$RESULT"
    echo "$RESULT" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
fi

# ── Code Audit ────────────────────────────────────────────────────────────────
if $RUN_CODE; then
    section "Code Audit"

    PROMPT="Je bent een bash/shell script expert. Doe een grondige code review van deze scripts.

Context: udm-bandfix — beheert LTE/NR5G bandinstellingen op een UniFi U5G-Max modem via SSH vanuit een Cloud Gateway.

Zoek naar:
- Bash best practices: quoting, set -euo pipefail, shellcheck issues
- Foutafhandeling: worden alle exit codes gecheckt?
- Robuustheid: wat als psql/postgres niet reageert, SSH faalt, ubus een onverwacht format teruggeeft?
- Portabiliteit: werkt het op BusyBox/ash als bash niet beschikbaar is?
- Idempotentie: is het veilig om meerdere keren te draaien?
- Hardcoded waarden die beter in de config zouden zitten
- Logging kwaliteit: is het duidelijk wat er mis ging bij een fout?
- Overbodige of ontbrekende stappen in install.sh

CODE:
$ALL_CODE

Geef maximaal 8 bevindingen met ernst (HOOG/MEDIUM/LAAG) en concrete refactor-suggestie."

    echo "## Code Audit" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    RESULT=$(ask_ollama "$MODEL" "$PROMPT")
    echo "$RESULT"
    echo "$RESULT" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
fi

# ── QA / Edge Cases ───────────────────────────────────────────────────────────
if $RUN_QA; then
    section "QA / Edge Cases"

    PROMPT="Je bent een QA engineer die edge cases test voor embedded Linux shell scripts.

Context: udm-bandfix draait elk uur als cronjob op een UniFi Cloud Gateway.
Het verbindt via SSH met een U5G-Max 5G-modem om bandinstellingen te handhaven.

Analyseer de volgende scripts op:
- Wat gebeurt er bij een reboot van de modem halverwege een fix?
- Wat als de U5G-Max een andere firmware heeft die get-radio-pref anders formatteert?
- Wat als de ICCID verandert (bijv. na SIM-swap)?
- Wat als de PostgreSQL-database tijdelijk down is?
- Wat als de crontab verdwijnt na een firmware-update van de Cloud Gateway?
- Wat als de SSH key op de modem verdwijnt (firmware-update wist /root/.ssh/)?
- Wat als het /data/ volume vol raakt door logs?
- Concurrency: twee cronjobs die tegelijk draaien?
- Wat als sshpass niet beschikbaar is op de Cloud Gateway?
- Wat als de database-query 'null' teruggeeft (device niet adopted)?

CODE:
$ALL_CODE

Geef per scenario: wat er misgaat, of het script dit al afhandelt, en wat de aanbevolen fix is.
Ernst: HOOG (gebruiker heeft geen internet) / MEDIUM (fix mislukt stil) / LAAG (cosmetic)."

    echo "## QA / Edge Cases" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    RESULT=$(ask_ollama "$MODEL" "$PROMPT")
    echo "$RESULT"
    echo "$RESULT" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
fi

# ── Samenvatting ──────────────────────────────────────────────────────────────
section "Samenvatting"

REPORT_CONTENT=$(cat "$REPORT_FILE")
SUMMARY_PROMPT="Maak een beknopte samenvatting (max 200 woorden) van dit audit rapport voor udm-bandfix.
Geef: totaal bevindingen per ernst, top 3 meest kritieke acties die de auteur moet ondernemen.

RAPPORT:
$REPORT_CONTENT"

echo "## Samenvatting" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
SUMMARY=$(ask_ollama "$MODEL" "$SUMMARY_PROMPT")
echo "$SUMMARY"
echo "$SUMMARY" >> "$REPORT_FILE"

echo ""
echo "✅ Audit klaar. Report: $REPORT_FILE"
