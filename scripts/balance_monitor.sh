#!/usr/bin/env bash
# 6-hourly balance monitor for the relayer wallets (mantle1 / osmo1 / akash1).
#
# Cron: `0 */6 * * *  /home/deepanshutr/akash-relayer/scripts/balance_monitor.sh`
#
# Why separate from weekly-monitor.sh:
#   - weekly runs Monday only; a sudden drain (mempool spam, rogue tx) can
#     bleed gas reserves to zero in <12h and leave the relayer dead until
#     next Monday's report.
#   - 6h cadence catches drain-rate spikes within one report cycle.
#   - 12h dedup state (~/akash-relayer/balance-monitor.state.json) prevents
#     repeated alerts when a balance has crossed the threshold but not
#     recovered yet (avoid Telegram spam during a multi-day low-balance
#     window).
#
# Reuses denom_balance, tg, and threshold constants conceptually from
# weekly-monitor.sh; we copy rather than source to keep that script's
# behavior frozen (it's the canonical Monday report).
#
# `--dry-run` flag (any arg) skips the Telegram send and just prints to
# stdout for ad-hoc invocation / testing.

set -uo pipefail
export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

LOG="/home/deepanshutr/akash-relayer/balance-monitor.log"
STATE_FILE="/home/deepanshutr/akash-relayer/balance-monitor.state.json"
PY_VENV="/home/deepanshutr/autonomy/internal/wallet/atomone/.venv/bin/python"

# Public addresses (no secrets) — same as weekly-monitor.sh
MANTLE_ADDR="mantle176p470v8vqfj072yclqxvcvrs88j0mszvztqtv"
OSMO_ADDR="osmo176p470v8vqfj072yclqxvcvrs88j0msz6ar4z5"
AKASH_ADDR="akash12yfk3mc2exa3zch7qh6w5ah9s3n0fadtpfurdj"

# LCDs
MANTLE_LCD="https://rest.assetmantle.one"
OSMO_LCD="https://lcd.osmosis.zone"
AKASH_LCD="https://api.akashnet.net"

# Thresholds (same as weekly-monitor.sh)
AKT_MIN_RUNWAY_MONTHS=2
MNTL_MIN=10000000      # 10 MNTL in umntl
UOSMO_MIN=2000000      # 2 OSMO in uosmo
DEDUP_HOURS=12         # don't re-alert on the same flag within 12h

mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1
echo ""
echo "============================================================"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  balance-monitor (dry_run=$DRY_RUN)"
echo "============================================================"

tg() {
    local msg="$1"
    if [ "$DRY_RUN" = "1" ]; then
        echo "DRY-RUN tg payload:"
        echo "$msg"
        return 0
    fi
    PYTHONPATH=/home/deepanshutr/autonomy/internal "$PY_VENV" -c "
import sys
from notification.telegram import send_alert
send_alert(sys.argv[1], parse_mode='HTML')
" "$msg" 2>&1 || echo "WARN: tg send failed"
}

denom_balance() {
    local lcd="$1" addr="$2" denom="$3"
    curl -s --max-time 15 "${lcd}/cosmos/bank/v1beta1/balances/${addr}/by_denom?denom=${denom}" \
        | "$PY_VENV" -c "import sys, json; d=json.load(sys.stdin); print(d.get('balance',{}).get('amount','0'))" \
        2>/dev/null || echo "ERR"
}

# Pull last-alert times for each flag from the state file (if present)
last_alert_ts() {
    local flag="$1"
    if [ ! -f "$STATE_FILE" ]; then echo "0"; return; fi
    "$PY_VENV" -c "
import json, sys
try:
    d = json.load(open('$STATE_FILE'))
    print(d.get('$flag', 0))
except Exception:
    print(0)
" 2>/dev/null || echo "0"
}

set_alert_ts() {
    local flag="$1" now_ts="$2"
    "$PY_VENV" -c "
import json, os
p = '$STATE_FILE'
try:
    d = json.load(open(p)) if os.path.exists(p) else {}
except Exception:
    d = {}
d['$flag'] = $now_ts
json.dump(d, open(p, 'w'), indent=2)
"
}

NOW_TS=$(date -u +%s)
DEDUP_SEC=$((DEDUP_HOURS * 3600))

# 1. AKT balance + runway
AKT_RAW=$(denom_balance "$AKASH_LCD" "$AKASH_ADDR" "uakt")
AKT=$("$PY_VENV" -c "v='$AKT_RAW'; print(int(v)/1e6 if v.isdigit() else 0)")
RUNWAY_MO=$("$PY_VENV" -c "print(round($AKT / 0.864, 1))")

# 2. Mantle / osmo balances
MNTL_RAW=$(denom_balance "$MANTLE_LCD" "$MANTLE_ADDR" "umntl")
MNTL=$("$PY_VENV" -c "v='$MNTL_RAW'; print(int(v)/1e6 if v.isdigit() else 0)")
OSMO_RAW=$(denom_balance "$OSMO_LCD" "$OSMO_ADDR" "uosmo")
OSMO=$("$PY_VENV" -c "v='$OSMO_RAW'; print(int(v)/1e6 if v.isdigit() else 0)")

echo "  AKT: $AKT (~${RUNWAY_MO}mo runway)"
echo "  mantle: $MNTL MNTL (raw=$MNTL_RAW)"
echo "  osmo:   $OSMO OSMO (raw=$OSMO_RAW)"

# Build flags + dedup
FLAGS=""

check_and_dedup() {
    local flag="$1" message="$2"
    local last
    last=$(last_alert_ts "$flag")
    local elapsed=$((NOW_TS - last))
    if [ "$elapsed" -ge "$DEDUP_SEC" ]; then
        FLAGS="${FLAGS}${message}\n"
        if [ "$DRY_RUN" != "1" ]; then
            set_alert_ts "$flag" "$NOW_TS"
        fi
        echo "  flag fired: $flag (last alert ${elapsed}s ago)"
    else
        echo "  flag suppressed: $flag (last alert ${elapsed}s ago, dedup ${DEDUP_SEC}s)"
    fi
}

if "$PY_VENV" -c "exit(0 if $RUNWAY_MO < $AKT_MIN_RUNWAY_MONTHS else 1)" 2>/dev/null; then
    check_and_dedup "akt_runway_low" "⚠ AKT runway low: ${RUNWAY_MO}mo (<${AKT_MIN_RUNWAY_MONTHS}mo)"
fi
if [ "$MNTL_RAW" != "ERR" ] && "$PY_VENV" -c "exit(0 if int('$MNTL_RAW' if '$MNTL_RAW'.isdigit() else 0) < $MNTL_MIN else 1)" 2>/dev/null; then
    check_and_dedup "mntl_low" "⚠ mantle1 below ${MNTL_MIN} umntl: ${MNTL} MNTL"
fi
if [ "$OSMO_RAW" != "ERR" ] && "$PY_VENV" -c "exit(0 if int('$OSMO_RAW' if '$OSMO_RAW'.isdigit() else 0) < $UOSMO_MIN else 1)" 2>/dev/null; then
    check_and_dedup "osmo_low" "⚠ osmo1 below ${UOSMO_MIN} uosmo: ${OSMO} OSMO"
fi

if [ -n "$FLAGS" ]; then
    REPORT="<b>💰 Relayer balance alert</b>%0A%0A<b>AKT:</b> ${AKT} (~${RUNWAY_MO}mo)%0A<b>mantle1:</b> ${MNTL} MNTL%0A<b>osmo1:</b> ${OSMO} OSMO%0A%0A$(echo -e "$FLAGS" | sed 's/$/%0A/' | tr -d '\n')"
    tg "$REPORT"
else
    echo "  no flags raised — no Telegram message sent"
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  done"
