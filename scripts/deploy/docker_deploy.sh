#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REQUESTED_MODULES=""
OUTPUT_PATH="$ROOT_DIR/deploy/docker/generated.docker.yml"
ENV_FILE="$ROOT_DIR/.env.production"
PROFILE_ARGS=()
COMPOSE_OVERRIDE_FILES=()
COMPOSE_PROJECT_DIR="${COMPOSE_PROJECT_DIRECTORY:-$ROOT_DIR}"
COMPOSE_BASE_ARGS=()
DO_UP=1
DO_MIGRATE=1
DO_BUILD=1
DO_PULL=0
PASSTHROUGH_ARGS=()
DOCKER_BIN=(docker)
POSTGRES_EXTENSIONS_RAW="${POSTGRES_EXTENSIONS:-vector}"
RENDER_PROFILES=""
FORCE_RECREATE_ARGS=(--force-recreate)
CADDY_RENDERED_CONFIG_PATH="${CADDY_RENDERED_CONFIG_PATH:-$ROOT_DIR/deploy/docker/generated.Caddyfile}"

# shellcheck source=scripts/lib/module_selection.sh
source "$ROOT_DIR/scripts/lib/module_selection.sh"

usage() {
  cat <<'EOF'
Usage: scripts/deploy/docker_deploy.sh [--modules chat,social] [--profile caddy] [--output /tmp/elektrine.compose.yml] [--compose-override override.yml] [--pull] [--skip-build] [--skip-migrate] [--skip-up] [additional docker compose args...]

Renders a module-aware Compose file and deploys the Docker stack.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --modules)
      REQUESTED_MODULES="$2"
      shift 2
      ;;
    --profile)
      PROFILE_ARGS+=("--profile" "$2")
      shift 2
      ;;
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --compose-override)
      COMPOSE_OVERRIDE_FILES+=("$2")
      shift 2
      ;;
    --pull)
      DO_PULL=1
      shift
      ;;
    --skip-build)
      DO_BUILD=0
      shift
      ;;
    --skip-migrate)
      DO_MIGRATE=0
      shift
      ;;
    --skip-up)
      DO_UP=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
  esac
done

for arg in "${PASSTHROUGH_ARGS[@]}"; do
  if [[ "$arg" == "--no-recreate" ]]; then
    FORCE_RECREATE_ARGS=()
    break
  fi
done

validate_env_file() {
  local env_file="$1"
  local line=""
  local line_no=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      echo "Error: invalid env syntax at $env_file:$line_no" >&2
      return 1
    fi
    if [[ "$line" == *'$('* || "$line" == *'`'* || "$line" == *';'* || "$line" == *'&&'* || "$line" == *'||'* ]]; then
      echo "Error: unsafe shell syntax in env file at $env_file:$line_no" >&2
      return 1
    fi
  done < "$env_file"
}

if [[ -f "$ENV_FILE" ]]; then
  validate_env_file "$ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

if [[ -z "$REQUESTED_MODULES" ]]; then
  REQUESTED_MODULES="$(default_enabled_modules)"
fi

normalize_platform_modules "$REQUESTED_MODULES"

append_profile_if_missing() {
  local wanted="$1"
  local existing=""
  local i=0

  for ((i = 0; i < ${#PROFILE_ARGS[@]}; i += 2)); do
    existing="${PROFILE_ARGS[i + 1]}"

    if [[ "$existing" == "$wanted" ]]; then
      return
    fi
  done

  PROFILE_ARGS+=("--profile" "$wanted")
}

if platform_module_selected vpn; then
  append_profile_if_missing "vpn"
fi

for ((i = 0; i < ${#PROFILE_ARGS[@]}; i += 2)); do
  profile_name="${PROFILE_ARGS[i + 1]}"

  if [[ -n "$profile_name" ]]; then
    if [[ -n "$RENDER_PROFILES" ]]; then
      RENDER_PROFILES+=" "
    fi

    RENDER_PROFILES+="$profile_name"
  fi
done

if [[ -z "$RENDER_PROFILES" ]]; then
  RENDER_PROFILES="${DOCKER_PROFILES:-caddy}"
fi

infer_caddy_config_default() {
  local site1_values="${CADDY_MANAGED_SITE_1:-}"
  local site2_values="${CADDY_MANAGED_SITE_2:-}"

  if [[ "$site1_values" == *"*."* ]]; then
    if [[ -z "${CADDY_MANAGED_SITE_1_CERT_PATH:-}" || -z "${CADDY_MANAGED_SITE_1_KEY_PATH:-}" ]]; then
      echo "Error: CADDY_MANAGED_SITE_1 contains wildcard hosts but no matching external cert/key paths are set." >&2
      echo "Hint: remove wildcard hosts like *.example.com from CADDY_MANAGED_SITE_1 for the stock Caddy setup." >&2
      echo "Hint: run scripts/acme/issue_elektrine_wildcard_cert.sh with ELEKTRINE_DNS_TOKEN, then use external wildcard cert mode." >&2
      echo "Hint: or provide CADDY_MANAGED_SITE_1_CERT_PATH and CADDY_MANAGED_SITE_1_KEY_PATH for an external wildcard certificate." >&2
      return 1
    fi
  fi

  if [[ "$site2_values" == *"*."* ]]; then
    if [[ -z "${CADDY_MANAGED_SITE_2_CERT_PATH:-}" || -z "${CADDY_MANAGED_SITE_2_KEY_PATH:-}" ]]; then
      echo "Error: CADDY_MANAGED_SITE_2 contains wildcard hosts but no matching external cert/key paths are set." >&2
      echo "Hint: remove wildcard hosts like *.example.com from CADDY_MANAGED_SITE_2 for the stock Caddy setup." >&2
      echo "Hint: run scripts/acme/issue_elektrine_wildcard_cert.sh with ELEKTRINE_DNS_TOKEN, then use external wildcard cert mode." >&2
      echo "Hint: or provide CADDY_MANAGED_SITE_2_CERT_PATH and CADDY_MANAGED_SITE_2_KEY_PATH for an external wildcard certificate." >&2
      return 1
    fi
  fi

  if [[ -n "${CADDY_CONFIG_PATH:-}" ]]; then
    printf '%s' "$CADDY_CONFIG_PATH"
    return 0
  fi

  local default_path="../caddy/Caddyfile.baremetal"
  local external_path="../caddy/Caddyfile.baremetal.external-certs"
  local wildcard_path="../caddy/Caddyfile.baremetal.wildcard-external"

  local site_values="$site1_values $site2_values"
  local has_wildcard=0
  local has_external_cert=0

  if [[ "$site_values" == *"*."* ]]; then
    has_wildcard=1
  fi

  if [[ -n "${CADDY_MANAGED_SITE_1_CERT_PATH:-}" && -n "${CADDY_MANAGED_SITE_1_KEY_PATH:-}" ]]; then
    has_external_cert=1
  fi

  if [[ -n "${CADDY_MANAGED_SITE_2_CERT_PATH:-}" && -n "${CADDY_MANAGED_SITE_2_KEY_PATH:-}" ]]; then
    has_external_cert=1
  fi

  if [[ "$has_external_cert" -eq 1 && "$has_wildcard" -eq 1 ]]; then
    printf '%s' "$wildcard_path"
  elif [[ "$has_external_cert" -eq 1 ]]; then
    printf '%s' "$external_path"
  else
    printf '%s' "$default_path"
  fi
}

validate_external_caddy_cert_paths() {
  local config_path="$1"

  case "$config_path" in
    *external-certs|*wildcard-external) ;;
    *) return 0 ;;
  esac

  if [[ -n "${CADDY_MANAGED_SITE_1:-}" ]]; then
    if [[ -z "${CADDY_MANAGED_SITE_1_CERT_PATH:-}" || -z "${CADDY_MANAGED_SITE_1_KEY_PATH:-}" ]]; then
      echo "Error: $config_path requires CADDY_MANAGED_SITE_1_CERT_PATH and CADDY_MANAGED_SITE_1_KEY_PATH." >&2
      echo "Hint: set both paths to certificate files mounted inside the Caddy container, or use the stock Caddyfile for Caddy-managed TLS." >&2
      return 1
    fi
  fi

  if [[ -n "${CADDY_MANAGED_SITE_2:-}" ]]; then
    if [[ -z "${CADDY_MANAGED_SITE_2_CERT_PATH:-}" || -z "${CADDY_MANAGED_SITE_2_KEY_PATH:-}" ]]; then
      echo "Error: $config_path requires CADDY_MANAGED_SITE_2_CERT_PATH and CADDY_MANAGED_SITE_2_KEY_PATH." >&2
      echo "Hint: set both paths to certificate files mounted inside the Caddy container, or unset CADDY_MANAGED_SITE_2 if you do not use a second site block." >&2
      return 1
    fi
  fi
}

url_host() {
  local value="$1"

  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%%:*}"
  printf '%s' "$value"
}

media_route_enabled() {
  local public_host=""
  local media_host="${CADDY_MEDIA_HOST:-media.elektrine.com}"

  if [[ -z "${S3_PUBLIC_URL:-${MAGPIE_PUBLIC_URL:-}}" ]]; then
    return 1
  fi

  public_host="$(url_host "${S3_PUBLIC_URL:-${MAGPIE_PUBLIC_URL:-}}")"
  [[ "$public_host" == "$media_host" ]]
}

validate_media_storage_config() {
  if ! media_route_enabled; then
    return 0
  fi

  if [[ -z "${S3_BUCKET_NAME:-${MAGPIE_BUCKET_NAME:-}}" ]]; then
    echo "Error: S3_PUBLIC_URL points at ${CADDY_MEDIA_HOST:-media.elektrine.com}, but S3_BUCKET_NAME is not set." >&2
    echo "Hint: set S3_BUCKET_NAME to the Magpie bucket so Caddy can rewrite /path to /bucket/path." >&2
    return 1
  fi

  case "$INFERRED_CADDY_CONFIG_PATH" in
    *external-certs|*wildcard-external) ;;
    *)
      echo "Error: S3_PUBLIC_URL uses ${CADDY_MEDIA_HOST:-media.elektrine.com}, but the selected Caddyfile has no Magpie media route." >&2
      echo "Hint: use external/wildcard external Caddy mode with CADDY_MANAGED_SITE_1_CERT_PATH and CADDY_MANAGED_SITE_1_KEY_PATH." >&2
      return 1
      ;;
  esac

  if [[ -z "${CADDY_MANAGED_SITE_1_CERT_PATH:-}" || -z "${CADDY_MANAGED_SITE_1_KEY_PATH:-}" ]]; then
    echo "Error: media Caddy route requires CADDY_MANAGED_SITE_1_CERT_PATH and CADDY_MANAGED_SITE_1_KEY_PATH." >&2
    return 1
  fi
}

validate_caddy_admin_cidrs() {
  if [[ "${NETBIRD_ALLOWED_CIDRS:-}" == *"0.0.0.0/0"* || "${NETBIRD_ALLOWED_CIDRS:-}" == *"::/0"* ]]; then
    echo "Error: NETBIRD_ALLOWED_CIDRS must not include 0.0.0.0/0 or ::/0 when Caddy is enabled." >&2
    echo "Hint: set exact VPN/private CIDRs, or leave it unset to deny public admin host access by default." >&2
    return 1
  fi
}

append_compose_override_if_missing() {
  local wanted="$1"
  local existing=""

  for existing in "${COMPOSE_OVERRIDE_FILES[@]}"; do
    if [[ "$existing" == "$wanted" ]]; then
      return 0
    fi
  done

  COMPOSE_OVERRIDE_FILES+=("$wanted")
}

maybe_enable_magpie_network_override() {
  local upstream_host="${CADDY_MEDIA_UPSTREAM:-magpie:8090}"
  upstream_host="${upstream_host%%:*}"

  if media_route_enabled && [[ "$upstream_host" == "magpie" ]]; then
    append_compose_override_if_missing "$ROOT_DIR/deploy/docker/compose.magpie-network.yml"
  fi
}

resolve_caddy_config_path() {
  local config_path="$1"

  if [[ "$config_path" == /* ]]; then
    printf '%s' "$config_path"
  else
    printf '%s/%s' "$ROOT_DIR/deploy/docker" "$config_path"
  fi
}

render_caddy_config() {
  local source_path=""
  local include_site2=0
  local include_media=0

  source_path="$(resolve_caddy_config_path "$INFERRED_CADDY_CONFIG_PATH")"

  if [[ ! -f "$source_path" ]]; then
    echo "Error: Caddy config does not exist: $source_path" >&2
    return 1
  fi

  if [[ -n "${CADDY_MANAGED_SITE_2:-}" ]]; then
    include_site2=1
  fi

  if media_route_enabled; then
    include_media=1
  fi

  awk -v include_site2="$include_site2" -v include_media="$include_media" '
    /# elektrine:site2:start/ { skip = include_site2 ? 0 : 1; next }
    /# elektrine:site2:end/ { skip = 0; next }
    /# elektrine:media:start/ { skip = include_media ? 0 : 1; next }
    /# elektrine:media:end/ { skip = 0; next }
    skip { next }
    { print }
  ' "$source_path" > "$CADDY_RENDERED_CONFIG_PATH"
}

infer_cert_base_name() {
  local site_values="$1"
  local token=""

  for token in $site_values; do
    token="${token#*.}"

    if [[ -n "$token" ]]; then
      printf '%s' "$token"
      return 0
    fi
  done

  return 1
}

populate_wildcard_cert_defaults() {
  local tls_mount_dir="${CADDY_TLS_MOUNT_DIR:-/opt/elektrine/certs}"
  local site1_values="${CADDY_MANAGED_SITE_1:-}"
  local site2_values="${CADDY_MANAGED_SITE_2:-}"
  local cert_base_name=""

  if [[ "$site1_values" == *"*."* ]]; then
    if [[ -z "${CADDY_MANAGED_SITE_1_CERT_PATH:-}" || -z "${CADDY_MANAGED_SITE_1_KEY_PATH:-}" ]]; then
      cert_base_name="$(infer_cert_base_name "$site1_values")" || cert_base_name=""

      if [[ -n "$cert_base_name" ]]; then
        CADDY_MANAGED_SITE_1_CERT_PATH="${CADDY_MANAGED_SITE_1_CERT_PATH:-$tls_mount_dir/$cert_base_name.fullchain.pem}"
        CADDY_MANAGED_SITE_1_KEY_PATH="${CADDY_MANAGED_SITE_1_KEY_PATH:-$tls_mount_dir/$cert_base_name.key.pem}"
        export CADDY_MANAGED_SITE_1_CERT_PATH CADDY_MANAGED_SITE_1_KEY_PATH
      fi
    fi
  fi

  if [[ "$site2_values" == *"*."* ]]; then
    if [[ -z "${CADDY_MANAGED_SITE_2_CERT_PATH:-}" || -z "${CADDY_MANAGED_SITE_2_KEY_PATH:-}" ]]; then
      cert_base_name="$(infer_cert_base_name "$site2_values")" || cert_base_name=""

      if [[ -n "$cert_base_name" ]]; then
        CADDY_MANAGED_SITE_2_CERT_PATH="${CADDY_MANAGED_SITE_2_CERT_PATH:-$tls_mount_dir/$cert_base_name.fullchain.pem}"
        CADDY_MANAGED_SITE_2_KEY_PATH="${CADDY_MANAGED_SITE_2_KEY_PATH:-$tls_mount_dir/$cert_base_name.key.pem}"
        export CADDY_MANAGED_SITE_2_CERT_PATH CADDY_MANAGED_SITE_2_KEY_PATH
      fi
    fi
  fi
}

uses_elektrine_wildcard_acme() {
  local site_values="${CADDY_MANAGED_SITE_1:-} ${CADDY_MANAGED_SITE_2:-}"

    [[ " $RENDER_PROFILES " == *" caddy " ]] &&
    [[ "$site_values" == *"*."* ]] &&
    [[ "${ACME_WILDCARD_RENEWAL_ENABLED:-false}" =~ ^(1|true|TRUE|yes|YES)$ ]]
}

compose_has_service() {
  local service_name="$1"
  "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" config --services | grep -qx "$service_name"
}

remove_caddy_with_stale_config_mount() {
  local container_name="elektrine_caddy_edge"
  local mounted_config=""

  if ! "${DOCKER_BIN[@]}" inspect "$container_name" >/dev/null 2>&1; then
    return 0
  fi

  mounted_config="$("${DOCKER_BIN[@]}" inspect "$container_name" --format '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}')"

  if [[ -n "$mounted_config" && ! -f "$mounted_config" ]]; then
    echo "Info: removing $container_name because its Caddyfile bind mount no longer exists: $mounted_config" >&2
    "${DOCKER_BIN[@]}" rm -f "$container_name" >/dev/null
  fi
}

acme_runner_service() {
  if compose_has_service worker; then
    printf '%s' worker
  else
    printf '%s' app
  fi
}

issue_initial_wildcard_cert() {
  if ! uses_elektrine_wildcard_acme; then
    return 0
  fi

  local runner_service
  runner_service="$(acme_runner_service)"

  echo "Info: ensuring initial Elektrine DNS wildcard certificate via $runner_service" >&2
  if [[ "$runner_service" == "app" ]]; then
    "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" up -d app
  else
    "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" up -d app "$runner_service"
  fi

  "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" exec -T "$runner_service" /app/scripts/acme/issue_elektrine_wildcard_cert.sh
}

populate_wildcard_cert_defaults

INFERRED_CADDY_CONFIG_PATH="$(infer_caddy_config_default)"
validate_external_caddy_cert_paths "$INFERRED_CADDY_CONFIG_PATH"
validate_media_storage_config
validate_caddy_admin_cidrs
maybe_enable_magpie_network_override
render_caddy_config
INFERRED_CADDY_CONFIG_PATH="$CADDY_RENDERED_CONFIG_PATH"

if [[ " $RENDER_PROFILES " == *" caddy "* ]]; then
  if [[ -z "${CADDY_EDGE_API_KEY:-}" ]]; then
    echo "Error: Caddy profile requires a distinct CADDY_EDGE_API_KEY for internal TLS auth." >&2
    echo "Hint: generate a long random value and set CADDY_EDGE_API_KEY in .env.production." >&2
    exit 1
  fi

  if [[ ! "$CADDY_EDGE_API_KEY" =~ ^[A-Za-z0-9._~-]+$ ]]; then
    echo "Error: CADDY_EDGE_API_KEY must contain only URL path-safe characters: A-Z a-z 0-9 . _ ~ -" >&2
    echo "Hint: scripts/deploy/generate_env.sh generates a compatible hex value." >&2
    exit 1
  fi
fi

COMPOSE_BASE_ARGS=(--project-directory "$COMPOSE_PROJECT_DIR" --env-file "$ENV_FILE")

if [[ -e "$OUTPUT_PATH" && ! -w "$OUTPUT_PATH" ]]; then
  echo "Error: output path is not writable: $OUTPUT_PATH" >&2
  echo "Hint: render to a writable temporary file with --output /tmp/elektrine.generated.docker.yml" >&2
  echo "Hint: if this is a repo-owned generated file, fix ownership instead of running git operations as root" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER_BIN=(sudo -n docker)
  else
    echo "Error: Docker daemon is not accessible for the current user" >&2
    exit 1
  fi
fi

DOCKER_PROFILES="$RENDER_PROFILES" CADDY_DEFAULT_CONFIG_PATH="$INFERRED_CADDY_CONFIG_PATH" bash "$ROOT_DIR/scripts/deploy/render_docker_compose.sh" --modules "$NORMALIZED_MODULES" --profiles "$RENDER_PROFILES" --output "$OUTPUT_PATH"

COMPOSE_ARGS=("${COMPOSE_BASE_ARGS[@]}" -f "$OUTPUT_PATH")
for override_file in "${COMPOSE_OVERRIDE_FILES[@]}"; do
  COMPOSE_ARGS+=(-f "$override_file")
done

remove_caddy_with_stale_config_mount

if [[ "$DO_UP" -eq 1 ]]; then
  # Do not let the partial postgres bootstrap recreate the shared project network
  # while other profile services are still attached. The full stack is converged
  # after migrations below.
  "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" up -d --no-recreate postgres

  if [[ -n "$POSTGRES_EXTENSIONS_RAW" ]]; then
    IFS=',' read -r -a POSTGRES_EXTENSIONS <<< "$POSTGRES_EXTENSIONS_RAW"

    for extension in "${POSTGRES_EXTENSIONS[@]}"; do
      extension="$(printf '%s' "$extension" | xargs)"

      if [[ -z "$extension" ]]; then
        continue
      fi

      if [[ ! "$extension" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo "Error: invalid Postgres extension name: $extension" >&2
        exit 1
      fi

      "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" exec -T postgres \
        psql -U "${POSTGRES_USER:-elektrine}" -d "${POSTGRES_DB:-elektrine_prod}" \
        -c "CREATE EXTENSION IF NOT EXISTS \"$extension\";"
    done
  fi

  if [[ "$DO_BUILD" -eq 1 ]]; then
    "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" build app worker
  elif [[ "$DO_PULL" -eq 1 ]]; then
    "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" pull app worker
  fi
fi

if [[ "$DO_MIGRATE" -eq 1 ]]; then
  MIGRATION_POOL_SIZE="${MIGRATION_POOL_SIZE:-2}"
  "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" run --rm -e "MIGRATION_POOL_SIZE=$MIGRATION_POOL_SIZE" -e "POOL_SIZE=2" app bin/elektrine eval "Elektrine.Release.migrate()"
fi

if [[ "$DO_UP" -eq 1 ]]; then
  issue_initial_wildcard_cert

  if [[ "$DO_BUILD" -eq 1 ]]; then
    "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" up -d --build "${FORCE_RECREATE_ARGS[@]}" "${PASSTHROUGH_ARGS[@]}"
    exit $?
  fi

  "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" up -d "${FORCE_RECREATE_ARGS[@]}" "${PASSTHROUGH_ARGS[@]}"
  exit $?
fi

if [[ "${#PASSTHROUGH_ARGS[@]}" -gt 0 ]]; then
  exec "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" "${PASSTHROUGH_ARGS[@]}"
fi

echo "Rendered config only: $OUTPUT_PATH"
