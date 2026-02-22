#!/bin/bash
set -euo pipefail

TOR_HS_DIR="/data/tor/elektrine"
TOR_BACKUP_ENV="/data/certs/onion-key-backup.env"
ONION_TLS_DIR="/data/certs/live"
ONION_TLS_CERT="$ONION_TLS_DIR/onion-cert.pem"
ONION_TLS_KEY="$ONION_TLS_DIR/onion-key.pem"
ONION_TLS_HOST_CACHE="$ONION_TLS_DIR/onion-hostname.txt"

base64_no_wrap() {
  local file_path="$1"

  if base64 -w 0 "$file_path" >/dev/null 2>&1; then
    base64 -w 0 "$file_path"
  else
    base64 "$file_path" | tr -d '\n'
  fi
}

write_tor_backup_snapshot() {
  if [ ! -s "$TOR_HS_DIR/hs_ed25519_secret_key" ] || [ ! -s "$TOR_HS_DIR/hs_ed25519_public_key" ] || [ ! -s "$TOR_HS_DIR/hostname" ]; then
    return
  fi

  local onion_host
  onion_host="$(tr -d '\r\n' < "$TOR_HS_DIR/hostname")"

  umask 077
  cat > "$TOR_BACKUP_ENV" <<EOF
ONION_HOST=$onion_host
ONION_HS_SECRET_KEY_B64=$(base64_no_wrap "$TOR_HS_DIR/hs_ed25519_secret_key")
ONION_HS_PUBLIC_KEY_B64=$(base64_no_wrap "$TOR_HS_DIR/hs_ed25519_public_key")
EOF
  chmod 600 "$TOR_BACKUP_ENV"
  echo "Updated Tor key backup snapshot: $TOR_BACKUP_ENV"
}

write_onion_tls_cert() {
  if [ ! -s "$TOR_HS_DIR/hostname" ]; then
    return
  fi

  local onion_host
  onion_host="$(tr -d '\r\n' < "$TOR_HS_DIR/hostname")"

  if [ -z "$onion_host" ]; then
    return
  fi

  mkdir -p "$ONION_TLS_DIR"
  chmod 700 "$ONION_TLS_DIR"

  local cached_onion_host=""
  if [ -f "$ONION_TLS_HOST_CACHE" ]; then
    cached_onion_host="$(tr -d '\r\n' < "$ONION_TLS_HOST_CACHE")"
  fi

  if [ -s "$ONION_TLS_CERT" ] && [ -s "$ONION_TLS_KEY" ] && [ "$cached_onion_host" = "$onion_host" ]; then
    return
  fi

  echo "Generating TLS certificate for onion host..."

  if ! openssl req \
    -x509 \
    -newkey rsa:2048 \
    -sha256 \
    -days 825 \
    -nodes \
    -subj "/CN=$onion_host" \
    -addext "subjectAltName=DNS:$onion_host" \
    -keyout "$ONION_TLS_KEY" \
    -out "$ONION_TLS_CERT" >/dev/null 2>&1; then
    # Fallback for OpenSSL variants that do not support -addext
    openssl req \
      -x509 \
      -newkey rsa:2048 \
      -sha256 \
      -days 825 \
      -nodes \
      -subj "/CN=$onion_host" \
      -keyout "$ONION_TLS_KEY" \
      -out "$ONION_TLS_CERT" >/dev/null 2>&1
  fi

  printf '%s\n' "$onion_host" > "$ONION_TLS_HOST_CACHE"
  chmod 600 "$ONION_TLS_CERT" "$ONION_TLS_KEY" "$ONION_TLS_HOST_CACHE"
  echo "Updated onion TLS certificate: $ONION_TLS_CERT"
}

# Start Tor in background (it will run as the current user - nobody)
echo "Starting Tor..."
tor -f /etc/tor/torrc &
TOR_PID=$!

# Wait for Tor to generate the onion address
for i in {1..60}; do
  if [ -f "$TOR_HS_DIR/hostname" ]; then
    echo "Onion address: $(cat "$TOR_HS_DIR/hostname")"
    write_tor_backup_snapshot
    write_onion_tls_cert
    break
  fi
  # Check if Tor is still running
  if ! kill -0 $TOR_PID 2>/dev/null; then
    echo "Tor process exited, continuing without onion service"
    break
  fi
  echo "Waiting for Tor to initialize... ($i/60)"
  sleep 1
done

# Start Phoenix app
echo "Starting Phoenix..."
export PHX_SERVER=true
RELEASE_NAME="${RELEASE_NAME:-elektrine}"
exec "/app/bin/${RELEASE_NAME}" start
