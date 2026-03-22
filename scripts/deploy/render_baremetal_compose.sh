#!/bin/bash
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/render_docker_compose.sh" "$@"
