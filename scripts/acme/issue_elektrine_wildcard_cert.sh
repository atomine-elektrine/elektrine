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
# Uses CADDY_EDGE_API_KEY for the internal DNS-01 endpoint.
#
# Optional environment:
#   ACME_DOMAIN                e.g. elektrine.com
#   ELEKTRINE_API_BASE         e.g. https://elektrine.com
#   ELEKTRINE_INTERNAL_API_KEY defaults to CADDY_EDGE_API_KEY
#   ACME_EMAIL           ACME account email, usually from .env.production
#   ACME_HOME            defaults to $HOME/.acme.sh
#   ACME_SH_DOWNLOAD_URL optional acme.sh source URL when acme.sh is absent
#   ACME_SH_SHA256       required when ACME_SH_DOWNLOAD_URL is used
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

validate_env_file() {
  env_file="$1"
  line_no=0

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    case "$line" in
      "" | "#"*) continue ;;
    esac
    if ! printf '%s\n' "$line" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; then
      echo "Invalid env syntax at $env_file:$line_no" >&2
      return 1
    fi
    case "$line" in
      *'$('* | *'`'* | *';'* | *'&&'* | *'||'*)
        echo "Unsafe shell syntax in env file at $env_file:$line_no" >&2
        return 1
        ;;
    esac
  done < "$env_file"
}

if [ -f "$ENV_FILE" ]; then
  validate_env_file "$ENV_FILE"
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

ELEKTRINE_INTERNAL_API_KEY="${ELEKTRINE_INTERNAL_API_KEY:-${CADDY_EDGE_API_KEY:-}}"

if [ -z "$ELEKTRINE_INTERNAL_API_KEY" ]; then
  echo "CADDY_EDGE_API_KEY is required in $ENV_FILE. You can also pass --token=<internal-api-key>." >&2
  exit 1
fi

# Prefer the persistent app-data volume for ACME state so accounts and
# renewal history survive container recreation (a throwaway /root/.acme.sh
# re-registers a fresh CA account on every deploy).
if [ -z "${ACME_HOME:-}" ] && [ -d /data ] && [ -w /data ]; then
  ACME_HOME=/data/acme.sh
fi

ACME_HOME="${ACME_HOME:-$HOME/.acme.sh}"
CERT_DIR="${CERT_DIR:-${CADDY_TLS_MOUNT_DIR:-/opt/elektrine/certs}}"
RELOAD_CMD="${RELOAD_CMD:-docker restart elektrine_caddy_edge}"
ACME_SERVER="${ACME_SERVER:-letsencrypt}"
RENEW_WITHIN_SECONDS="${RENEW_WITHIN_SECONDS:-2592000}"

case "$RELOAD_CMD" in
  "docker restart elektrine_caddy_edge" | \
  "systemctl reload caddy" | \
  "systemctl restart caddy" | \
  "caddy reload --config /etc/caddy/Caddyfile" | \
  "true") ;;
  *)
    echo "Unsafe RELOAD_CMD. Use a supported fixed reload command instead of an arbitrary shell string." >&2
    exit 1
    ;;
esac

# Deploys run this on every pass: when the installed cert is comfortably
# inside its validity window there is nothing to do, and skipping early
# avoids depending on the app API (which may still be booting) at all.
installed_cert="$CERT_DIR/$ACME_DOMAIN.fullchain.pem"

if [ -f "$installed_cert" ] && command -v openssl >/dev/null 2>&1 &&
  openssl x509 -in "$installed_cert" -noout -checkend "$RENEW_WITHIN_SECONDS" >/dev/null 2>&1; then
  echo "Wildcard cert for $ACME_DOMAIN is valid for more than $((RENEW_WITHIN_SECONDS / 86400)) days; skipping issuance."
  exit 0
fi

if [ ! -x "$ACME_HOME/acme.sh" ]; then
  if ! command -v curl >/dev/null 2>&1; then
    echo "acme.sh not found at $ACME_HOME/acme.sh and curl is not installed" >&2
    exit 1
  fi

  if [ -z "${ACME_SH_DOWNLOAD_URL:-}" ] || [ -z "${ACME_SH_SHA256:-}" ]; then
    echo "acme.sh is missing. Install it first, or set ACME_SH_DOWNLOAD_URL and ACME_SH_SHA256 to a pinned release." >&2
    exit 1
  fi

  mkdir -p "$ACME_HOME"
  curl -fsSL "$ACME_SH_DOWNLOAD_URL" -o "$ACME_HOME/acme.sh"
  actual_sha="$(sha256sum "$ACME_HOME/acme.sh" | awk '{print $1}')"

  if [ "$actual_sha" != "$ACME_SH_SHA256" ]; then
    rm -f "$ACME_HOME/acme.sh"
    echo "Downloaded acme.sh checksum mismatch" >&2
    exit 1
  fi

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
  "$ACME_HOME/acme.sh" --register-account --home "$ACME_HOME" --server "$ACME_SERVER" -m "$ACME_EMAIL"
fi

export ELEKTRINE_API_BASE ELEKTRINE_INTERNAL_API_KEY

# The DNS-01 hook creates TXT records through the app API; after a deploy
# recreates containers the app may still be booting, so wait for it.
api_attempts=0
until curl -fsS -o /dev/null --max-time 5 "$ELEKTRINE_API_BASE/health"; do
  api_attempts=$((api_attempts + 1))

  if [ "$api_attempts" -ge 24 ]; then
    echo "Elektrine API at $ELEKTRINE_API_BASE did not become ready; aborting issuance." >&2
    exit 1
  fi

  echo "Waiting for Elektrine API at $ELEKTRINE_API_BASE ($api_attempts/24)..."
  sleep 5
done

# acme.sh exits 2 when the cert exists and is not yet due for renewal;
# that is a success for our purposes, not a deploy failure.
issue_rc=0
"$ACME_HOME/acme.sh" --issue \
  --home "$ACME_HOME" \
  --server "$ACME_SERVER" \
  --dns dns_elektrine \
  -d "$ACME_DOMAIN" \
  -d "*.$ACME_DOMAIN" \
  --keylength ec-256 || issue_rc=$?

if [ "$issue_rc" -ne 0 ] && [ "$issue_rc" -ne 2 ]; then
  exit "$issue_rc"
fi

"$ACME_HOME/acme.sh" --install-cert \
  --home "$ACME_HOME" \
  -d "$ACME_DOMAIN" \
  --ecc \
  --fullchain-file "$CERT_DIR/$ACME_DOMAIN.fullchain.pem" \
  --key-file "$CERT_DIR/$ACME_DOMAIN.key.pem" \
  --reloadcmd "$RELOAD_CMD"
