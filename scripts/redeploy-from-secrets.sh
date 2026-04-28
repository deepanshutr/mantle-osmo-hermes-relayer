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
# Akash publishes .zip / .deb / .rpm (no .tar.gz). The .deb is the cleanest
# install path on ubuntu-latest runners — it lays the binary at
# /usr/bin/provider-services and brings its own dependency declarations.
PROV="${PROVIDER_SERVICES:-$HOME/go/bin/provider-services}"
PROV_VERSION="${PROVIDER_SERVICES_VERSION:-0.12.0}"
if [ ! -x "$PROV" ]; then
  log "step 2: provider-services not found at $PROV — installing v$PROV_VERSION"
  TMPDEB="$(mktemp --suffix=.deb)"
  URL="https://github.com/akash-network/provider/releases/download/v${PROV_VERSION}/provider-services_${PROV_VERSION}_linux_amd64.deb"
  if curl -fsSL "$URL" -o "$TMPDEB" && sudo dpkg -i "$TMPDEB" >/dev/null 2>&1; then
    rm -f "$TMPDEB"
    PROV="$(command -v provider-services)"
  else
    rm -f "$TMPDEB"
    # Fallback: .zip extract — works without sudo, useful for non-root
    # environments and as a sanity path if dpkg is unhappy.
    TMPZIP="$(mktemp --suffix=.zip)"
    URL_ZIP="https://github.com/akash-network/provider/releases/download/v${PROV_VERSION}/provider-services_${PROV_VERSION}_linux_amd64.zip"
    if curl -fsSL "$URL_ZIP" -o "$TMPZIP" && unzip -o -q "$TMPZIP" provider-services -d /tmp; then
      sudo install -m 0755 /tmp/provider-services /usr/local/bin/provider-services
      rm -f /tmp/provider-services "$TMPZIP"
      PROV="/usr/local/bin/provider-services"
    else
      rm -f "$TMPZIP"
      log "FATAL: cannot install provider-services v$PROV_VERSION (deb + zip both failed)"
      exit 1
    fi
  fi
fi
log "step 2: provider-services at $PROV ($($PROV version 2>&1 | head -1))"
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
