#!/bin/bash
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docker_deploy.sh" "$@"
