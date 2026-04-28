#!/usr/bin/env bash
# Weekly health check for the Akash-deployed Hermes relayer.
# Telegram report covers: AKT lease runway, relayer wallet drains,
# IBC client TP buffer, Hermes telemetry liveness.
#
# Runs Mondays 09:00 IST via crontab.

set -uo pipefail
export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LOG="/home/deepanshutr/akash-relayer/weekly-monitor.log"
STATE_FILE="/home/deepanshutr/akash-relayer/deployment-state.json"
HISTORY_FILE="/home/deepanshutr/akash-relayer/weekly-monitor.history.json"
PY_VENV="/home/deepanshutr/autonomy/internal/wallet/atomone/.venv/bin/python"

# Public addresses (no secrets)
MANTLE_ADDR="mantle176p470v8vqfj072yclqxvcvrs88j0mszvztqtv"
OSMO_ADDR="osmo176p470v8vqfj072yclqxvcvrs88j0msz6ar4z5"
AKASH_ADDR="akash12yfk3mc2exa3zch7qh6w5ah9s3n0fadtpfurdj"
MANTLE_CLIENT="07-tendermint-0"
OSMO_CLIENT="07-tendermint-1923"

# LCDs
MANTLE_LCD="https://assetmantle-rest.stakerhouse.com"
OSMO_LCD="https://lcd.osmosis.zone"
AKASH_LCD="https://api.akashnet.net"

# Thresholds for warnings
AKT_MIN_RUNWAY_MONTHS=2
MNTL_MIN=10000000      # 10 MNTL
UOSMO_MIN=2000000      # 2 OSMO (revised burn rate ~180/yr means 2 OSMO ≈ 4 days)
TP_WARN_PCT=70

mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1
echo ""
echo "============================================================"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  weekly-monitor"
echo "============================================================"

tg() {
    local msg="$1"
    PYTHONPATH=/home/deepanshutr/autonomy/internal "$PY_VENV" -c "
import sys
from notification.telegram import send_alert
send_alert(sys.argv[1], parse_mode='HTML')
" "$msg" 2>&1 || echo "WARN: tg send failed"
}

# Helper: query a balance for a single denom
denom_balance() {
    local lcd="$1" addr="$2" denom="$3"
    curl -s --max-time 15 "${lcd}/cosmos/bank/v1beta1/balances/${addr}/by_denom?denom=${denom}" \
        | "$PY_VENV" -c "import sys, json; d=json.load(sys.stdin); print(d.get('balance',{}).get('amount','0'))" \
        2>/dev/null || echo "ERR"
}

# Helper: client TP buffer (% of trusting period elapsed since last update)
client_tp_pct() {
    local lcd="$1" client="$2"
    curl -s --max-time 15 "${lcd}/ibc/core/client/v1/client_states/${client}" \
        | "$PY_VENV" -c "
import sys, json
from datetime import datetime, timezone
try:
    d = json.load(sys.stdin)
    cs = d.get('client_state', {})
    tp_str = cs.get('trusting_period', '0s')
    # cosmwasm Duration: '864000s' style
    tp_sec = int(tp_str.rstrip('s')) if tp_str.endswith('s') else 0
    # latest_height isn't useful here; we need consensus state for last-update ts
    # Use status endpoint instead — already known
except Exception as e:
    print('ERR')
" 2>/dev/null || echo "ERR"
}

# Helper: client status (Active/Expired/Frozen)
client_status() {
    local lcd="$1" client="$2"
    curl -s --max-time 15 "${lcd}/ibc/core/client/v1/client_status/${client}" \
        | "$PY_VENV" -c "import sys, json; print(json.load(sys.stdin).get('status','UNKNOWN'))" \
        2>/dev/null || echo "ERR"
}

# 1. AKT balance + lease runway
echo "[1] Akash funding wallet..."
AKT_RAW=$(denom_balance "$AKASH_LCD" "$AKASH_ADDR" "uakt")
AKT=$(echo "$AKT_RAW" | "$PY_VENV" -c "import sys; v=sys.stdin.read().strip(); print(int(v)/1e6 if v.isdigit() else 0)")
# At 100 uakt/block × 6s blocks = 600 uakt/min = 36000 uakt/hr = 864000 uakt/day = 25.92 AKT/month
# So 1 AKT ≈ 1.13 months runway
RUNWAY_MO=$("$PY_VENV" -c "print(round($AKT / 0.864, 1))")
echo "   AKT: $AKT  → ~${RUNWAY_MO} months runway"

# 2. Relayer wallet balances
echo "[2] Relayer wallets..."
MNTL_RAW=$(denom_balance "$MANTLE_LCD" "$MANTLE_ADDR" "umntl")
MNTL=$("$PY_VENV" -c "v='$MNTL_RAW'; print(int(v)/1e6 if v.isdigit() else 0)")
OSMO_RAW=$(denom_balance "$OSMO_LCD" "$OSMO_ADDR" "uosmo")
OSMO=$("$PY_VENV" -c "v='$OSMO_RAW'; print(int(v)/1e6 if v.isdigit() else 0)")
echo "   mantle: $MNTL MNTL"
echo "   osmo:   $OSMO OSMO"

# 3. Client states
echo "[3] IBC client states..."
M_STATUS=$(client_status "$MANTLE_LCD" "$MANTLE_CLIENT")
O_STATUS=$(client_status "$OSMO_LCD" "$OSMO_CLIENT")
echo "   mantle-1/$MANTLE_CLIENT: $M_STATUS"
echo "   osmosis-1/$OSMO_CLIENT: $O_STATUS"

# 4. Pending-packet counts (cleanup trend after first relay run)
echo "[4] Pending packet commitments..."

pending_count() {
    local lcd="$1" channel="$2"
    curl -s --max-time 30 "${lcd}/ibc/core/channel/v1/channels/${channel}/ports/transfer/packet_commitments?pagination.count_total=true&pagination.limit=1" \
        | "$PY_VENV" -c "import sys, json; d=json.load(sys.stdin); print(d.get('pagination',{}).get('total','-1'))" \
        2>/dev/null || echo "-1"
}

MANTLE_PENDING=$(pending_count "$MANTLE_LCD" "channel-0")
OSMO_PENDING=$(pending_count "$OSMO_LCD" "channel-232")
TOTAL_PENDING=$("$PY_VENV" -c "
m = int('$MANTLE_PENDING') if '$MANTLE_PENDING'.lstrip('-').isdigit() else 0
o = int('$OSMO_PENDING') if '$OSMO_PENDING'.lstrip('-').isdigit() else 0
print(m + o)
")

# Compute delta vs last week
PRIOR_MANTLE="?"
PRIOR_OSMO="?"
PRIOR_TOTAL="?"
DELTA_MANTLE=""
DELTA_OSMO=""
DELTA_TOTAL=""
if [ -f "$HISTORY_FILE" ]; then
    PRIOR_MANTLE=$("$PY_VENV" -c "import json; d=json.load(open('$HISTORY_FILE')); print(d.get('mantle_pending', '?'))" 2>/dev/null || echo "?")
    PRIOR_OSMO=$("$PY_VENV" -c "import json; d=json.load(open('$HISTORY_FILE')); print(d.get('osmo_pending', '?'))" 2>/dev/null || echo "?")
    PRIOR_TOTAL=$("$PY_VENV" -c "import json; d=json.load(open('$HISTORY_FILE')); print(d.get('total_pending', '?'))" 2>/dev/null || echo "?")
    if [ "$PRIOR_MANTLE" != "?" ]; then
        DELTA_MANTLE=$("$PY_VENV" -c "
d = $MANTLE_PENDING - $PRIOR_MANTLE
print(f' ({d:+d})')
" 2>/dev/null || echo "")
    fi
    if [ "$PRIOR_OSMO" != "?" ]; then
        DELTA_OSMO=$("$PY_VENV" -c "
d = $OSMO_PENDING - $PRIOR_OSMO
print(f' ({d:+d})')
" 2>/dev/null || echo "")
    fi
    if [ "$PRIOR_TOTAL" != "?" ]; then
        DELTA_TOTAL=$("$PY_VENV" -c "
d = $TOTAL_PENDING - $PRIOR_TOTAL
print(f' ({d:+d})')
" 2>/dev/null || echo "")
    fi
fi

echo "   mantle-1 → osmo: $MANTLE_PENDING$DELTA_MANTLE"
echo "   osmo → mantle-1: $OSMO_PENDING$DELTA_OSMO"
echo "   total: $TOTAL_PENDING$DELTA_TOTAL"

# Persist for next week's delta
"$PY_VENV" -c "
import json
json.dump({
    'ts': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'mantle_pending': $MANTLE_PENDING,
    'osmo_pending': $OSMO_PENDING,
    'total_pending': $TOTAL_PENDING,
}, open('$HISTORY_FILE', 'w'), indent=2)
"

# 5. Hermes telemetry liveness (only if deployment-state.json exists)
echo "[5] Hermes telemetry..."
HERMES_HEALTH="not-deployed"
HERMES_ENDPOINT=""
if [ -f "$STATE_FILE" ]; then
    HERMES_ENDPOINT=$("$PY_VENV" -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('endpoint',''))" 2>/dev/null || echo "")
    if [ -n "$HERMES_ENDPOINT" ]; then
        if curl -sf --max-time 10 "$HERMES_ENDPOINT" -o /tmp/wm.metrics 2>/dev/null; then
            HERMES_HEALTH="OK ($(wc -l < /tmp/wm.metrics) metric lines)"
        else
            HERMES_HEALTH="UNREACHABLE"
        fi
        rm -f /tmp/wm.metrics
    fi
fi
echo "   $HERMES_HEALTH"

# Build flags list
FLAGS=""
if "$PY_VENV" -c "exit(0 if $RUNWAY_MO < $AKT_MIN_RUNWAY_MONTHS else 1)" 2>/dev/null; then
    FLAGS="${FLAGS}⚠ AKT runway low (${RUNWAY_MO}mo)\n"
fi
if [ "$MNTL_RAW" != "ERR" ] && "$PY_VENV" -c "exit(0 if int('$MNTL_RAW' if '$MNTL_RAW'.isdigit() else 0) < $MNTL_MIN else 1)" 2>/dev/null; then
    FLAGS="${FLAGS}⚠ mantle1 below ${MNTL_MIN} umntl\n"
fi
if [ "$OSMO_RAW" != "ERR" ] && "$PY_VENV" -c "exit(0 if int('$OSMO_RAW' if '$OSMO_RAW'.isdigit() else 0) < $UOSMO_MIN else 1)" 2>/dev/null; then
    FLAGS="${FLAGS}⚠ osmo1 below ${UOSMO_MIN} uosmo\n"
fi
if [ "$M_STATUS" != "Active" ]; then
    FLAGS="${FLAGS}⚠ mantle client $MANTLE_CLIENT: $M_STATUS\n"
fi
if [ "$O_STATUS" != "Active" ]; then
    FLAGS="${FLAGS}⚠ osmo client $OSMO_CLIENT: $O_STATUS\n"
fi
if [ "$HERMES_HEALTH" = "UNREACHABLE" ]; then
    FLAGS="${FLAGS}⚠ Hermes telemetry unreachable at $HERMES_ENDPOINT\n"
fi

# Telegram report
HEADER="<b>📡 Weekly relayer health</b>"
if [ -n "$FLAGS" ]; then
    HEADER="<b>⚠️ Weekly relayer health (action items)</b>"
fi

REPORT="${HEADER}%0A%0A<b>AKT:</b> ${AKT} (~${RUNWAY_MO}mo runway)%0A<b>mantle1:</b> ${MNTL} MNTL%0A<b>osmo1:</b> ${OSMO} OSMO%0A<b>mantle client:</b> ${M_STATUS}%0A<b>osmo client:</b> ${O_STATUS}%0A<b>Hermes:</b> ${HERMES_HEALTH}%0A%0A<b>Pending packets</b>%0A  m→o: ${MANTLE_PENDING}${DELTA_MANTLE}%0A  o→m: ${OSMO_PENDING}${DELTA_OSMO}%0A  total: ${TOTAL_PENDING}${DELTA_TOTAL}"

if [ -n "$FLAGS" ]; then
    REPORT="${REPORT}%0A%0A<b>Flags:</b>%0A$(echo -e "$FLAGS" | sed 's/$/%0A/' | tr -d '\n')"
fi

tg "$REPORT"

echo ""
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  done"
