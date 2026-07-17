#!/usr/bin/env bash
#
# Elektrine standalone VPN fleet agent (WireGuard).
#
# A DB-free node agent for running WireGuard exit nodes at fleet scale. Instead
# of connecting each node to the central Postgres (which exhausts connections
# and widens the DB's exposure once you have hundreds of nodes), this agent
# talks only to the Elektrine control-plane HTTP API:
#
#   1. registers the node once (bearer: fleet key) and stores server_id + api_key
#   2. every interval: pulls the peer set, applies it to WireGuard, reports
#      bandwidth stats, and sends a heartbeat (bearer: per-node api key)
#
# Interface + NAT setup is handled here when MANAGE_INTERFACE=1 (the default),
# so a fresh VPS needs only WireGuard tools, curl, and jq.
#
# Requires: bash, curl, jq, wg, ip (iproute2). Run as root (needs NET_ADMIN).
#
# Shadowsocks nodes are not covered by this agent; run the bundled Elektrine
# `vpn` container for those (it reconciles ss-server per-port from the DB).

set -euo pipefail

# --- Configuration (environment) ---------------------------------------------

# Control plane base URL, e.g. https://elektrine.example.com  (no trailing /api)
CONTROL_PLANE_URL="${CONTROL_PLANE_URL:-}"

# One-time bootstrap secret; must equal the control plane's
# VPN_FLEET_REGISTRATION_KEY. Only needed until the node is registered.
VPN_FLEET_REGISTRATION_KEY="${VPN_FLEET_REGISTRATION_KEY:-}"

# Node identity / advertised endpoint.
NODE_NAME="${NODE_NAME:-$(hostname)}"
NODE_LOCATION="${NODE_LOCATION:-unknown}"
NODE_COUNTRY_CODE="${NODE_COUNTRY_CODE:-}"
NODE_CITY="${NODE_CITY:-}"
PUBLIC_IP="${PUBLIC_IP:-}"           # autodetected if empty
ENDPOINT_HOST="${ENDPOINT_HOST:-}"   # defaults to PUBLIC_IP when empty
ENDPOINT_PORT="${ENDPOINT_PORT:-51820}"

# WireGuard / runtime.
WG_INTERFACE="${WG_INTERFACE:-wg0}"
LISTEN_PORT="${LISTEN_PORT:-$ENDPOINT_PORT}"
EGRESS_INTERFACE="${EGRESS_INTERFACE:-}"   # autodetected if empty
MANAGE_INTERFACE="${MANAGE_INTERFACE:-1}"  # 1 = create/own wg iface + NAT
POLL_INTERVAL="${POLL_INTERVAL:-60}"       # seconds between reconciles
ACTIVE_WINDOW="${ACTIVE_WINDOW:-180}"      # handshake age (s) counted as online
STATE_DIR="${STATE_DIR:-/var/lib/elektrine-vpn}"

# --- State file paths --------------------------------------------------------

STATE_FILE="${STATE_DIR}/agent.env"
PRIVATE_KEY_FILE="${STATE_DIR}/wg-private.key"
PUBLIC_KEY_FILE="${STATE_DIR}/wg-public.key"

API_BASE=""
SERVER_ID=""
API_KEY=""

# --- Helpers -----------------------------------------------------------------

log() { printf '%s [elektrine-vpn-agent] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

check_deps() {
  require_cmd curl
  require_cmd jq
  require_cmd wg
  if [[ "$MANAGE_INTERFACE" == "1" ]]; then
    require_cmd ip
  fi
}

# curl wrapper. Sets the globals HTTP_STATUS and RESP_BODY. Must be called
# directly (not in a $(...) subshell) so those globals survive to the caller.
HTTP_STATUS=""
RESP_BODY=""
api_call() {
  local method="$1" path="$2" body="${3:-}" auth="$4"
  local url="${API_BASE}${path}"
  local tmp="/tmp/vpn-agent-resp.$$"
  local args=(-sS -m 20 -o "$tmp" -w '%{http_code}' -X "$method" -H "Authorization: Bearer ${auth}")
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' -d "$body")
  fi
  HTTP_STATUS="$(curl "${args[@]}" "$url" 2>/dev/null || echo 000)"
  RESP_BODY="$(cat "$tmp" 2>/dev/null || true)"
  rm -f "$tmp" 2>/dev/null || true
}

detect_public_ip() {
  # Prefer the source IP the kernel would use for outbound traffic; fall back to
  # an external echo service only if that fails.
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')" || true
  if [[ -z "$ip" ]]; then
    ip="$(curl -sS -m 10 https://api.ipify.org 2>/dev/null || true)"
  fi
  printf '%s' "$ip"
}

detect_egress_interface() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# --- Key management ----------------------------------------------------------

ensure_keys() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  if [[ ! -s "$PRIVATE_KEY_FILE" ]]; then
    log "generating WireGuard keypair"
    (umask 077; wg genkey > "$PRIVATE_KEY_FILE")
  fi
  wg pubkey < "$PRIVATE_KEY_FILE" > "$PUBLIC_KEY_FILE"
  chmod 600 "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE"
}

# --- Registration ------------------------------------------------------------

load_state() {
  if [[ -s "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    SERVER_ID="${SERVER_ID:-}"
    API_KEY="${API_KEY:-}"
  fi
}

save_state() {
  umask 077
  cat > "$STATE_FILE" <<EOF
SERVER_ID=${SERVER_ID}
API_KEY=${API_KEY}
EOF
  log "saved node credentials to ${STATE_FILE} (server_id=${SERVER_ID})"
}

register_node() {
  [[ -n "$VPN_FLEET_REGISTRATION_KEY" ]] || die "not registered and VPN_FLEET_REGISTRATION_KEY is unset"

  local public_key endpoint_host body resp
  public_key="$(cat "$PUBLIC_KEY_FILE")"
  endpoint_host="${ENDPOINT_HOST:-$PUBLIC_IP}"

  body="$(jq -n \
    --arg name "$NODE_NAME" \
    --arg location "$NODE_LOCATION" \
    --arg public_ip "$PUBLIC_IP" \
    --arg public_key "$public_key" \
    --arg endpoint_host "$endpoint_host" \
    --argjson endpoint_port "$ENDPOINT_PORT" \
    --arg country_code "$NODE_COUNTRY_CODE" \
    --arg city "$NODE_CITY" \
    '{name:$name, location:$location, public_ip:$public_ip, protocol:"wireguard",
      public_key:$public_key, endpoint_host:$endpoint_host, endpoint_port:$endpoint_port}
     + (if $country_code == "" then {} else {country_code:$country_code} end)
     + (if $city == "" then {} else {city:$city} end)')"

  log "registering node ${NODE_NAME} (${PUBLIC_IP}) with control plane"
  api_call POST "/vpn/register" "$body" "$VPN_FLEET_REGISTRATION_KEY"
  resp="$RESP_BODY"

  case "$HTTP_STATUS" in
    200|201)
      SERVER_ID="$(jq -r '.server_id' <<<"$resp")"
      API_KEY="$(jq -r '.api_key' <<<"$resp")"
      [[ -n "$SERVER_ID" && -n "$API_KEY" && "$API_KEY" != "null" ]] \
        || die "registration response missing server_id/api_key: $resp"
      save_state
      ;;
    409)
      die "public IP already registered but this node has no saved credentials.
Credentials cannot be recovered via fleet bootstrap. Either delete the stale
server record in the admin UI and re-run, or seed ${STATE_FILE} with the
existing SERVER_ID and API_KEY."
      ;;
    401)
      die "registration rejected (401): fleet key invalid or missing"
      ;;
    *)
      die "registration failed (HTTP ${HTTP_STATUS}): $resp"
      ;;
  esac
}

# --- WireGuard interface management ------------------------------------------

interface_up() {
  wg show "$WG_INTERFACE" >/dev/null 2>&1
}

ensure_interface() {
  [[ "$MANAGE_INTERFACE" == "1" ]] || return 0
  interface_up && return 0

  local range="$1" node_addr
  # Node takes .1 of its allocated /24, e.g. 10.8.3.0/24 -> 10.8.3.1/24.
  node_addr="$(range_to_node_addr "$range")"
  [[ -n "$node_addr" ]] || die "could not derive node address from range '${range}'"

  log "bringing up ${WG_INTERFACE} at ${node_addr} (listen ${LISTEN_PORT})"
  ip link add dev "$WG_INTERFACE" type wireguard 2>/dev/null || true
  wg set "$WG_INTERFACE" private-key "$PRIVATE_KEY_FILE" listen-port "$LISTEN_PORT"
  ip address replace "$node_addr" dev "$WG_INTERFACE"
  ip link set "$WG_INTERFACE" up

  enable_forwarding_and_nat "$range"
}

range_to_node_addr() {
  # "10.8.3.0/24" -> "10.8.3.1/24"
  local range="$1" net prefix
  net="${range%/*}"; prefix="${range#*/}"
  [[ "$net" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.[0-9]+$ ]] || return 1
  printf '%s.%s.%s.1/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "$prefix"
}

enable_forwarding_and_nat() {
  local range="$1" egress
  egress="${EGRESS_INTERFACE:-$(detect_egress_interface)}"
  [[ -n "$egress" ]] || { log "WARN: no egress interface detected; skipping NAT"; return 0; }

  sysctl -q -w net.ipv4.ip_forward=1 || true

  if command -v iptables >/dev/null 2>&1; then
    # Idempotent: only add the MASQUERADE rule if it isn't already present.
    if ! iptables -t nat -C POSTROUTING -s "$range" -o "$egress" -j MASQUERADE 2>/dev/null; then
      iptables -t nat -A POSTROUTING -s "$range" -o "$egress" -j MASQUERADE
      log "added NAT MASQUERADE for ${range} via ${egress}"
    fi
    iptables -C FORWARD -i "$WG_INTERFACE" -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -i "$WG_INTERFACE" -j ACCEPT
    iptables -C FORWARD -o "$WG_INTERFACE" -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -o "$WG_INTERFACE" -j ACCEPT
  else
    log "WARN: iptables not found; configure NAT for ${range} via ${egress} yourself"
  fi
}

# --- Reconcile ---------------------------------------------------------------

reconcile() {
  local resp range
  api_call GET "/vpn/${SERVER_ID}/peers" "" "$API_KEY"
  resp="$RESP_BODY"
  if [[ "$HTTP_STATUS" != "200" ]]; then
    log "WARN: peer sync failed (HTTP ${HTTP_STATUS}); keeping current peers"
    return 0
  fi

  range="$(jq -r '.server.internal_ip_range // empty' <<<"$resp")"
  if [[ -n "$range" ]]; then
    ensure_interface "$range"
  fi

  interface_up || { log "WARN: ${WG_INTERFACE} not up; skipping apply"; return 0; }

  apply_peers "$resp"
  report_stats
  send_heartbeat
}

apply_peers() {
  local resp="$1" desired current stale
  # Desired active peers -> "pubkey<TAB>allocated_ip"
  desired="$(jq -r '.peers[]? | [.public_key, (.allocated_ip // "")] | @tsv' <<<"$resp")"

  # Apply / update each desired peer.
  while IFS=$'\t' read -r pubkey allowed; do
    [[ -n "$pubkey" ]] || continue
    [[ -n "$allowed" ]] || continue
    wg set "$WG_INTERFACE" peer "$pubkey" allowed-ips "$allowed" persistent-keepalive 25
  done <<<"$desired"

  # Explicit removals from the snapshot.
  jq -r '.remove_peers[]?.public_key // empty' <<<"$resp" | while read -r pubkey; do
    [[ -n "$pubkey" ]] || continue
    wg set "$WG_INTERFACE" peer "$pubkey" remove 2>/dev/null || true
  done

  # Reconcile drift: drop any peer on the interface the control plane no longer
  # lists as active (covers configs deleted between snapshots).
  current="$(wg show "$WG_INTERFACE" peers 2>/dev/null || true)"
  local desired_keys
  desired_keys="$(cut -f1 <<<"$desired" | sort -u)"
  stale="$(comm -23 <(sort -u <<<"$current") <(printf '%s\n' "$desired_keys") 2>/dev/null || true)"
  while read -r pubkey; do
    [[ -n "$pubkey" ]] || continue
    wg set "$WG_INTERFACE" peer "$pubkey" remove 2>/dev/null || true
  done <<<"$stale"
}

report_stats() {
  local dump peers_json
  dump="$(wg show "$WG_INTERFACE" dump 2>/dev/null | tail -n +2 || true)"
  [[ -n "$dump" ]] || return 0

  # dump columns: pubkey psk endpoint allowed-ips handshake rx tx keepalive
  peers_json="$(awk -F'\t' 'NF>=7 && $1!="" {
      printf "{\"public_key\":\"%s\",\"bytes_received\":%s,\"bytes_sent\":%s,\"last_handshake\":%s},",
             $1, $6, $7, ($5==0?"null":$5)
    }' <<<"$dump")"
  peers_json="[${peers_json%,}]"

  local body
  body="$(jq -n --argjson peers "$peers_json" '{peers:$peers}')"
  api_call POST "/vpn/${SERVER_ID}/stats" "$body" "$API_KEY"
  [[ "$HTTP_STATUS" == "200" ]] || log "WARN: stats push failed (HTTP ${HTTP_STATUS})"
}

send_heartbeat() {
  local now current body
  now="$(date +%s)"
  # Count peers whose last handshake is within the active window.
  current="$(wg show "$WG_INTERFACE" dump 2>/dev/null | tail -n +2 \
    | awk -F'\t' -v now="$now" -v w="$ACTIVE_WINDOW" 'NF>=7 && $5>0 && (now-$5)<=w' | wc -l | tr -d ' ')"
  current="${current:-0}"

  body="$(jq -n --argjson server_id "$SERVER_ID" --argjson current "$current" \
    '{server_id:$server_id, current_users:$current, status:"active"}')"
  api_call POST "/vpn/${SERVER_ID}/heartbeat" "$body" "$API_KEY"
  [[ "$HTTP_STATUS" == "200" ]] || log "WARN: heartbeat failed (HTTP ${HTTP_STATUS})"
}

# --- Main --------------------------------------------------------------------

main() {
  [[ -n "$CONTROL_PLANE_URL" ]] || die "CONTROL_PLANE_URL is required"
  API_BASE="${CONTROL_PLANE_URL%/}/api"

  check_deps

  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(detect_public_ip)"
    [[ -n "$PUBLIC_IP" ]] || die "could not autodetect PUBLIC_IP; set it explicitly"
    log "detected public IP ${PUBLIC_IP}"
  fi

  ensure_keys
  load_state

  if [[ -z "$SERVER_ID" || -z "$API_KEY" ]]; then
    register_node
  else
    log "using saved credentials (server_id=${SERVER_ID})"
  fi

  log "agent online; reconciling every ${POLL_INTERVAL}s"
  trap 'log "shutting down"; exit 0' INT TERM

  while true; do
    reconcile || log "WARN: reconcile cycle errored; retrying next interval"
    sleep "$POLL_INTERVAL"
  done
}

# Only run when executed directly, so tests can source and call functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
