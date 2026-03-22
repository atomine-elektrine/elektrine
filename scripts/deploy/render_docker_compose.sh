#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE_PATH="$ROOT_DIR/deploy/docker/compose.full.yml"
REQUESTED_MODULES="${ELEKTRINE_RELEASE_MODULES:-all}"
OUTPUT_PATH="${OUTPUT_PATH:-$ROOT_DIR/deploy/docker/generated.docker.yml}"

# shellcheck source=scripts/lib/module_selection.sh
source "$ROOT_DIR/scripts/lib/module_selection.sh"

usage() {
  cat <<'EOF'
Usage: scripts/deploy/render_docker_compose.sh [--modules chat,social] [--output /tmp/elektrine.compose.yml]

Renders a module-aware Docker Compose file.
Mail port bindings are omitted when the email module is not selected.
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
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

normalize_platform_modules "$REQUESTED_MODULES"

MAIL_ENABLED="false"
if platform_module_selected email; then
  MAIL_ENABLED="true"
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

awk -v release_modules="$NORMALIZED_MODULES" -v enabled_modules="$NORMALIZED_MODULES" -v mail_enabled="$MAIL_ENABLED" '
  BEGIN {
    skip_email_ports = 0
  }

  /# BEGIN EMAIL PORTS/ {
    if (mail_enabled == "true") {
      print
    } else {
      skip_email_ports = 1
    }
    next
  }

  /# END EMAIL PORTS/ {
    if (skip_email_ports == 1) {
      skip_email_ports = 0
    } else {
      print
    }
    next
  }

  skip_email_ports == 1 {
    next
  }

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

  /ELEKTRINE_ENABLE_MAIL:/ {
    sub(/\$\{ELEKTRINE_ENABLE_MAIL:-[^}]*\}/, "${ELEKTRINE_ENABLE_MAIL:-" mail_enabled "}")
    print
    next
  }

  {
    print
  }
' "$TEMPLATE_PATH" > "$OUTPUT_PATH"

echo "Rendered Docker Compose config for modules ${NORMALIZED_MODULES} at $OUTPUT_PATH"
