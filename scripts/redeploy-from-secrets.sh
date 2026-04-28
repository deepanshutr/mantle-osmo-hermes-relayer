#!/usr/bin/env bash
# End-to-end redeploy from GH Secrets. Designed to be invoked by the
# .github/workflows/redeploy.yml workflow but also runs locally if the
# right env vars are set (`gh auth login` + `gh secret list` + manual
# export). Idempotent: skips deploy if no SDL change since last run.
#
# Steps:
#   1. load-secrets.sh hydrates ~/.relayer-akash/ + ~/.akash/keyring-test/
#   2. Install provider-services (if missing)
#   3. Run deploy.sh — switches to update mode if state file has DSEQ
#
# Env in:
#   GHCR_PAT, RELAYER_MNEMONIC_ENC_BASE64, RELAYER_ENCRYPTION_KEY_BASE64,
#   RELAYER_ADDRESSES_JSON_BASE64, AKASH_KEYRING_TGZ_BASE64

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(dirname "$SCRIPT_DIR")"
log() { printf '[redeploy %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# 1. Materialize secrets
log "step 1: load-secrets"
"$SCRIPT_DIR/load-secrets.sh"

# 2. provider-services binary
PROV="${PROVIDER_SERVICES:-$HOME/go/bin/provider-services}"
if [ ! -x "$PROV" ]; then
  log "step 2: provider-services not found at $PROV — installing v0.12.0 via docker"
  # On Ubuntu 22.04 the v0.12.0 binary needs glibc 2.39 → fall back to docker.
  # In CI (ubuntu-latest = 22.04+) we usually have the right glibc; try direct first.
  if curl -sSL https://github.com/akash-network/provider/releases/download/v0.12.0/provider-services_0.12.0_linux_amd64.tar.gz \
        | tar -xzC /tmp provider-services 2>/dev/null; then
    sudo mv /tmp/provider-services /usr/local/bin/provider-services
    PROV="/usr/local/bin/provider-services"
  else
    log "FATAL: cannot install provider-services in this environment"; exit 1
  fi
fi
log "step 2: provider-services at $PROV"
export PROVIDER_SERVICES="$PROV"

# 3. Login to ghcr (image push only happens if we built; deploy.sh doesn't need this
# directly since it injects __GHCR_TOKEN__ into the SDL via `gh auth token`).
# But CI's `gh` may not be authed — set GH_TOKEN from GHCR_PAT if so.
if ! gh auth status >/dev/null 2>&1; then
  export GH_TOKEN="${GHCR_PAT:?GHCR_PAT not set}"
  log "step 3: configured gh CLI from GHCR_PAT"
fi

# 4. Run deploy.sh (it auto-switches to update mode via state file)
log "step 4: running deploy.sh"
"$PKG_DIR/deploy.sh"

log "redeploy complete"
