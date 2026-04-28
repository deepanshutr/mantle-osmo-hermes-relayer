#!/usr/bin/env bash
# Post-prop-#82 enaction deploy driver.
# Scheduled via crontab to fire at 2026-04-28 10:30 IST (= 05:00 UTC),
# ~42 min after mantle-1 prop #82 voting closes (04:18 UTC).
#
# Behavior:
#   - Verifies #82 final status = PASSED via LCD
#   - Verifies mantle-1 client 07-tendermint-0 is now Active
#   - Tops up relayer osmo1 wallet by 25 OSMO from autonomy hot wallet
#   - Builds + pushes wrapper image to ghcr.io
#   - Runs deploy.sh (Akash deployment)
#   - Health-checks the deployed relayer's Hermes /metrics endpoint
#   - Posts a Telegram report (success or abort details)
#
# Idempotent via state file. Re-running after a successful run is a no-op.

set -uo pipefail

# Cron has a minimal PATH; ensure linuxbrew + autonomy venv binaries are reachable.
export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# ---------- paths ------------------------------------------------------------
PKG_DIR="/home/deepanshutr/akash-relayer"
STATE="${PKG_DIR}/post-prop-82-deploy.state"
LOG="${PKG_DIR}/post-prop-82-deploy.log"
DEPLOY_OUT="/tmp/akash-deploy-out.log"
PY_VENV="/home/deepanshutr/autonomy/internal/wallet/atomone/.venv/bin/python"
OSMOSISD="/tmp/osmosisd"

# Match deploy.yaml's image reference:
IMAGE="ghcr.io/deepanshutr/mantle-osmo-hermes-relayer:v0.1.0"

RELAYER_OSMO_ADDR="osmo176p470v8vqfj072yclqxvcvrs88j0msz6ar4z5"
AUTONOMY_OSMO_ADDR="osmo12yfk3mc2exa3zch7qh6w5ah9s3n0fadtyfz5z6"
TOPUP_AMOUNT_UOSMO="25000000"  # 25 OSMO

OSMO_LCD="https://rpc.osmosis.zone:443"
MANTLE_LCD="https://assetmantle-rest.stakerhouse.com"

mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1
echo ""
echo "=========================================================="
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  post-prop-82-deploy start"
echo "=========================================================="

# ---------- helpers ----------------------------------------------------------
tg() {
    # Best-effort Telegram alert via orchctl bot.
    local msg="$1"
    PYTHONPATH=/home/deepanshutr/autonomy/internal "$PY_VENV" -c "
import sys
from notification.telegram import send_alert
send_alert(sys.argv[1], parse_mode='HTML')
" "$msg" 2>&1 || echo "WARN: tg alert failed (continuing)"
}

abort() {
    local reason="$1"
    echo "ABORT: $reason"
    echo "{\"status\": \"aborted\", \"reason\": \"$reason\", \"ts\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$STATE"
    tg "<b>❌ post-prop-82-deploy ABORTED</b>%0A<code>$reason</code>"
    exit 1
}

# ---------- idempotency check ------------------------------------------------
if [ -f "$STATE" ]; then
    PRIOR_STATUS=$($PY_VENV -c "import json; print(json.load(open('$STATE')).get('status','?'))" 2>/dev/null || echo "?")
    if [ "$PRIOR_STATUS" = "completed" ]; then
        echo "STATE file shows completed — exiting (no-op)."
        exit 0
    fi
    echo "STATE file present (status=$PRIOR_STATUS); proceeding cautiously."
fi

# ---------- 1/6: verify #82 status -------------------------------------------
echo ""
echo "[1/6] Checking prop #82 status..."
PROP_STATUS=$(curl -s --max-time 30 "${MANTLE_LCD}/cosmos/gov/v1beta1/proposals/82" \
    | $PY_VENV -c "import sys, json; print(json.load(sys.stdin).get('proposal', {}).get('status','UNKNOWN'))" \
    2>/dev/null || echo "ERR")
echo "   prop #82 status: $PROP_STATUS"

if [ "$PROP_STATUS" != "PROPOSAL_STATUS_PASSED" ]; then
    abort "Prop #82 status is $PROP_STATUS (expected PROPOSAL_STATUS_PASSED). Voting may not have closed yet, or proposal failed."
fi

# ---------- 2/6: verify mantle-1 client recovered ----------------------------
echo ""
echo "[2/6] Checking mantle-1 client 07-tendermint-0..."
CLIENT_STATUS=$(curl -s --max-time 30 "${MANTLE_LCD}/ibc/core/client/v1/client_status/07-tendermint-0" \
    | $PY_VENV -c "import sys, json; print(json.load(sys.stdin).get('status','UNKNOWN'))" \
    2>/dev/null || echo "ERR")
echo "   client 07-tendermint-0 status: $CLIENT_STATUS"

if [ "$CLIENT_STATUS" != "Active" ]; then
    abort "mantle-1 client 07-tendermint-0 status is '$CLIENT_STATUS' (expected 'Active'). Recovery may not have enacted."
fi

tg "<b>✅ Prop #82 PASSED + client recovered</b>%0AStarting Akash deploy..."

# ---------- 3/6: top up osmo1 wallet -----------------------------------------
echo ""
echo "[3/6] Topping up relayer osmo1 by 25 OSMO..."

# Shared-wallet guard (per autonomy memory)
if pgrep -fa 'osmosisd|atomoned|swap_to_osmo' \
    | grep -v "$$" | grep -v 'post-prop-82-deploy' \
    | grep -v 'pgrep' > /dev/null; then
    pgrep -fa 'osmosisd|atomoned|swap_to_osmo' >> "$LOG"
    abort "Other osmosis process running — manual intervention needed for OSMO top-up. Check pgrep output in log."
fi

if [ ! -x "$OSMOSISD" ]; then
    echo "   WARN: $OSMOSISD missing or not executable; skipping top-up. Relayer has 5 OSMO seed (~10 days runway)."
    OSMO_TX="SKIPPED_BINARY_MISSING"
else
    OSMO_TX_OUT=$($OSMOSISD tx bank send autonomy "$RELAYER_OSMO_ADDR" "${TOPUP_AMOUNT_UOSMO}uosmo" \
        --gas auto --gas-prices 0.05uosmo --gas-adjustment 1.4 \
        --keyring-backend test --chain-id osmosis-1 --node "$OSMO_LCD" \
        -y -o json 2>&1) || true
    OSMO_TX=$(echo "$OSMO_TX_OUT" | $PY_VENV -c "import sys, json; print(json.load(sys.stdin).get('txhash','ERR'))" 2>/dev/null || echo "ERR")
    echo "   OSMO top-up tx: $OSMO_TX"
    if [ "$OSMO_TX" = "ERR" ]; then
        echo "   stdout/stderr from osmosisd:"
        echo "$OSMO_TX_OUT" | head -20
        echo "   Continuing despite top-up failure (relayer has seed)..."
    fi
fi

# ---------- 4/6: build + push wrapper image ----------------------------------
echo ""
echo "[4/6] Building + pushing $IMAGE..."
cd "$PKG_DIR"

if ! gh auth token | docker login ghcr.io -u deepanshutr --password-stdin 2>&1 | grep -q "Login Succeeded"; then
    abort "Docker login to ghcr.io failed. Check 'gh auth status' for write:packages scope."
fi

if ! docker build -t "$IMAGE" . 2>&1 | tail -10; then
    abort "Docker build failed. See log for details."
fi

if ! docker push "$IMAGE" 2>&1 | tail -10; then
    abort "Docker push to ghcr.io failed."
fi

IMG_DIGEST=$(docker inspect "$IMAGE" -f '{{index .RepoDigests 0}}' 2>/dev/null || docker inspect "$IMAGE" -f '{{.Id}}')
echo "   image digest: $IMG_DIGEST"

# ---------- 5/6: run Akash deploy --------------------------------------------
echo ""
echo "[5/6] Running deploy.sh..."
> "$DEPLOY_OUT"
if ! bash "$PKG_DIR/deploy.sh" 2>&1 | tee -a "$DEPLOY_OUT"; then
    DSEQ_PARTIAL=$(grep -oP 'DSEQ[:= ]+\K\d+' "$DEPLOY_OUT" | head -1 || true)
    abort "deploy.sh failed. Partial DSEQ: ${DSEQ_PARTIAL:-none}. Tail of output: $(tail -5 $DEPLOY_OUT | tr '\n' ' ')"
fi

DSEQ=$(grep -oP 'DSEQ[:= ]+\K\d+' "$DEPLOY_OUT" | tail -1 || true)
PROVIDER=$(grep -oP 'Provider[:= ]+\Kakash1[a-z0-9]+' "$DEPLOY_OUT" | tail -1 || true)
ENDPOINT=$(grep -oP 'https?://[^\s]+:3001[^\s]*' "$DEPLOY_OUT" | tail -1 || true)
echo "   DSEQ: ${DSEQ:-?}  provider: ${PROVIDER:-?}  endpoint: ${ENDPOINT:-?}"

# ---------- 6/6: health check + Telegram report ------------------------------
echo ""
echo "[6/6] Health check..."
sleep 30  # give container time to import keys + start hermes

HEALTH="UNKNOWN"
if [ -n "${ENDPOINT:-}" ]; then
    if curl -sf --max-time 10 "$ENDPOINT" -o /tmp/metrics.out; then
        HEALTH="OK ($(wc -l < /tmp/metrics.out) lines)"
    else
        HEALTH="FAIL_OR_NOT_READY"
    fi
fi
echo "   metrics check: $HEALTH"

# Persist final state
$PY_VENV -c "
import json
json.dump({
    'status': 'completed',
    'ts': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'prop_82': '$PROP_STATUS',
    'client_status': '$CLIENT_STATUS',
    'osmo_topup_tx': '$OSMO_TX',
    'image': '$IMAGE',
    'image_digest': '$IMG_DIGEST',
    'dseq': '${DSEQ:-}',
    'provider': '${PROVIDER:-}',
    'endpoint': '${ENDPOINT:-}',
    'metrics_health': '$HEALTH'
}, open('$STATE', 'w'), indent=2)
"

tg "<b>✅ post-prop-82-deploy SUCCESS</b>%0A%0A<b>Prop #82:</b> PASSED%0A<b>Client 07-tendermint-0:</b> Active%0A<b>OSMO top-up:</b> <code>${OSMO_TX:-SKIPPED}</code>%0A<b>Image:</b> <code>${IMG_DIGEST:0:32}…</code>%0A<b>DSEQ:</b> <code>${DSEQ:-?}</code>%0A<b>Provider:</b> <code>${PROVIDER:-?}</code>%0A<b>Endpoint:</b> <code>${ENDPOINT:-?}</code>%0A<b>Health:</b> <code>$HEALTH</code>"

echo ""
echo "=========================================================="
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  post-prop-82-deploy DONE"
echo "=========================================================="
