#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

mapfile -t tracked_generated < <(
  git ls-files \
    'apps/*/priv/static/assets/*' \
    'apps/*/priv/static/cache_manifest.json' \
    'apps/*/assets/node_modules/*' \
    'deploy/generated/*' \
    'deploy/docker/generated*.yml' \
    'deploy/docker/generated.Caddyfile' |
    grep -v '^deploy/generated/\.gitkeep$' || true
)

if ((${#tracked_generated[@]} == 0)); then
  echo "No tracked generated artifacts found."
  exit 0
fi

echo "Tracked generated artifacts found. These paths should stay disposable:" >&2
printf '  %s\n' "${tracked_generated[@]}" >&2
exit 1
