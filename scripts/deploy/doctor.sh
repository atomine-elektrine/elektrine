#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$ROOT_DIR/.env.production"
DOCKER_BIN=(docker)
ERRORS=0
WARNINGS=0

usage() {
  cat <<'EOF'
Usage: scripts/deploy/doctor.sh [--env-file .env.production]

Validates the common Docker self-hosting failure points before deploy.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

check_ok() {
  printf 'ok: %s\n' "$1"
}

check_warn() {
  WARNINGS=$((WARNINGS + 1))
  printf 'warn: %s\n' "$1" >&2
}

check_error() {
  ERRORS=$((ERRORS + 1))
  printf 'error: %s\n' "$1" >&2
}

present() {
  [[ -n "${1:-}" ]]
}

truthy() {
  [[ "${1:-false}" =~ ^(1|true|TRUE|yes|YES)$ ]]
}

url_host() {
  local value="$1"

  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%%:*}"
  printf '%s' "$value"
}

has_profile() {
  local wanted="$1"
  local profile=""

  for profile in ${DOCKER_PROFILES:-caddy}; do
    if [[ "$profile" == "$wanted" ]]; then
      return 0
    fi
  done

  return 1
}

host_path_exists() {
  local path="$1"

  [[ "$path" == /* && -e "$path" ]]
}

validate_env_file() {
  local env_file="$1"
  local line=""
  local line_no=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      check_error "invalid env syntax at $env_file:$line_no"
      return 1
    fi
    if [[ "$line" == *'$('* || "$line" == *'`'* || "$line" == *';'* || "$line" == *'&&'* || "$line" == *'||'* ]]; then
      check_error "unsafe shell syntax in env file at $env_file:$line_no"
      return 1
    fi
  done < "$env_file"
}

if [[ ! -f "$ENV_FILE" ]]; then
  check_error "env file does not exist: $ENV_FILE"
  echo "Hint: scripts/deploy/generate_env.sh --domain example.com --email admin@example.com" >&2
  exit 1
fi

validate_env_file "$ENV_FILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

check_ok "loaded $ENV_FILE"

for required in PRIMARY_DOMAIN DB_PASSWORD ELEKTRINE_MASTER_SECRET; do
  if present "${!required:-}"; then
    check_ok "$required is set"
  else
    check_error "$required is required"
  fi
done

if [[ "${DB_PASSWORD:-}" == "change-me" ]]; then
  check_error "DB_PASSWORD is still the placeholder value"
fi

if [[ "${ELEKTRINE_MASTER_SECRET:-}" == "replace-with-long-random-secret" ]]; then
  check_error "ELEKTRINE_MASTER_SECRET is still the placeholder value"
fi

if has_profile caddy; then
  if present "${ACME_EMAIL:-}"; then
    check_ok "ACME_EMAIL is set for Caddy"
  else
    check_warn "Caddy profile is enabled without ACME_EMAIL"
  fi
fi

if [[ "${CADDY_MANAGED_SITE_1:-}" == *"*."* ]]; then
  if present "${CADDY_MANAGED_SITE_1_CERT_PATH:-}" && present "${CADDY_MANAGED_SITE_1_KEY_PATH:-}"; then
    check_ok "wildcard site 1 has external cert paths"
  else
    check_error "CADDY_MANAGED_SITE_1 has wildcard hosts but no cert/key paths"
  fi

  if truthy "${ACME_WILDCARD_RENEWAL_ENABLED:-false}"; then
    check_ok "wildcard renewal is enabled"
  else
    check_warn "wildcard hosts are configured but ACME_WILDCARD_RENEWAL_ENABLED is not true"
  fi
fi

if [[ "${CADDY_MANAGED_SITE_2:-}" == *"*."* ]]; then
  if present "${CADDY_MANAGED_SITE_2_CERT_PATH:-}" && present "${CADDY_MANAGED_SITE_2_KEY_PATH:-}"; then
    check_ok "wildcard site 2 has external cert paths"
  else
    check_error "CADDY_MANAGED_SITE_2 has wildcard hosts but no cert/key paths"
  fi
fi

for cert_path in \
  "${CADDY_MANAGED_SITE_1_CERT_PATH:-}" \
  "${CADDY_MANAGED_SITE_1_KEY_PATH:-}" \
  "${CADDY_MANAGED_SITE_2_CERT_PATH:-}" \
  "${CADDY_MANAGED_SITE_2_KEY_PATH:-}"; do
  if present "$cert_path"; then
    if host_path_exists "$cert_path"; then
      check_ok "cert path exists: $cert_path"
    else
      check_warn "cert path is set but does not exist on this host: $cert_path"
    fi
  fi
done

S3_PUBLIC="${S3_PUBLIC_URL:-${MAGPIE_PUBLIC_URL:-}}"
S3_BUCKET="${S3_BUCKET_NAME:-${MAGPIE_BUCKET_NAME:-}}"
S3_ENDPOINT_VALUE="${S3_ENDPOINT:-${MAGPIE_ENDPOINT:-}}"
MEDIA_HOST="${CADDY_MEDIA_HOST:-media.${PRIMARY_DOMAIN:-example.com}}"

if present "$S3_PUBLIC" || present "$S3_ENDPOINT_VALUE" || present "$S3_BUCKET"; then
  for required in S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
    if ! present "${!required:-}"; then
      check_warn "$required is unset while S3/Magpie storage appears partially configured"
    fi
  done

  if present "$S3_BUCKET"; then
    check_ok "S3 bucket is set"
  else
    check_error "S3/Magpie storage is configured but S3_BUCKET_NAME is unset"
  fi

  if present "$S3_PUBLIC" && [[ "$(url_host "$S3_PUBLIC")" == "$MEDIA_HOST" ]]; then
    check_ok "S3_PUBLIC_URL is routed through $MEDIA_HOST"

    if present "${CADDY_MANAGED_SITE_1_CERT_PATH:-}" && present "${CADDY_MANAGED_SITE_1_KEY_PATH:-}"; then
      check_ok "media route has Caddy cert paths available"
    else
      check_error "media route requires CADDY_MANAGED_SITE_1_CERT_PATH and CADDY_MANAGED_SITE_1_KEY_PATH"
    fi

    if [[ "${CADDY_MEDIA_UPSTREAM:-magpie:8090}" == magpie:* ]]; then
      check_ok "media route upstream uses Magpie"
    fi
  fi
fi

if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER_BIN=(sudo -n docker)
    check_ok "Docker is accessible with passwordless sudo"
  else
    check_warn "Docker daemon is not accessible; skipping container checks"
    DOCKER_BIN=()
  fi
else
  check_ok "Docker is accessible"
fi

if [[ "${#DOCKER_BIN[@]}" -gt 0 ]]; then
  if "${DOCKER_BIN[@]}" inspect elektrine_caddy_edge >/dev/null 2>&1; then
    caddy_mount="$("${DOCKER_BIN[@]}" inspect elektrine_caddy_edge --format '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}')"

    if present "$caddy_mount" && [[ ! -f "$caddy_mount" ]]; then
      check_error "elektrine_caddy_edge has stale Caddyfile bind mount: $caddy_mount"
      echo "Hint: scripts/deploy/docker_deploy.sh removes this automatically on deploy." >&2
    else
      check_ok "Caddy container bind mount is not stale"
    fi
  else
    check_warn "elektrine_caddy_edge container does not exist yet"
  fi

  if present "$S3_PUBLIC" && [[ "$(url_host "$S3_PUBLIC")" == "$MEDIA_HOST" ]] && [[ "${CADDY_MEDIA_UPSTREAM:-magpie:8090}" == magpie:* ]]; then
    network_name="${MAGPIE_DOCKER_NETWORK:-app-shared}"

    if "${DOCKER_BIN[@]}" network inspect "$network_name" >/dev/null 2>&1; then
      check_ok "Magpie shared network exists: $network_name"
    else
      check_warn "Magpie shared network does not exist yet: $network_name"
      echo "Hint: docker network create $network_name" >&2
    fi
  fi
fi

if [[ "$ERRORS" -gt 0 ]]; then
  echo "Doctor failed with $ERRORS error(s) and $WARNINGS warning(s)." >&2
  exit 1
fi

echo "Doctor passed with $WARNINGS warning(s)."
