#!/usr/bin/env bash
# Entrypoint for the mantle-1 <-> osmosis-1 Akash Hermes relayer container.
#
# First-boot init (idempotent — re-running on existing volume is a no-op):
#   1. envsubst config.toml.template -> ~/.hermes/config.toml
#   2. hermes config validate
#   3. hermes keys add --chain mantle-1 / osmosis-1 --mnemonic-file /tmp/<file>
#      (only if no key for that chain exists yet)
#   4. hermes keys list (sanity probe; non-fatal — only logs)
#
# Every-boot:
#   5. exec hermes start
#
# SIGTERM is forwarded by tini (image ENTRYPOINT) and re-forwarded by this
# script's trap. Hermes itself handles graceful shutdown of workers.

set -euo pipefail

: "${MANTLE_RPC_PRIMARY:?MANTLE_RPC_PRIMARY not set}"
: "${OSMO_RPC_PRIMARY:?OSMO_RPC_PRIMARY not set}"
: "${MANTLE_GRPC:?MANTLE_GRPC not set}"
: "${OSMO_GRPC:?OSMO_GRPC not set}"
# WebSocket URLs default to the RPC primary with /websocket appended if
# the SDL did not set them explicitly. Hermes 1.13 requires either push
# (WS) or pull mode; we default to push because it is lower-latency and
# both Polkachu RPC + rpc.osmosis.zone expose WS on the same hostname.
if [ -z "${MANTLE_WS:-}" ]; then
  MANTLE_WS="${MANTLE_RPC_PRIMARY/https:/wss:}"
  MANTLE_WS="${MANTLE_WS/http:/ws:}/websocket"
fi
if [ -z "${OSMO_WS:-}" ]; then
  OSMO_WS="${OSMO_RPC_PRIMARY/https:/wss:}"
  OSMO_WS="${OSMO_WS/http:/ws:}/websocket"
fi
export MANTLE_RPC_PRIMARY OSMO_RPC_PRIMARY MANTLE_GRPC OSMO_GRPC MANTLE_WS OSMO_WS

# Akash mounts the persistent volume root-owned. Re-exec as hermes with proper
# ownership on first boot; idempotent on subsequent boots (no-op when already
# owned correctly + already running as hermes).
if [ "$(id -u)" = "0" ]; then
  HERMES_HOME="/home/hermes/.hermes"
  TEMPLATE_BAKED="/usr/local/share/hermes/config.toml.template"
  # Always overwrite the template from the baked image — config changes
  # ship via image rebuild, not by editing the persistent volume. (RPC
  # URLs come from env vars; structural config like packet_filter or
  # mode.packets settings come from this template.) This is idempotent
  # if the file is already up-to-date.
  mkdir -p "$HERMES_HOME/keys"
  if [ -f "$TEMPLATE_BAKED" ]; then
    cp "$TEMPLATE_BAKED" "$HERMES_HOME/config.toml.template"
  fi
  chown -R hermes:hermes /home/hermes
  exec gosu hermes "$0" "$@"
fi

CONFIG_DIR="${HOME}/.hermes"
KEYS_DIR="${CONFIG_DIR}/keys"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
TEMPLATE_FILE="${CONFIG_DIR}/config.toml.template"
INIT_MARKER="${CONFIG_DIR}/.akash-init-done"

log() { printf '[entrypoint %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

trap 'log "received SIGTERM, forwarding to hermes + proxy"; kill -TERM "${HERMES_PID:-0}" 2>/dev/null || true; kill -TERM "${PROXY_PID:-0}" 2>/dev/null || true; wait "${HERMES_PID:-0}" 2>/dev/null || true; exit 0' TERM INT

mkdir -p "${KEYS_DIR}"

log "rendering config.toml from template (envsubst)"
envsubst < "${TEMPLATE_FILE}" > "${CONFIG_FILE}"

log "hermes config validate"
hermes --config "${CONFIG_FILE}" config validate

if [ ! -f "${INIT_MARKER}" ]; then
  log "first-boot init starting"

  if [ -z "${RELAYER_MNEMONIC:-}" ]; then
    log "ERROR: RELAYER_MNEMONIC env var is empty; cannot restore keys"
    exit 1
  fi

  # hermes expects the 24 mnemonic words on a single line in a file.
  MNEMONIC_FILE="$(mktemp)"
  printf '%s\n' "${RELAYER_MNEMONIC}" > "${MNEMONIC_FILE}"
  chmod 0600 "${MNEMONIC_FILE}"

  log "restoring relayer key for mantle-1"
  hermes --config "${CONFIG_FILE}" keys add \
    --chain mantle-1 \
    --mnemonic-file "${MNEMONIC_FILE}" \
    --key-name relayer \
    --overwrite >/dev/null

  log "restoring relayer key for osmosis-1"
  hermes --config "${CONFIG_FILE}" keys add \
    --chain osmosis-1 \
    --mnemonic-file "${MNEMONIC_FILE}" \
    --key-name relayer \
    --overwrite >/dev/null

  # shred + remove. On Akash provider FS this lives in the persistent volume
  # for ~milliseconds. The mnemonic also lives in the env of THIS process
  # (and the SDL); we unset it below.
  if command -v shred >/dev/null 2>&1; then
    shred -u -n 3 "${MNEMONIC_FILE}" 2>/dev/null || rm -f "${MNEMONIC_FILE}"
  else
    rm -f "${MNEMONIC_FILE}"
  fi

  log "showing keys (sanity)"
  hermes --config "${CONFIG_FILE}" keys list --chain mantle-1  || log "WARN: keys list mantle-1 failed"
  hermes --config "${CONFIG_FILE}" keys list --chain osmosis-1 || log "WARN: keys list osmosis-1 failed"

  touch "${INIT_MARKER}"
  log "first-boot init complete"
else
  log "init marker present, skipping key restore"
fi

# Drop RELAYER_MNEMONIC from the environment of the hermes process tree.
unset RELAYER_MNEMONIC

# Start the mantle-rpc-proxy sidecar if available. It rewrites the
# stub validator pubkey on publicnode's /status so hermes can use
# publicnode's deeper tx_search index for orphan packet recovery.
# Hermes' MANTLE_RPC_PRIMARY in the SDL points at 127.0.0.1:18903.
if command -v mantle-rpc-proxy >/dev/null 2>&1; then
  log "starting mantle-rpc-proxy sidecar on 127.0.0.1:18903"
  mantle-rpc-proxy -addr 127.0.0.1:18903 &
  PROXY_PID=$!
  # Brief readiness wait — proxy starts in <100ms but hermes' first
  # RPC call needs the listener up.
  for _ in 1 2 3 4 5; do
    if (echo > /dev/tcp/127.0.0.1/18903) 2>/dev/null; then break; fi
    sleep 0.2
  done
fi

log "starting hermes (auto-discovery of paths)"
hermes --config "${CONFIG_FILE}" start &
HERMES_PID=$!
wait "${HERMES_PID}"
