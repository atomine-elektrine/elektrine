#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REQUESTED_MODULES="${ELEKTRINE_RELEASE_MODULES:-all}"
OUTPUT_PATH=""
PASSTHROUGH_ARGS=()

# shellcheck source=scripts/lib/module_selection.sh
source "$ROOT_DIR/scripts/lib/module_selection.sh"

usage() {
  cat <<'EOF'
Usage: scripts/deploy/fly_deploy.sh [--modules chat,social] [--output /tmp/elektrine.fly.toml] [additional fly deploy args...]

Renders a module-aware Fly config and runs `fly deploy -c <generated-config>`.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --modules)
      REQUESTED_MODULES="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="$2"
      shift 2
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

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$ROOT_DIR/deploy/fly/generated.${BUILD_SLUG}.toml"
fi

bash "$ROOT_DIR/scripts/deploy/render_fly_toml.sh" --modules "$NORMALIZED_MODULES" --output "$OUTPUT_PATH"

exec fly deploy -c "$OUTPUT_PATH" "${PASSTHROUGH_ARGS[@]}"
