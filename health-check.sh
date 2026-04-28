#!/usr/bin/env bash
# 5-min health check for the mantle-1 <-> osmosis-1 IBC Hermes relayer.
#
# Two-tier alert policy:
#   - WARN once per fault.transition (page when newly broken; silent until fixed
#     and broken again)
#   - PAGE if BOTH akash and home are simultaneously broken (paired loss is
#     the actual outage; single-side is degraded but still relaying)
#
# Runs every 5 minutes via crontab:
#   */5 * * * * /home/deepanshutr/akash-relayer/health-check.sh
#
# State persisted between runs at $STATE_FILE so we don't spam Telegram on
# every 5-min tick when the same fault persists.

set -uo pipefail
export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LOG="/home/deepanshutr/akash-relayer/health-check.log"
STATE_FILE="/home/deepanshutr/akash-relayer/health-check.state.json"
DEPLOY_STATE="/home/deepanshutr/akash-relayer/deployment-state.json"
PY_VENV="/home/deepanshutr/autonomy/internal/wallet/atomone/.venv/bin/python"

mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1

ts() { date -u +%FT%TZ; }
echo "$(ts) check"

tg() {
    local msg="$1"
    PYTHONPATH=/home/deepanshutr/autonomy/internal "$PY_VENV" -c "
import sys
from notification.telegram import send_alert
send_alert(sys.argv[1], parse_mode='HTML')
" "$msg" 2>&1 || echo "$(ts) WARN: tg send failed"
}

# Load prior state (or empty)
prior() {
    local key="$1"
    if [ -f "$STATE_FILE" ]; then
        "$PY_VENV" -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('$key', ''))" 2>/dev/null || echo ""
    fi
}

# Probe 1: home container — docker inspect
home_status="ok"
home_pid="$(docker inspect -f '{{.State.Pid}}' hermes-relayer 2>/dev/null || echo 0)"
if [ "$home_pid" = "0" ] || [ -z "$home_pid" ]; then
    home_status="down (docker inspect failed)"
elif ! curl -sf --max-time 5 http://127.0.0.1:3001/metrics -o /dev/null; then
    home_status="metrics-unreachable"
fi

# Probe 2: akash deployment — provider lease-status + metrics endpoint
akash_status="ok"
akash_endpoint="$("$PY_VENV" -c "import json; d=json.load(open('$DEPLOY_STATE')); print(d.get('endpoint',''))" 2>/dev/null || echo '')"
if [ -z "$akash_endpoint" ]; then
    akash_status="no-deploy-state"
elif ! curl -sf --max-time 10 "http://${akash_endpoint}/metrics" -o /dev/null; then
    akash_status="metrics-unreachable"
fi

# Decide alerts
prior_home="$(prior home_status)"
prior_akash="$(prior akash_status)"

ALERT=""
if [ "$home_status" != "ok" ] && [ "$prior_home" = "ok" ]; then
    ALERT="${ALERT}⚠ <b>HOME relayer NEWLY DOWN:</b> ${home_status}%0A"
fi
if [ "$akash_status" != "ok" ] && [ "$prior_akash" = "ok" ]; then
    ALERT="${ALERT}⚠ <b>AKASH relayer NEWLY DOWN:</b> ${akash_status}%0A"
fi
if [ "$home_status" = "ok" ] && [ "$prior_home" != "ok" ] && [ -n "$prior_home" ]; then
    ALERT="${ALERT}✅ <b>HOME relayer recovered</b> (was: ${prior_home})%0A"
fi
if [ "$akash_status" = "ok" ] && [ "$prior_akash" != "ok" ] && [ -n "$prior_akash" ]; then
    ALERT="${ALERT}✅ <b>AKASH relayer recovered</b> (was: ${prior_akash})%0A"
fi

# PAGE: both down simultaneously
if [ "$home_status" != "ok" ] && [ "$akash_status" != "ok" ]; then
    ALERT="${ALERT}🚨 <b>BOTH relayers down — IBC channel mantle-1↔osmosis-1 unmonitored</b>%0A"
fi

if [ -n "$ALERT" ]; then
    tg "$ALERT(checked $(ts))"
    echo "$(ts) alert sent: ${ALERT}" | tr -d '\n'
    echo ""
fi

# Persist state
"$PY_VENV" -c "
import json
json.dump({
    'ts': '$(ts)',
    'home_status': '$home_status',
    'akash_status': '$akash_status',
}, open('$STATE_FILE','w'), indent=2)
"

echo "$(ts) home=$home_status akash=$akash_status"
