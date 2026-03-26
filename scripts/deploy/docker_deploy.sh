#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REQUESTED_MODULES="${ELEKTRINE_RELEASE_MODULES:-all}"
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

normalize_platform_modules "$REQUESTED_MODULES"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
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

DOCKER_PROFILES="$RENDER_PROFILES" bash "$ROOT_DIR/scripts/deploy/render_docker_compose.sh" --modules "$NORMALIZED_MODULES" --profiles "$RENDER_PROFILES" --output "$OUTPUT_PATH"

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
    exec "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" up -d --build "${PASSTHROUGH_ARGS[@]}"
  fi

  exec "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" up -d "${PASSTHROUGH_ARGS[@]}"
fi

if [[ "${#PASSTHROUGH_ARGS[@]}" -gt 0 ]]; then
  exec "${DOCKER_BIN[@]}" compose "${COMPOSE_ARGS[@]}" "${PROFILE_ARGS[@]}" "${PASSTHROUGH_ARGS[@]}"
fi

echo "Rendered config only: $OUTPUT_PATH"
