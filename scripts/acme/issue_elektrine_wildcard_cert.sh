#!/usr/bin/env sh
set -eu

# Issues and installs an apex + wildcard certificate using acme.sh and
# Elektrine DNS for DNS-01 challenges.
#
# By default this loads .env.production and infers:
#   ACME_DOMAIN        from PRIMARY_DOMAIN or CADDY_MANAGED_SITE_1
#   ELEKTRINE_API_BASE as https://$PHX_HOST or https://$ACME_DOMAIN
#   CERT_DIR           from CADDY_TLS_MOUNT_DIR
#
# Uses PHOENIX_API_KEY or CADDY_EDGE_API_KEY for the internal DNS-01 endpoint.
#
# Optional environment:
#   ACME_DOMAIN                e.g. elektrine.com
#   ELEKTRINE_API_BASE         e.g. https://elektrine.com
#   ELEKTRINE_INTERNAL_API_KEY defaults to CADDY_EDGE_API_KEY or PHOENIX_API_KEY
#   ACME_EMAIL           ACME account email, usually from .env.production
#   ACME_HOME            defaults to $HOME/.acme.sh
#   CERT_DIR             defaults to /opt/elektrine/certs
#   ENV_FILE             defaults to .env.production when present
#   RELOAD_CMD           defaults to docker restart elektrine_caddy_edge

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.production}"

for arg in "$@"; do
  case "$arg" in
    --env-file=*) ENV_FILE="${arg#*=}" ;;
  esac
done

if [ -f "$ENV_FILE" ]; then
  set +u
  set -a
  . "$ENV_FILE"
  set +a
  set -u
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --domain=*) ACME_DOMAIN="${1#*=}" ;;
    --api-base=*) ELEKTRINE_API_BASE="${1#*=}" ;;
    --token=*) ELEKTRINE_INTERNAL_API_KEY="${1#*=}" ;;
    --cert-dir=*) CERT_DIR="${1#*=}" ;;
    --reload-cmd=*) RELOAD_CMD="${1#*=}" ;;
    --env-file=*) ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

infer_domain_from_sites() {
  site_values="$1"

  for host in $site_values; do
    host="${host#https://}"
    host="${host#http://}"
    host="${host%%/*}"
    host="${host#*.}"

    if [ -n "$host" ]; then
      printf '%s' "$host"
      return 0
    fi
  done

  return 1
}

ACME_DOMAIN="${ACME_DOMAIN:-${PRIMARY_DOMAIN:-}}"

if [ -z "$ACME_DOMAIN" ] && [ -n "${CADDY_MANAGED_SITE_1:-}" ]; then
  ACME_DOMAIN="$(infer_domain_from_sites "$CADDY_MANAGED_SITE_1")" || ACME_DOMAIN=""
fi

if [ -z "$ACME_DOMAIN" ] && [ -n "${PHX_HOST:-}" ]; then
  ACME_DOMAIN="$PHX_HOST"
fi

if [ -z "$ACME_DOMAIN" ]; then
  echo "ACME_DOMAIN could not be inferred. Set PRIMARY_DOMAIN, CADDY_MANAGED_SITE_1, or pass --domain=example.com." >&2
  exit 1
fi

if [ -z "${ELEKTRINE_API_BASE:-}" ]; then
  ELEKTRINE_API_BASE="https://${PHX_HOST:-$ACME_DOMAIN}"
fi

ELEKTRINE_INTERNAL_API_KEY="${ELEKTRINE_INTERNAL_API_KEY:-${CADDY_EDGE_API_KEY:-${PHOENIX_API_KEY:-}}}"

if [ -z "$ELEKTRINE_INTERNAL_API_KEY" ]; then
  echo "PHOENIX_API_KEY or CADDY_EDGE_API_KEY is required in $ENV_FILE. You can also pass --token=<internal-api-key>." >&2
  exit 1
fi

ACME_HOME="${ACME_HOME:-$HOME/.acme.sh}"
CERT_DIR="${CERT_DIR:-${CADDY_TLS_MOUNT_DIR:-/opt/elektrine/certs}}"
RELOAD_CMD="${RELOAD_CMD:-docker restart elektrine_caddy_edge}"

if [ ! -x "$ACME_HOME/acme.sh" ]; then
  if ! command -v curl >/dev/null 2>&1; then
    echo "acme.sh not found at $ACME_HOME/acme.sh and curl is not installed" >&2
    exit 1
  fi

  mkdir -p "$ACME_HOME"
  curl -fsSL https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh -o "$ACME_HOME/acme.sh"
  chmod 700 "$ACME_HOME/acme.sh"

  if [ -n "${ACME_EMAIL:-}" ]; then
    "$ACME_HOME/acme.sh" --install --home "$ACME_HOME" --no-cron --accountemail "$ACME_EMAIL"
  else
    "$ACME_HOME/acme.sh" --install --home "$ACME_HOME" --no-cron
  fi
fi

mkdir -p "$ACME_HOME/dnsapi" "$CERT_DIR"
cp "$SCRIPT_DIR/dns_elektrine.sh" "$ACME_HOME/dnsapi/dns_elektrine.sh"
chmod 700 "$ACME_HOME/dnsapi/dns_elektrine.sh"

if [ -n "${ACME_EMAIL:-}" ]; then
  "$ACME_HOME/acme.sh" --register-account -m "$ACME_EMAIL"
fi

export ELEKTRINE_API_BASE ELEKTRINE_INTERNAL_API_KEY

"$ACME_HOME/acme.sh" --issue \
  --dns dns_elektrine \
  -d "$ACME_DOMAIN" \
  -d "*.$ACME_DOMAIN" \
  --keylength ec-256

"$ACME_HOME/acme.sh" --install-cert \
  -d "$ACME_DOMAIN" \
  --ecc \
  --fullchain-file "$CERT_DIR/$ACME_DOMAIN.fullchain.pem" \
  --key-file "$CERT_DIR/$ACME_DOMAIN.key.pem" \
  --reloadcmd "$RELOAD_CMD"
