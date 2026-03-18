#!/bin/bash
set -euo pipefail

APP_NAME="${1:-elektrine}"
HS_DIR="/data/tor/elektrine"

tmp_file="$(mktemp)"
cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT

fly ssh console -a "$APP_NAME" -C "sh -lc 'base64 -w0 $HS_DIR/hs_ed25519_secret_key; echo; base64 -w0 $HS_DIR/hs_ed25519_public_key; echo; tr -d \"\\r\\n\" < $HS_DIR/hostname'" > "$tmp_file"

onion_secret_key_b64="$(sed -n '1p' "$tmp_file")"
onion_public_key_b64="$(sed -n '2p' "$tmp_file")"
onion_host="$(sed -n '3p' "$tmp_file")"

if [ -z "$onion_secret_key_b64" ] || [ -z "$onion_public_key_b64" ] || [ -z "$onion_host" ]; then
  echo "Failed to fetch Tor key material from app '$APP_NAME'." >&2
  exit 1
fi

fly secrets set -a "$APP_NAME" \
  ONION_HS_SECRET_KEY_B64="$onion_secret_key_b64" \
  ONION_HS_PUBLIC_KEY_B64="$onion_public_key_b64" \
  ONION_HOST="$onion_host"

echo "Synced onion backup secrets for '$APP_NAME': $onion_host"
