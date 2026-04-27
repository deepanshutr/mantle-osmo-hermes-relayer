#!/usr/bin/env bash
# Akash deployment driver for the mantle-1 <-> osmosis-1 IBC Hermes relayer.
#
# Reads:
#   /home/deepanshutr/.relayer-akash/addresses.json   (mantle1 + osmo1 addrs)
#   /home/deepanshutr/.relayer-akash/mnemonic.enc     (24-word BIP39 mnemonic)
#   /home/deepanshutr/.relayer-akash/.encryption_key  (AES-GCM key, when used)
#   /home/deepanshutr/akash-relayer/deploy.yaml       (SDL template)
#
# Writes (and shreds at end):
#   /home/deepanshutr/akash-relayer/deploy-rendered.yaml
#
# Persists:
#   /home/deepanshutr/akash-relayer/deployment-state.json
#
# Idempotency: if deployment-state.json exists with a DSEQ, the script
# switches to update mode (`tx deployment update` instead of `create`,
# plus a manifest re-send). To force a fresh deploy, delete
# deployment-state.json first.

set -euo pipefail

# ---------- config -----------------------------------------------------------
PKG_DIR="/home/deepanshutr/akash-relayer"
WALLET_DIR="/home/deepanshutr/.relayer-akash"
ADDRESSES_FILE="${WALLET_DIR}/addresses.json"
MNEMONIC_ENC="${WALLET_DIR}/mnemonic.enc"
ENC_KEY_FILE="${WALLET_DIR}/.encryption_key"
SDL_TEMPLATE="${PKG_DIR}/deploy.yaml"
SDL_RENDERED="${PKG_DIR}/deploy-rendered.yaml"
STATE_FILE="${PKG_DIR}/deployment-state.json"

AKASH_KEY_NAME="autonomy"
AKASH_KEY_ADDR="akash12yfk3mc2exa3zch7qh6w5ah9s3n0fadtpfurdj"
AKASH_NODE="${AKASH_NODE:-https://rpc.akashnet.net:443}"
AKASH_CHAIN_ID="${AKASH_CHAIN_ID:-akashnet-2}"
AKASH_KEYRING="${AKASH_KEYRING:-test}"
AKASH_GAS_PRICES="${AKASH_GAS_PRICES:-0.025uakt}"

PROVIDER_ATTR_HOST="${PROVIDER_ATTR_HOST:-akash}"            # SDL placement.host
PROVIDER_NAME_HINT="${PROVIDER_NAME_HINT:-zencloud.eu}"      # bid hostname filter
MIN_AKT_REQUIRED="${MIN_AKT_REQUIRED:-5000000}"              # 5 AKT in uakt
BID_WAIT_SECS="${BID_WAIT_SECS:-300}"

PROVIDER_SERVICES="${PROVIDER_SERVICES:-/home/deepanshutr/go/bin/provider-services}"
JQ="${JQ:-/usr/bin/jq}"

# ---------- helpers ----------------------------------------------------------
log()  { printf '[deploy %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { log "FATAL: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "required binary not in PATH: $1"; }

shred_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  if command -v shred >/dev/null 2>&1; then
    shred -u -f -n 3 "$f" || rm -f "$f"
  else
    rm -f "$f"
  fi
}

cleanup() {
  local rc=$?
  shred_file "${SDL_RENDERED}"
  unset RELAYER_MNEMONIC || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------- 1. preflight -----------------------------------------------------
log "preflight: checking required binaries"
need "${PROVIDER_SERVICES}"
need "${JQ}"
need envsubst
need curl

[ -f "${SDL_TEMPLATE}" ] || fail "missing SDL template ${SDL_TEMPLATE}"
[ -f "${ADDRESSES_FILE}" ] || fail "missing ${ADDRESSES_FILE}; the relayer-wallet agent must finish before deploy"
[ -f "${MNEMONIC_ENC}" ] || fail "missing ${MNEMONIC_ENC}; the relayer-wallet agent must finish before deploy"

log "preflight: querying AKT balance for ${AKASH_KEY_ADDR}"
balance_uakt="$("${PROVIDER_SERVICES}" query bank balances "${AKASH_KEY_ADDR}" \
  --node "${AKASH_NODE}" --output json 2>/dev/null \
  | "${JQ}" -r '.balances[] | select(.denom=="uakt") | .amount' || true)"
balance_uakt="${balance_uakt:-0}"
log "preflight: AKT balance = ${balance_uakt} uakt (need >= ${MIN_AKT_REQUIRED})"
if [ "${balance_uakt}" -lt "${MIN_AKT_REQUIRED}" ]; then
  fail "insufficient AKT: have ${balance_uakt} uakt, need ${MIN_AKT_REQUIRED} uakt; fund ${AKASH_KEY_ADDR}"
fi

log "preflight: parsing addresses.json"
mantle_addr="$("${JQ}" -r '.mantle1 // .mantle // empty' "${ADDRESSES_FILE}")"
osmo_addr="$("${JQ}" -r '.osmo1 // .osmosis // .osmo // empty' "${ADDRESSES_FILE}")"
[ -n "${mantle_addr}" ] || fail "addresses.json missing mantle1 / mantle key"
[ -n "${osmo_addr}" ]   || fail "addresses.json missing osmo1 / osmosis / osmo key"
log "preflight: mantle relayer addr = ${mantle_addr}"
log "preflight: osmo   relayer addr = ${osmo_addr}"

probe_balance() {
  local lcd="$1" addr="$2" label="$3"
  local resp
  resp="$(curl -fsS --max-time 8 "${lcd}/cosmos/bank/v1beta1/balances/${addr}" || echo '{}')"
  local n
  n="$(printf '%s' "${resp}" | "${JQ}" -r '.balances | length' 2>/dev/null || echo 0)"
  if [ "${n}" -eq 0 ]; then
    log "WARN: ${label} relayer wallet ${addr} appears unfunded (LCD: ${lcd})"
  else
    log "preflight: ${label} relayer wallet funded with ${n} denom(s)"
  fi
}
probe_balance "https://assetmantle-rest.stakerhouse.com" "${mantle_addr}" "mantle"
probe_balance "https://lcd.osmosis.zone"                 "${osmo_addr}"   "osmosis"

# ---------- 2. decrypt mnemonic ---------------------------------------------
log "decrypt: loading RELAYER_MNEMONIC from ${MNEMONIC_ENC}"
RELAYER_MNEMONIC=""

# Detect format by header bytes:
#   - GPG armored:  '-----BEGIN PGP MESSAGE-----'
#   - GPG binary:   0x85 / 0x84 leading byte
#   - age:          'age-encryption.org/v1'
#   - AES-GCM:      raw binary, 12-byte nonce + ciphertext + 16-byte tag
#                   (the layout the relayer-wallet agent uses with .encryption_key)
header="$(head -c 32 "${MNEMONIC_ENC}" | xxd -p | tr -d '\n')"

if printf '%s' "${header}" | grep -qi '2d2d2d2d2d424547494e2050475020'; then
  # GPG armored
  if [ -n "${MNEMONIC_GPG_PASSPHRASE:-}" ]; then
    RELAYER_MNEMONIC="$(gpg --batch --yes --quiet --passphrase "${MNEMONIC_GPG_PASSPHRASE}" \
      --decrypt "${MNEMONIC_ENC}" 2>/dev/null || true)"
  else
    RELAYER_MNEMONIC="$(gpg --quiet --decrypt "${MNEMONIC_ENC}" 2>/dev/null || true)"
  fi
elif printf '%s' "${header}" | head -c 4 | grep -qE '^85|^84'; then
  # GPG binary
  RELAYER_MNEMONIC="$(gpg --quiet --decrypt "${MNEMONIC_ENC}" 2>/dev/null || true)"
elif head -c 21 "${MNEMONIC_ENC}" | grep -q 'age-encryption.org'; then
  : "${AGE_IDENTITY_FILE:=${HOME}/.age/identity.txt}"
  [ -f "${AGE_IDENTITY_FILE}" ] || fail "age identity file not found: ${AGE_IDENTITY_FILE}"
  RELAYER_MNEMONIC="$(age --decrypt -i "${AGE_IDENTITY_FILE}" "${MNEMONIC_ENC}")"
elif [ -f "${ENC_KEY_FILE}" ]; then
  # AES-GCM with 32-byte key at .encryption_key. The python decrypt is the
  # one matching the relayer-wallet agent's encryption format (cryptography
  # library, AESGCM(key).decrypt(nonce=ct[:12], data=ct[12:], aad=None)).
  need python3
  RELAYER_MNEMONIC="$(MNEMONIC_ENC="${MNEMONIC_ENC}" ENC_KEY_FILE="${ENC_KEY_FILE}" \
    python3 - <<'PY'
import os, sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
key = open(os.environ['ENC_KEY_FILE'], 'rb').read()
blob = open(os.environ['MNEMONIC_ENC'], 'rb').read()
nonce, ct = blob[:12], blob[12:]
sys.stdout.write(AESGCM(key).decrypt(nonce, ct, None).decode().strip())
PY
)" || fail "AES-GCM decrypt failed; verify .encryption_key matches the encryption format"
elif [ -n "${MNEMONIC_OPENSSL_PASSPHRASE:-}" ]; then
  RELAYER_MNEMONIC="$(openssl enc -d -aes-256-cbc -salt -pbkdf2 \
    -in "${MNEMONIC_ENC}" -pass "pass:${MNEMONIC_OPENSSL_PASSPHRASE}" 2>/dev/null || true)"
else
  fail "could not detect mnemonic encryption format; set MNEMONIC_GPG_PASSPHRASE / MNEMONIC_OPENSSL_PASSPHRASE / age identity, or ensure ${ENC_KEY_FILE} exists"
fi

# Trim whitespace; sanity check word count (expecting 12 or 24 BIP39 words).
RELAYER_MNEMONIC="$(printf '%s' "${RELAYER_MNEMONIC}" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
word_count="$(printf '%s' "${RELAYER_MNEMONIC}" | wc -w | tr -d ' ')"
if [ "${word_count}" -ne 24 ] && [ "${word_count}" -ne 12 ]; then
  fail "mnemonic decryption produced ${word_count} words; expected 12 or 24."
fi
log "decrypt: mnemonic loaded (${word_count} words)"
export RELAYER_MNEMONIC

# ---------- 3. render SDL ----------------------------------------------------
log "render: generating ${SDL_RENDERED}"
umask 0077
{
  awk -v MNEMONIC="${RELAYER_MNEMONIC}" '
    /# RELAYER_MNEMONIC injected/ {
      print "      - RELAYER_MNEMONIC=" MNEMONIC
      next
    }
    { print }
  ' "${SDL_TEMPLATE}"
} > "${SDL_RENDERED}"

# Sanity: rendered file must contain the mnemonic line.
grep -q '^      - RELAYER_MNEMONIC=' "${SDL_RENDERED}" \
  || fail "render failed; RELAYER_MNEMONIC line not injected"
log "render: SDL ready (mode 0600, will be shredded on exit)"

# ---------- 4. create or update deployment ----------------------------------
mode="create"
existing_dseq=""
existing_provider=""
if [ -f "${STATE_FILE}" ]; then
  existing_dseq="$("${JQ}" -r '.dseq // empty' "${STATE_FILE}")"
  existing_provider="$("${JQ}" -r '.provider // empty' "${STATE_FILE}")"
  if [ -n "${existing_dseq}" ]; then
    mode="update"
    log "state: existing DSEQ=${existing_dseq} provider=${existing_provider}; switching to update mode"
  fi
fi

tx_common=(
  --from "${AKASH_KEY_NAME}"
  --keyring-backend "${AKASH_KEYRING}"
  --node "${AKASH_NODE}"
  --chain-id "${AKASH_CHAIN_ID}"
  --gas-prices "${AKASH_GAS_PRICES}"
  --gas auto
  --gas-adjustment 1.5
  -y
  --output json
)

if [ "${mode}" = "create" ]; then
  log "tx: deployment create"
  create_resp="$("${PROVIDER_SERVICES}" tx deployment create "${SDL_RENDERED}" "${tx_common[@]}")"
  printf '%s\n' "${create_resp}" | "${JQ}" '.' >/dev/null \
    || fail "deployment create returned non-JSON: ${create_resp}"
  txhash="$(printf '%s' "${create_resp}" | "${JQ}" -r '.txhash')"
  log "tx: hash=${txhash}; waiting for inclusion"
  sleep 8
  tx_q="$("${PROVIDER_SERVICES}" query tx "${txhash}" --node "${AKASH_NODE}" --output json 2>/dev/null || echo '{}')"
  dseq="$(printf '%s' "${tx_q}" | "${JQ}" -r '.events[]?.attributes[]? | select(.key=="dseq" or .key=="ZHNlcQ==").value' \
    | head -1 | tr -d '"')"
  if [ -z "${dseq}" ]; then
    dseq="$(printf '%s' "${tx_q}" | "${JQ}" -r '.logs[0].events[]?.attributes[]? | select(.key=="dseq").value' | head -1)"
  fi
  [ -n "${dseq}" ] || fail "could not parse DSEQ from tx ${txhash}"
  log "tx: DSEQ=${dseq}"
else
  dseq="${existing_dseq}"
  log "tx: deployment update on DSEQ=${dseq}"
  "${PROVIDER_SERVICES}" tx deployment update "${SDL_RENDERED}" \
    --dseq "${dseq}" "${tx_common[@]}" >/dev/null
fi

# ---------- 5. wait for bids -------------------------------------------------
provider=""
if [ -n "${existing_provider}" ]; then
  provider="${existing_provider}"
  log "lease: reusing existing provider=${provider}"
else
  log "lease: waiting up to ${BID_WAIT_SECS}s for bids on DSEQ=${dseq}"
  deadline=$(( $(date +%s) + BID_WAIT_SECS ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    bids_json="$("${PROVIDER_SERVICES}" query market bid list \
      --owner "${AKASH_KEY_ADDR}" --dseq "${dseq}" \
      --node "${AKASH_NODE}" --output json 2>/dev/null || echo '{}')"
    n_bids="$(printf '%s' "${bids_json}" | "${JQ}" -r '.bids | length' 2>/dev/null || echo 0)"
    if [ "${n_bids}" -gt 0 ]; then
      log "lease: ${n_bids} bid(s) received"
      printf '%s' "${bids_json}" | "${JQ}" -r '.bids[] | "  bid provider=\(.bid.bid_id.provider) price=\(.bid.price.amount)\(.bid.price.denom)"'
      break
    fi
    sleep 6
  done

  for cand in $(printf '%s' "${bids_json}" | "${JQ}" -r '.bids[].bid.bid_id.provider'); do
    info="$("${PROVIDER_SERVICES}" query provider get "${cand}" \
      --node "${AKASH_NODE}" --output json 2>/dev/null || echo '{}')"
    host_uri="$(printf '%s' "${info}" | "${JQ}" -r '.provider.host_uri // empty')"
    if printf '%s' "${host_uri}" | grep -qi "${PROVIDER_NAME_HINT}"; then
      provider="${cand}"
      log "lease: matched provider=${provider} host=${host_uri}"
      break
    fi
  done
  if [ -z "${provider}" ]; then
    log "WARN: no bid matched ${PROVIDER_NAME_HINT}; falling back to lowest-price bid"
    provider="$(printf '%s' "${bids_json}" \
      | "${JQ}" -r '.bids | sort_by(.bid.price.amount | tonumber) | .[0].bid.bid_id.provider')"
    [ -n "${provider}" ] && [ "${provider}" != "null" ] || fail "no usable bid for DSEQ=${dseq}"
    log "lease: fallback provider=${provider}"
  fi

  log "lease: creating lease dseq=${dseq} provider=${provider}"
  "${PROVIDER_SERVICES}" tx market lease create \
    --dseq "${dseq}" --provider "${provider}" \
    --gseq 1 --oseq 1 \
    "${tx_common[@]}" >/dev/null
fi

# ---------- 7. send manifest -------------------------------------------------
log "manifest: sending to ${provider}"
"${PROVIDER_SERVICES}" send-manifest "${SDL_RENDERED}" \
  --dseq "${dseq}" --provider "${provider}" \
  --from "${AKASH_KEY_NAME}" --keyring-backend "${AKASH_KEYRING}" \
  --node "${AKASH_NODE}" --home "${HOME}/.akash" || \
  log "WARN: send-manifest reported non-zero; check 'provider-services lease-status'"

# ---------- 8. resolve external endpoint ------------------------------------
log "endpoint: querying lease-status for forwarded URLs"
status_json="$("${PROVIDER_SERVICES}" lease-status \
  --dseq "${dseq}" --provider "${provider}" \
  --from "${AKASH_KEY_NAME}" --keyring-backend "${AKASH_KEYRING}" \
  --home "${HOME}/.akash" --node "${AKASH_NODE}" 2>/dev/null || echo '{}')"
endpoint="$(printf '%s' "${status_json}" \
  | "${JQ}" -r '.forwarded_ports.relayer[0]? | "\(.host):\(.externalPort)"' 2>/dev/null || true)"
[ "${endpoint}" = ":" ] && endpoint=""

# ---------- 9. persist state ------------------------------------------------
log "state: writing ${STATE_FILE}"
"${JQ}" -n \
  --arg dseq "${dseq}" \
  --arg provider "${provider}" \
  --arg endpoint "${endpoint}" \
  --arg mantle_addr "${mantle_addr}" \
  --arg osmo_addr "${osmo_addr}" \
  --arg ts "$(date -u +%FT%TZ)" \
  --arg mode "${mode}" \
  '{
     dseq: $dseq,
     provider: $provider,
     endpoint: $endpoint,
     mantle_relayer_address: $mantle_addr,
     osmo_relayer_address: $osmo_addr,
     created_at: $ts,
     mode: $mode,
     sdl: "deploy.yaml",
     image: "ghcr.io/assetmantle/relayer-mantle-osmosis-hermes:v0.1.0",
     relayer: "hermes-1.13.1"
   }' > "${STATE_FILE}"
chmod 0600 "${STATE_FILE}"

# ---------- 10. summary ------------------------------------------------------
log "===================================================================="
log "DONE  mode=${mode}"
log "  DSEQ:     ${dseq}"
log "  Provider: ${provider}"
log "  Endpoint: ${endpoint:-pending; re-run: provider-services lease-status}"
log "  State:    ${STATE_FILE}"
log "===================================================================="
log "logs:    ${PROVIDER_SERVICES} lease-logs --dseq ${dseq} --provider ${provider} --service relayer --follow"
log "metrics: curl http://${endpoint:-<endpoint>}/metrics  # Prometheus format"
log "close:   ${PROVIDER_SERVICES} tx deployment close --dseq ${dseq} --from ${AKASH_KEY_NAME}"
