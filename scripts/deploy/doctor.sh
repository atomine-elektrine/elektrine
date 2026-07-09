#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$ROOT_DIR/.env.production"
DOCKER_BIN=(docker)
ERRORS=0
WARNINGS=0
GENERATED_DIR="${ELEKTRINE_GENERATED_DIR:-$ROOT_DIR/deploy/generated}"
GENERATED_COMPOSE_PATH="$GENERATED_DIR/generated.docker.yml"
GENERATED_CADDY_PATH="$GENERATED_DIR/generated.Caddyfile"
ACTIVE_DOCKER_PROFILES=""

# shellcheck source=scripts/lib/module_selection.sh
source "$ROOT_DIR/scripts/lib/module_selection.sh"
# shellcheck source=scripts/lib/deploy_simplify.sh
source "$ROOT_DIR/scripts/lib/deploy_simplify.sh"

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

  for profile in $ACTIVE_DOCKER_PROFILES; do
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

path_writable_or_sudo_installable() {
  local path="$1"
  local dir=""

  dir="$(dirname "$path")"

  if [[ -d "$dir" && -w "$dir" ]]; then
    if [[ ! -e "$path" || -w "$path" ]]; then
      return 0
    fi
  fi

  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null
}

check_generated_output_path() {
  local path="$1"
  local label="$2"
  local dir=""

  dir="$(dirname "$path")"

  if [[ ! -d "$dir" ]]; then
    if mkdir -p "$dir" 2>/dev/null; then
      check_ok "$label directory can be created: $dir"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      check_ok "$label directory can be created with passwordless sudo: $dir"
    else
      check_error "$label directory cannot be created: $dir"
      return
    fi
  fi

  if path_writable_or_sudo_installable "$path"; then
    check_ok "$label is writable or sudo-installable: $path"
  else
    check_error "$label is not writable: $path"
    echo "Hint: keep generated deploy files under deploy/generated/ owned by the deploy user." >&2
  fi
}

check_generated_path_location() {
  local path="$1"
  local label="$2"
  local generated_prefix="$ROOT_DIR/deploy/generated/"

  case "$path" in
    "$generated_prefix"*)
      check_ok "$label is under deploy/generated"
      ;;
    "$ROOT_DIR/deploy/docker/"*|"$ROOT_DIR/deploy/caddy/"*)
      check_error "$label points into a source template directory: $path"
      echo "Hint: set ELEKTRINE_GENERATED_DIR=$ROOT_DIR/deploy/generated or remove older generated-path overrides." >&2
      ;;
    *)
      check_warn "$label is outside deploy/generated: $path"
      echo "Hint: generated Compose and Caddy outputs should normally live under deploy/generated/." >&2
      ;;
  esac
}

check_old_generated_files() {
  local paths=()
  local old_path=""

  while IFS= read -r old_path; do
    paths+=("$old_path")
  done < <(
    find "$ROOT_DIR/deploy/docker" "$ROOT_DIR/deploy/caddy" \
      \( -name 'generated*.yml' -o -name 'generated.Caddyfile' -o -name 'compose.override.yml' \) \
      -print 2>/dev/null || true
  )

  if [[ "${#paths[@]}" -eq 0 ]]; then
    check_ok "no older generated files found in source template directories"
    return
  fi

  check_warn "older generated files found in source template directories"
  printf '  %s\n' "${paths[@]}" >&2
  echo "Hint: move disposable rendered outputs to deploy/generated/ and keep deploy/docker/ and deploy/caddy/ as templates." >&2
}

check_root_owned_generated_files() {
  local paths=()
  local generated_path=""

  while IFS= read -r generated_path; do
    paths+=("$generated_path")
  done < <(
    find "$ROOT_DIR/deploy/generated" "$ROOT_DIR/deploy/docker" \
      \( -path "$ROOT_DIR/deploy/generated/.gitkeep" -o -name 'generated*.yml' -o -name 'generated.Caddyfile' \) \
      -user 0 -print 2>/dev/null || true
  )

  if [[ "${#paths[@]}" -eq 0 ]]; then
    check_ok "no root-owned generated deploy files found"
    return
  fi

  check_error "root-owned generated deploy files found"
  printf '  %s\n' "${paths[@]}" >&2
  echo "Hint: chown these files to the deploy user or remove them before deploying." >&2
}

check_stale_deploy_worktrees() {
  local paths=()
  local worktree_path=""

  while IFS= read -r worktree_path; do
    paths+=("$worktree_path")
  done < <(find "$ROOT_DIR" -maxdepth 1 -type d -name '.deploy-worktree.*' -print 2>/dev/null || true)

  if [[ "${#paths[@]}" -eq 0 ]]; then
    check_ok "no stale deploy worktrees found"
    return
  fi

  check_warn "stale deploy worktrees found"
  printf '  %s\n' "${paths[@]}" >&2
  echo "Hint: remove stale .deploy-worktree.* directories after confirming no deploy is running." >&2
}

check_compose_project_name() {
  if present "${COMPOSE_PROJECT_NAME:-}"; then
    check_ok "COMPOSE_PROJECT_NAME is set to $COMPOSE_PROJECT_NAME"
  else
    check_warn "COMPOSE_PROJECT_NAME is unset; Compose will derive it from the project directory"
    echo "Hint: set COMPOSE_PROJECT_NAME=docker for stable network and volume names across deploy paths." >&2
  fi
}

port_in_use() {
  local port="$1"
  local proto="$2"
  local lsof_proto=""

  if command -v ss >/dev/null 2>&1; then
    ss -H -l "${proto}" "sport = :$port" 2>/dev/null | grep -q .
  elif command -v lsof >/dev/null 2>&1; then
    case "$proto" in
      -t) lsof_proto="TCP" ;;
      -u) lsof_proto="UDP" ;;
      *) return 2 ;;
    esac

    if [[ "$lsof_proto" == "TCP" ]]; then
      lsof -nP "-i$lsof_proto:$port" -sTCP:LISTEN >/dev/null 2>&1
    else
      lsof -nP "-i$lsof_proto:$port" >/dev/null 2>&1
    fi
  else
    return 2
  fi
}

check_port() {
  local port="$1"
  local proto="$2"
  local label="$3"

  if port_in_use "$port" "$proto"; then
    check_warn "$label port appears to be in use: $port/${proto#-}"
  else
    case "$?" in
      2)
        check_warn "cannot check $label port; install ss or lsof"
        ;;
      *)
        check_ok "$label port appears available: $port/${proto#-}"
        ;;
    esac
  fi
}

validate_env_file() {
  local env_file="$1"
  local line=""
  local line_no=0
  local key=""

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

    key="${line%%=*}"
    if [[ -n "${seen_env_keys[$key]:-}" ]]; then
      check_error "duplicate env key $key at $env_file:$line_no; first seen at line ${seen_env_keys[$key]}"
    else
      seen_env_keys[$key]="$line_no"
    fi
  done < "$env_file"
}

if [[ ! -f "$ENV_FILE" ]]; then
  check_error "env file does not exist: $ENV_FILE"
  echo "Hint: scripts/deploy/self_host.sh init --domain example.com --email admin@example.com" >&2
  exit 1
fi

declare -A seen_env_keys=()
validate_env_file "$ENV_FILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

apply_simplified_deploy_env

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-docker}"

check_ok "loaded $ENV_FILE"
ACTIVE_DOCKER_PROFILES="${DOCKER_PROFILES:-$(default_docker_profiles)}"

check_generated_path_location "$GENERATED_COMPOSE_PATH" "generated Compose output"
check_generated_path_location "$GENERATED_CADDY_PATH" "generated Caddy output"
check_generated_output_path "$GENERATED_COMPOSE_PATH" "generated Compose output"
check_generated_output_path "$GENERATED_CADDY_PATH" "generated Caddy output"
check_old_generated_files
check_root_owned_generated_files
check_stale_deploy_worktrees
check_compose_project_name
doctor_check_legacy_deploy_env_file
doctor_check_simplified_deploy_env

for required in PRIMARY_DOMAIN DB_PASSWORD ELEKTRINE_MASTER_SECRET; do
  if present "${!required:-}"; then
    check_ok "$required is set"
  else
    check_error "$required is required"
  fi
done

if [[ "${DB_PASSWORD:-}" == "change-me" || "${DB_PASSWORD:-}" == "<generate-a-long-random-secret>" ]]; then
  check_error "DB_PASSWORD is still the placeholder value"
fi

if [[ "${ELEKTRINE_MASTER_SECRET:-}" == "replace-with-long-random-secret" || "${ELEKTRINE_MASTER_SECRET:-}" == "<generate-a-long-random-secret>" ]]; then
  check_error "ELEKTRINE_MASTER_SECRET is still the placeholder value"
fi

if has_profile caddy; then
  check_port 80 -t "Caddy HTTP"
  check_port 443 -t "Caddy HTTPS"

  if present "${ACME_EMAIL:-}"; then
    check_ok "ACME_EMAIL is set for Caddy"
  else
    check_warn "Caddy profile is enabled without ACME_EMAIL"
  fi
fi

if has_profile dns; then
  check_port 53 -t "DNS TCP"
  check_port 53 -u "DNS UDP"
fi

if has_profile email; then
  check_port 25 -t "SMTP edge"
  check_port 465 -t "SMTPS"
  check_port 587 -t "SMTP submission"
  check_port 993 -t "IMAPS"
fi

if [[ "${CADDY_MANAGED_SITE_1:-}" == *"*."* ]]; then
  if path_writable_or_sudo_installable "${CADDY_TLS_MOUNT_DIR:-/opt/elektrine/certs}/.doctor-write-test"; then
    check_ok "Caddy TLS directory is writable or sudo-installable: ${CADDY_TLS_MOUNT_DIR:-/opt/elektrine/certs}"
  else
    check_error "Caddy TLS directory is not writable: ${CADDY_TLS_MOUNT_DIR:-/opt/elektrine/certs}"
  fi

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

if has_profile email; then
  mail_cert_path="${IMAP_TLS_CERT_PATH:-${MAIL_TLS_CERT_PATH:-}}"
  mail_key_path="${IMAP_TLS_KEY_PATH:-${MAIL_TLS_KEY_PATH:-}}"

  if present "$mail_cert_path" && present "$mail_key_path"; then
    check_ok "email profile has IMAPS TLS cert/key paths"

    for mail_tls_path in "$mail_cert_path" "$mail_key_path"; do
      if host_path_exists "$mail_tls_path"; then
        check_ok "mail TLS path exists: $mail_tls_path"
      else
        check_warn "mail TLS path is set but does not exist on this host: $mail_tls_path"
      fi
    done
  else
    check_warn "email profile is enabled without IMAP_TLS_CERT_PATH/KEY or MAIL_TLS_CERT_PATH/KEY"
    echo "Hint: Gmail mobile works best with public IMAPS on 993 and a trusted certificate for the configured mail host." >&2
  fi

  if [[ ! "${HARAKA_WILDCARD_TLS_AUTO_CONFIGURE:-true}" =~ ^(0|false|FALSE|no|NO)$ ]]; then
    haraka_dir="${HARAKA_DEPLOY_DIR:-}"
    [[ -z "$haraka_dir" && -d /opt/elektrine-haraka ]] && haraka_dir=/opt/elektrine-haraka
    [[ -z "$haraka_dir" && -d /opt/elektrine/haraka ]] && haraka_dir=/opt/elektrine/haraka

    if present "$haraka_dir" && [[ -d "$haraka_dir" ]]; then
      haraka_override_path="$haraka_dir/compose.override.yml"

      if path_writable_or_sudo_installable "$haraka_override_path"; then
        check_ok "Haraka TLS override is writable or sudo-installable: $haraka_override_path"
      else
        check_error "Haraka TLS override is not writable: $haraka_override_path"
        echo "Hint: chown the Haraka deployment directory to the SSH deploy user or disable HARAKA_WILDCARD_TLS_AUTO_CONFIGURE." >&2
      fi
    fi
  fi
fi

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
    network_name="${MAGPIE_DOCKER_NETWORK:-elektrine-magpie-shared}"
    magpie_container_name="${MAGPIE_CONTAINER_NAME:-magpie}"

    if "${DOCKER_BIN[@]}" network inspect "$network_name" >/dev/null 2>&1; then
      check_ok "Magpie shared network exists: $network_name"
    else
      check_warn "Magpie shared network does not exist yet: $network_name"
      echo "Hint: docker network create $network_name" >&2
    fi

    if "${DOCKER_BIN[@]}" inspect "$magpie_container_name" >/dev/null 2>&1; then
      magpie_attached="$("${DOCKER_BIN[@]}" inspect "$magpie_container_name" --format "{{if index .NetworkSettings.Networks \"$network_name\"}}yes{{end}}")"

      if [[ "$magpie_attached" == "yes" ]]; then
        check_ok "Magpie container is attached to $network_name"
      else
        check_warn "Magpie container is not attached to $network_name"
        echo "Hint: scripts/deploy/docker_deploy.sh connects it automatically, or run: docker network connect --alias magpie $network_name $magpie_container_name" >&2
      fi
    else
      check_warn "Magpie container does not exist yet: $magpie_container_name"
      echo "Hint: start Magpie first, or set MAGPIE_CONTAINER_NAME to the real container name." >&2
    fi
  fi
fi

if [[ "$ERRORS" -gt 0 ]]; then
  echo "Doctor failed with $ERRORS error(s) and $WARNINGS warning(s)." >&2
  exit 1
fi

echo "Doctor passed with $WARNINGS warning(s)."
