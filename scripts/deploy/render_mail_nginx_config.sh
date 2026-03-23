#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE_PATH="$ROOT_DIR/deploy/nginx/mail.conf.template"
OUTPUT_PATH="${OUTPUT_PATH:-$ROOT_DIR/deploy/docker/generated.mail.nginx.conf}"

usage() {
  cat <<'EOF'
Usage: scripts/deploy/render_mail_nginx_config.sh [--output /tmp/mail.conf]

Renders the nginx stream config used for secure mail protocol proxying.
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
cp "$TEMPLATE_PATH" "$OUTPUT_PATH"
echo "Rendered nginx mail edge config at $OUTPUT_PATH"
