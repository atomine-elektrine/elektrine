#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE_PATH="$ROOT_DIR/deploy/docker/compose.full.yml"
REQUESTED_MODULES="${ELEKTRINE_RELEASE_MODULES:-all}"
RAW_PROFILES="${DOCKER_PROFILES:-caddy}"
OUTPUT_PATH="${OUTPUT_PATH:-$ROOT_DIR/deploy/docker/generated.docker.yml}"

# shellcheck source=scripts/lib/module_selection.sh
source "$ROOT_DIR/scripts/lib/module_selection.sh"

usage() {
  cat <<'EOF'
Usage: scripts/deploy/render_docker_compose.sh [--modules chat,social] [--profiles "caddy dns tor"] [--output /tmp/elektrine.compose.yml]

Renders a module-aware Docker Compose file.
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
    --profiles)
      RAW_PROFILES="$2"
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

normalize_platform_modules "$REQUESTED_MODULES"

TOR_ENABLED="false"
for profile in $RAW_PROFILES; do
  if [[ "$profile" == "tor" ]]; then
    TOR_ENABLED="true"
    break
  fi
done

mkdir -p "$(dirname "$OUTPUT_PATH")"

awk -v release_modules="$NORMALIZED_MODULES" -v enabled_modules="$NORMALIZED_MODULES" -v tor_enabled="$TOR_ENABLED" '
  /ELEKTRINE_RELEASE_MODULES:/ {
    sub(/\$\{ELEKTRINE_RELEASE_MODULES:-[^}]*\}/, "${ELEKTRINE_RELEASE_MODULES:-" release_modules "}")
    print
    next
  }

  /ELEKTRINE_ENABLED_MODULES:/ {
    sub(/\$\{ELEKTRINE_ENABLED_MODULES:-[^}]*\}/, "${ELEKTRINE_ENABLED_MODULES:-" enabled_modules "}")
    print
    next
  }

  /ELEKTRINE_ENABLE_TOR:/ {
    sub(/\$\{ELEKTRINE_ENABLE_TOR:-[^}]*\}/, "${ELEKTRINE_ENABLE_TOR:-" tor_enabled "}")
    print
    next
  }

  {
    print
  }
' "$TEMPLATE_PATH" > "$OUTPUT_PATH"

echo "Rendered Docker Compose config for modules ${NORMALIZED_MODULES} at $OUTPUT_PATH"
