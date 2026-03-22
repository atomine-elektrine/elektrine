#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REQUESTED_MODULES="${ELEKTRINE_RELEASE_MODULES:-all}"
OUTPUT_PATH="$ROOT_DIR/deploy/docker/generated.docker.yml"
ENV_FILE="$ROOT_DIR/.env.production"
PROFILE_ARGS=()
DO_UP=1
DO_MIGRATE=1
PASSTHROUGH_ARGS=()

# shellcheck source=scripts/lib/module_selection.sh
source "$ROOT_DIR/scripts/lib/module_selection.sh"

usage() {
  cat <<'EOF'
Usage: scripts/deploy/docker_deploy.sh [--modules chat,social] [--profile caddy] [--output /tmp/elektrine.compose.yml] [--skip-migrate] [--skip-up] [additional docker compose args...]

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

bash "$ROOT_DIR/scripts/deploy/render_docker_compose.sh" --modules "$NORMALIZED_MODULES" --output "$OUTPUT_PATH"

if [[ "$DO_UP" -eq 1 ]]; then
  docker compose -f "$OUTPUT_PATH" "${PROFILE_ARGS[@]}" up -d --build postgres
  docker compose -f "$OUTPUT_PATH" "${PROFILE_ARGS[@]}" build app worker
fi

if [[ "$DO_MIGRATE" -eq 1 ]]; then
  MIGRATION_POOL_SIZE="${MIGRATION_POOL_SIZE:-2}"
  docker compose -f "$OUTPUT_PATH" "${PROFILE_ARGS[@]}" run --rm -e "MIGRATION_POOL_SIZE=$MIGRATION_POOL_SIZE" app bin/elektrine eval "Elektrine.Release.migrate()"
fi

if [[ "$DO_UP" -eq 1 ]]; then
  exec docker compose -f "$OUTPUT_PATH" "${PROFILE_ARGS[@]}" up -d --build "${PASSTHROUGH_ARGS[@]}"
fi

if [[ "${#PASSTHROUGH_ARGS[@]}" -gt 0 ]]; then
  exec docker compose -f "$OUTPUT_PATH" "${PROFILE_ARGS[@]}" "${PASSTHROUGH_ARGS[@]}"
fi

echo "Rendered config only: $OUTPUT_PATH"
