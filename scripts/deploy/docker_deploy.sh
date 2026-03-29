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

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

if [[ -z "$REQUESTED_MODULES" ]]; then
  REQUESTED_MODULES="$(default_enabled_modules)"
fi

normalize_platform_modules "$REQUESTED_MODULES"

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
      echo "Hint: or provide CADDY_MANAGED_SITE_1_CERT_PATH and CADDY_MANAGED_SITE_1_KEY_PATH for a wildcard certificate." >&2
      return 1
    fi
  fi

  if [[ "$site2_values" == *"*."* ]]; then
    if [[ -z "${CADDY_MANAGED_SITE_2_CERT_PATH:-}" || -z "${CADDY_MANAGED_SITE_2_KEY_PATH:-}" ]]; then
      echo "Error: CADDY_MANAGED_SITE_2 contains wildcard hosts but no matching external cert/key paths are set." >&2
      echo "Hint: remove wildcard hosts like *.example.com from CADDY_MANAGED_SITE_2 for the stock Caddy setup." >&2
      echo "Hint: or provide CADDY_MANAGED_SITE_2_CERT_PATH and CADDY_MANAGED_SITE_2_KEY_PATH for a wildcard certificate." >&2
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

INFERRED_CADDY_CONFIG_PATH="$(infer_caddy_config_default)"

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

if [[ "$DO_UP" -eq 1 ]]; then
  "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" up -d postgres

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
  "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" run --rm -e "MIGRATION_POOL_SIZE=$MIGRATION_POOL_SIZE" app bin/elektrine eval "Elektrine.Release.migrate()"
fi

if [[ "$DO_UP" -eq 1 ]]; then
  if [[ "$DO_BUILD" -eq 1 ]]; then
    exec "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" up -d --build "${FORCE_RECREATE_ARGS[@]}" "${PASSTHROUGH_ARGS[@]}"
  fi

  exec "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" up -d "${FORCE_RECREATE_ARGS[@]}" "${PASSTHROUGH_ARGS[@]}"
fi

if [[ "${#PASSTHROUGH_ARGS[@]}" -gt 0 ]]; then
  exec "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" "${PASSTHROUGH_ARGS[@]}"
fi

echo "Rendered config only: $OUTPUT_PATH"
