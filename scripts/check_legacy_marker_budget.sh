#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

max_markers=234

count=$(
  rg -n "legacy|backward|backwards|compat|deprecated" apps config scripts deploy \
    -g '!**/test/**' \
    -g '!**/priv/repo/migrations/**' \
    -g '!**/README.md' \
    -g '!**/node_modules/**' \
    -g '!**/priv/static/**' \
    -g '!scripts/check_legacy_marker_budget.sh' \
    | wc -l
)

if ((count > max_markers)); then
  echo "error: production legacy/compat marker count is $count; budget is $max_markers" >&2
  echo "Hint: avoid adding compatibility branches without cleanup ownership, or lower the baseline by removing stale paths first." >&2
  exit 1
fi

echo "Legacy/compat marker budget passed."
