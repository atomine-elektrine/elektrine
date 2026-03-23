#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE_PATH="$ROOT_DIR/deploy/mongooseim/mongooseim.toml.template"
OUTPUT_PATH="${OUTPUT_PATH:-$ROOT_DIR/deploy/mongooseim/generated/mongooseim.toml}"
PRIMARY_DOMAIN_VALUE="${PRIMARY_DOMAIN:-example.com}"
MONGOOSEIM_API_KEY_VALUE="${MONGOOSEIM_API_KEY:-change-me}"

usage() {
  cat <<'EOF'
Usage: scripts/deploy/render_mongooseim_config.sh [--output /tmp/mongooseim.toml]

Renders MongooseIM config from environment values.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

mkdir -p "$(dirname "$OUTPUT_PATH")"

python3 - <<'PY' "$TEMPLATE_PATH" "$OUTPUT_PATH" "$PRIMARY_DOMAIN_VALUE" "$MONGOOSEIM_API_KEY_VALUE"
from pathlib import Path
import sys

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
primary_domain = sys.argv[3]
api_key = sys.argv[4]

content = template_path.read_text()
content = content.replace("__PRIMARY_DOMAIN__", primary_domain)
content = content.replace("__MONGOOSEIM_API_KEY__", api_key)
output_path.write_text(content)
PY

echo "Rendered MongooseIM config at $OUTPUT_PATH"
