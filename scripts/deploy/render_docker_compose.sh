#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE_PATH="$ROOT_DIR/deploy/docker/compose.full.yml"
REQUESTED_ENABLED_MODULES=""
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
      REQUESTED_ENABLED_MODULES="$2"
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

if [[ -z "$REQUESTED_ENABLED_MODULES" ]]; then
  REQUESTED_ENABLED_MODULES="$(default_enabled_modules)"
fi

normalize_platform_modules "$REQUESTED_ENABLED_MODULES"
ENABLED_MODULES="$NORMALIZED_MODULES"

REQUESTED_RELEASE_MODULES="${ELEKTRINE_RELEASE_MODULES:-$ENABLED_MODULES}"
normalize_platform_modules "$REQUESTED_RELEASE_MODULES"
RELEASE_MODULES="$NORMALIZED_MODULES"

TOR_ENABLED="false"
CADDY_DEFAULT_CONFIG_PATH="${CADDY_DEFAULT_CONFIG_PATH:-../caddy/Caddyfile.baremetal}"
for profile in $RAW_PROFILES; do
  if [[ "$profile" == "tor" ]]; then
    TOR_ENABLED="true"
    break
  fi
done

mkdir -p "$(dirname "$OUTPUT_PATH")"

awk -v release_modules="$RELEASE_MODULES" -v enabled_modules="$ENABLED_MODULES" -v tor_enabled="$TOR_ENABLED" -v caddy_config_default="$CADDY_DEFAULT_CONFIG_PATH" '
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

  /\/etc\/caddy\/Caddyfile:ro/ {
    sub(/\$\{CADDY_CONFIG_PATH:-[^}]*\}/, "${CADDY_CONFIG_PATH:-" caddy_config_default "}")
    print
    next
  }

  {
    print
  }
' "$TEMPLATE_PATH" > "$OUTPUT_PATH"

if [[ "$RELEASE_MODULES" == "$ENABLED_MODULES" ]]; then
  echo "Rendered Docker Compose config for modules ${ENABLED_MODULES} at $OUTPUT_PATH"
else
  echo "Rendered Docker Compose config for enabled modules ${ENABLED_MODULES} (release modules ${RELEASE_MODULES}) at $OUTPUT_PATH"
fi
