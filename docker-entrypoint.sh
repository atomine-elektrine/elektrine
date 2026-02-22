#!/bin/bash
set -euo pipefail

TOR_HS_DIR="/data/tor/elektrine"
TOR_DATA_DIR="/data/tor/data"
CERTS_DIR="/data/certs"

decode_b64_to_file() {
  local value="$1"
  local destination="$2"
  local label="$3"

  [ -z "$value" ] && return 1

  if printf '%s' "$value" | base64 -d > "${destination}.tmp" 2>/dev/null || \
      printf '%s' "$value" | base64 --decode > "${destination}.tmp" 2>/dev/null; then
    mv "${destination}.tmp" "$destination"
    chmod 600 "$destination"
    echo "Restored ${label} from environment backup."
    return 0
  fi

  rm -f "${destination}.tmp"
  echo "Warning: failed to decode ${label} from environment backup."
  return 1
}

# Create and fix ownership of data directories (volume mount may have wrong perms)
mkdir -p "$TOR_HS_DIR" "$TOR_DATA_DIR" "$CERTS_DIR" 2>/dev/null || true
chmod 700 "$TOR_HS_DIR" 2>/dev/null || true

# Restore Tor hidden-service identity if /data was replaced and backup secrets are available.
if [ ! -s "$TOR_HS_DIR/hs_ed25519_secret_key" ] && [ -n "${ONION_HS_SECRET_KEY_B64:-}" ]; then
  echo "No Tor hidden-service key found; attempting restore from environment backup..."

  decode_b64_to_file "${ONION_HS_SECRET_KEY_B64:-}" "$TOR_HS_DIR/hs_ed25519_secret_key" "Tor secret key" || true
  decode_b64_to_file "${ONION_HS_PUBLIC_KEY_B64:-}" "$TOR_HS_DIR/hs_ed25519_public_key" "Tor public key" || true

  if [ -n "${ONION_HOST:-}" ]; then
    printf '%s\n' "${ONION_HOST}" > "$TOR_HS_DIR/hostname"
    chmod 600 "$TOR_HS_DIR/hostname"
    echo "Restored Tor hostname from ONION_HOST."
  fi
fi

chown -R nobody:nogroup /data 2>/dev/null || true
chmod 700 "$TOR_HS_DIR" 2>/dev/null || true

# Drop to nobody and run the start script
exec su -s /bin/bash nobody -c "/app/start.sh"
