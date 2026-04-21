#!/bin/bash
set -euo pipefail

TOR_HS_DIR="/data/tor/elektrine"
TOR_BACKUP_ENV="/data/certs/onion-key-backup.env"
ONION_TLS_DIR="/data/certs/live"
ONION_TLS_CERT="$ONION_TLS_DIR/onion-cert.pem"
ONION_TLS_KEY="$ONION_TLS_DIR/onion-key.pem"
ONION_TLS_HOST_CACHE="$ONION_TLS_DIR/onion-hostname.txt"
VPN_DATA_DIR="/data/vpn"
VPN_PRIVATE_KEY_FILE="$VPN_DATA_DIR/wg-private.key"
ROLE="${1:-${ELEKTRINE_RUNTIME_ROLE:-all}}"

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

selfhost_protocols() {
  local raw_protocols="${VPN_SELFHOST_PROTOCOLS:-${VPN_SELFHOST_PROTOCOL:-wireguard}}"
  raw_protocols="${raw_protocols//,/ }"
  printf '%s\n' "$raw_protocols" | xargs -n1 | awk '!seen[$0]++'
}

configure_role() {
  local role="$1"
  local web_default="true"
  local jobs_default="true"
  local mail_default="true"
  local tor_default="false"

  case "$role" in
    all)
      ;;
    app|edge)
      jobs_default="true"
      ;;
    web)
      jobs_default="false"
      mail_default="false"
      tor_default="false"
      ;;
    worker)
      web_default="false"
      mail_default="false"
      tor_default="false"
      ;;
    mail)
      web_default="false"
      jobs_default="false"
      tor_default="false"
      ;;
    vpn)
      web_default="false"
      jobs_default="false"
      mail_default="false"
      tor_default="false"
      ;;
    *)
      echo "Unknown Elektrine runtime role: $role" >&2
      exit 1
      ;;
  esac

  export ELEKTRINE_RUNTIME_ROLE="$role"
  export ELEKTRINE_ENABLE_WEB="${ELEKTRINE_ENABLE_WEB:-$web_default}"
  export ELEKTRINE_ENABLE_JOBS="${ELEKTRINE_ENABLE_JOBS:-$jobs_default}"
  export ELEKTRINE_ENABLE_MAIL="${ELEKTRINE_ENABLE_MAIL:-$mail_default}"
  export ELEKTRINE_ENABLE_TOR="${ELEKTRINE_ENABLE_TOR:-$tor_default}"
}

derive_vpn_public_key() {
  if [ -n "${VPN_SELFHOST_PUBLIC_KEY:-}" ] || [ -z "${VPN_SELFHOST_PRIVATE_KEY:-}" ]; then
    return
  fi

  if ! command -v wg >/dev/null 2>&1; then
    echo "WireGuard tools are not installed; cannot derive VPN_SELFHOST_PUBLIC_KEY" >&2
    return
  fi

  export VPN_SELFHOST_PUBLIC_KEY
  VPN_SELFHOST_PUBLIC_KEY="$(printf '%s' "$VPN_SELFHOST_PRIVATE_KEY" | wg pubkey | tr -d '\r\n')"
}

ensure_vpn_private_key() {
  if [ -n "${VPN_SELFHOST_PRIVATE_KEY:-}" ]; then
    return
  fi

  mkdir -p "$VPN_DATA_DIR"
  chmod 700 "$VPN_DATA_DIR"

  if [ -s "$VPN_PRIVATE_KEY_FILE" ]; then
    export VPN_SELFHOST_PRIVATE_KEY
    VPN_SELFHOST_PRIVATE_KEY="$(tr -d '\r\n' < "$VPN_PRIVATE_KEY_FILE")"
    return
  fi

  if ! command -v wg >/dev/null 2>&1; then
    echo "WireGuard tools are not installed; cannot generate VPN_SELFHOST_PRIVATE_KEY" >&2
    exit 1
  fi

  umask 077
  wg genkey | tee "$VPN_PRIVATE_KEY_FILE" >/dev/null
  export VPN_SELFHOST_PRIVATE_KEY
  VPN_SELFHOST_PRIVATE_KEY="$(tr -d '\r\n' < "$VPN_PRIVATE_KEY_FILE")"
  echo "Generated WireGuard private key at $VPN_PRIVATE_KEY_FILE"
}

detect_vpn_public_ip() {
  local detected=""

  if [ -n "${VPN_SELFHOST_PUBLIC_IP:-}" ] || [ -n "${VPN_SELFHOST_ENDPOINT_HOST:-}" ]; then
    return
  fi

  if command -v ip >/dev/null 2>&1; then
    detected="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
  fi

  if [ -n "$detected" ]; then
    export VPN_SELFHOST_PUBLIC_IP
    VPN_SELFHOST_PUBLIC_IP="$detected"
    echo "Detected VPN_SELFHOST_PUBLIC_IP=$VPN_SELFHOST_PUBLIC_IP"
  else
    echo "Warning: could not detect VPN_SELFHOST_PUBLIC_IP; set VPN_SELFHOST_ENDPOINT_HOST or VPN_SELFHOST_PUBLIC_IP if client configs need a reachable endpoint" >&2
  fi
}

configure_wireguard_interface() {
  local interface="${VPN_SELFHOST_WG_INTERFACE:-wg0}"
  local address="${VPN_SELFHOST_ADDRESS:-10.8.0.1/24}"
  local listen_port="${VPN_SELFHOST_LISTEN_PORT:-443}"
  local mtu="${VPN_SELFHOST_LINK_MTU:-}"
  local private_key_file

  if [ -z "${VPN_SELFHOST_PRIVATE_KEY:-}" ]; then
    echo "VPN_SELFHOST_PRIVATE_KEY is required for the vpn runtime role" >&2
    exit 1
  fi

  if ! command -v wg >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1; then
    echo "wireguard-tools and iproute2 are required for the vpn runtime role" >&2
    exit 1
  fi

  private_key_file="$(mktemp)"
  trap 'rm -f "$private_key_file"' RETURN
  umask 077
  printf '%s\n' "$VPN_SELFHOST_PRIVATE_KEY" > "$private_key_file"

  if ! ip link show dev "$interface" >/dev/null 2>&1; then
    ip link add dev "$interface" type wireguard
  fi

  wg set "$interface" private-key "$private_key_file" listen-port "$listen_port"
  ip address replace "$address" dev "$interface"

  if [ -n "$mtu" ]; then
    ip link set mtu "$mtu" up dev "$interface"
  else
    ip link set up dev "$interface"
  fi
}

configure_shadowsocks_backend() {
  mkdir -p "$VPN_DATA_DIR"
  chmod 700 "$VPN_DATA_DIR"
  export VPN_SELFHOST_PUBLIC_KEY="${VPN_SELFHOST_PUBLIC_KEY:-shadowsocks}"

  if [ -z "${VPN_SELFHOST_PUBLIC_IP:-}" ] && [ -z "${VPN_SELFHOST_ENDPOINT_HOST:-}" ]; then
    detect_vpn_public_ip
  fi
}

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

configure_role "$ROLE"

if [ "$ROLE" = "vpn" ]; then
  while IFS= read -r protocol; do
    [ -z "$protocol" ] && continue

    if [ "$protocol" = "shadowsocks" ]; then
      configure_shadowsocks_backend
    else
      ensure_vpn_private_key
      derive_vpn_public_key
      detect_vpn_public_ip
      configure_wireguard_interface
    fi
  done < <(selfhost_protocols)
fi

if is_truthy "$ELEKTRINE_ENABLE_TOR"; then
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
else
  echo "Skipping Tor for role: $ROLE"
fi

echo "Starting Elektrine role: $ROLE"
if is_truthy "$ELEKTRINE_ENABLE_WEB"; then
  export PHX_SERVER=true
else
  unset PHX_SERVER || true
fi
RELEASE_NAME="${RELEASE_NAME:-elektrine}"
exec "/app/bin/${RELEASE_NAME}" start
