#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE_PATH="$ROOT_DIR/deploy/mongooseim/mongooseim.toml.template"
OUTPUT_PATH="${OUTPUT_PATH:-$ROOT_DIR/deploy/mongooseim/generated/mongooseim.toml}"
PRIMARY_DOMAIN_VALUE="${PRIMARY_DOMAIN:-example.com}"
MONGOOSEIM_API_KEY_VALUE="${MONGOOSEIM_API_KEY:-${PHOENIX_API_KEY:-change-me}}"
MONGOOSEIM_DB_NAME_VALUE="${MONGOOSEIM_DB_NAME:-mongooseim}"
MONGOOSEIM_DB_USER_VALUE="${MONGOOSEIM_DB_USER:-mongooseim}"
MONGOOSEIM_DB_PASSWORD_VALUE="${MONGOOSEIM_DB_PASSWORD:-change-me}"

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

python3 - <<'PY' "$TEMPLATE_PATH" "$OUTPUT_PATH" "$PRIMARY_DOMAIN_VALUE" "$MONGOOSEIM_API_KEY_VALUE" "$MONGOOSEIM_DB_NAME_VALUE" "$MONGOOSEIM_DB_USER_VALUE" "$MONGOOSEIM_DB_PASSWORD_VALUE"
from pathlib import Path
import sys

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
primary_domain = sys.argv[3]
api_key = sys.argv[4]
db_name = sys.argv[5]
db_user = sys.argv[6]
db_password = sys.argv[7]

content = template_path.read_text()
content = content.replace("__PRIMARY_DOMAIN__", primary_domain)
content = content.replace("__MONGOOSEIM_API_KEY__", api_key)
content = content.replace("__MONGOOSEIM_DB_NAME__", db_name)
content = content.replace("__MONGOOSEIM_DB_USER__", db_user)
content = content.replace("__MONGOOSEIM_DB_PASSWORD__", db_password)
output_path.write_text(content)
PY

echo "Rendered MongooseIM config at $OUTPUT_PATH"
