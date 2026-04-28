#!/usr/bin/env bash
# Materialize the GitHub Secrets for this repo into a local working dir
# so deploy.sh / redeploy can run from a fresh checkout. Run from inside
# a GitHub Actions workflow (where ${{ secrets.* }} is exposed as env)
# OR locally after `gh auth login` (the helper falls back to the local
# /home/deepanshutr/.relayer-akash/ + ~/.akash/ keyring already on disk).
#
# Outputs (relative to $TARGET_DIR, default $HOME):
#   .relayer-akash/mnemonic.enc
#   .relayer-akash/.encryption_key
#   .relayer-akash/addresses.json
#   .akash/keyring-test/*  (autonomy + deployer keys)
#
# Env in (must be set by caller — never read from disk):
#   RELAYER_MNEMONIC_ENC_BASE64
#   RELAYER_ENCRYPTION_KEY_BASE64
#   RELAYER_ADDRESSES_JSON_BASE64
#   AKASH_KEYRING_TGZ_BASE64
#
# Env out: nothing. Exits 1 on any decode failure.

set -euo pipefail

TARGET_DIR="${TARGET_DIR:-$HOME}"
WALLET_DIR="${TARGET_DIR}/.relayer-akash"
AKASH_DIR="${TARGET_DIR}/.akash"

log() { printf '[load-secrets %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

need() {
  local var="$1"
  [ -n "${!var:-}" ] || fail "env var $var is empty"
}

need RELAYER_MNEMONIC_ENC_BASE64
need RELAYER_ENCRYPTION_KEY_BASE64
need RELAYER_ADDRESSES_JSON_BASE64
need AKASH_KEYRING_TGZ_BASE64

mkdir -p "$WALLET_DIR" "$AKASH_DIR"
chmod 700 "$WALLET_DIR" "$AKASH_DIR"
umask 0077

log "writing $WALLET_DIR/mnemonic.enc"
echo "$RELAYER_MNEMONIC_ENC_BASE64" | base64 -d > "$WALLET_DIR/mnemonic.enc"
chmod 600 "$WALLET_DIR/mnemonic.enc"

log "writing $WALLET_DIR/.encryption_key"
echo "$RELAYER_ENCRYPTION_KEY_BASE64" | base64 -d > "$WALLET_DIR/.encryption_key"
chmod 600 "$WALLET_DIR/.encryption_key"

log "writing $WALLET_DIR/addresses.json"
echo "$RELAYER_ADDRESSES_JSON_BASE64" | base64 -d > "$WALLET_DIR/addresses.json"
chmod 644 "$WALLET_DIR/addresses.json"

log "extracting AKASH_KEYRING_TGZ_BASE64 → $AKASH_DIR/keyring-test/"
TGZ=$(mktemp --suffix=.tgz)
echo "$AKASH_KEYRING_TGZ_BASE64" | base64 -d > "$TGZ"
tar -xzf "$TGZ" -C "$AKASH_DIR"
chmod 700 "$AKASH_DIR/keyring-test"
chmod 600 "$AKASH_DIR/keyring-test"/*
shred -u -n 3 "$TGZ" 2>/dev/null || rm -f "$TGZ"

log "verifying:"
log "  mnemonic.enc:    $(stat -c '%s bytes' "$WALLET_DIR/mnemonic.enc")"
log "  encryption_key:  $(stat -c '%s bytes' "$WALLET_DIR/.encryption_key")"
log "  addresses.json:  $(stat -c '%s bytes' "$WALLET_DIR/addresses.json")"
log "  keyring entries: $(ls "$AKASH_DIR/keyring-test" | wc -l)"

# Verify mnemonic decrypts cleanly (sanity: does AES-GCM nonce + key decrypt?)
if command -v python3 >/dev/null 2>&1 && python3 -c "from cryptography.hazmat.primitives.ciphers.aead import AESGCM" 2>/dev/null; then
  python3 - <<EOF
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
key = open("$WALLET_DIR/.encryption_key","rb").read()
blob = open("$WALLET_DIR/mnemonic.enc","rb").read()
mn = AESGCM(key).decrypt(blob[:12], blob[12:], None).decode()
words = len(mn.split())
print(f"[load-secrets] mnemonic decrypts cleanly ({words} words)")
EOF
else
  log "WARN: python3 cryptography not available, skipping decrypt sanity check"
fi

log "done. Use deploy.sh as normal — it reads from \$WALLET_DIR + \$AKASH_DIR."
