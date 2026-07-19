#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Design-consistency budgets for the web UI.
#
# Each pattern below is a styling decision that should live in one place
# (apps/elektrine_web/lib/elektrine_web/components/ui/ or the token layer in
# apps/elektrine/assets/css/) instead of being re-authored inline in
# templates. Budgets are ratchets: they hold the current count as a ceiling.
# When you remove occurrences, lower the budget to match. Never raise a
# budget without a review conversation.
#
# Conventions enforced:
# - Buttons render through <.button>/<.icon_button>, not raw `btn btn-*`.
#   (Residual budget: file-input labels, dropdown/summary toggles, dynamic
#   class helpers, phx-hook buttons.)
# - Cards render through <.card>/<.stat_card>/<.info_card>, not raw markup.
#   (Residual budget: section/aside/details card shells, translucent
#   sub-cards, JS-wired containers, and stateful LiveComponent roots —
#   LiveView requires those to be a static HTML tag, so <.card> cannot be
#   the root of a live_component render/1.)
# - Type scale: use text-2xs/text-3xs tokens, never text-[NNpx].
#   (Residual budget: two 9px notification count badges.)
# - Radius: rounded-lg (small), rounded-box (surfaces), rounded-full (pills).
# - Colors come from semantic tokens; no raw hex in .heex templates.
# - Inline style attrs are frozen at the current count; prefer utilities.

templates=(apps/elektrine_web/lib/elektrine_web)
ui_dir='!**/components/ui/**'

fail=0

check_budget() {
  local name="$1" budget="$2" pattern="$3"
  shift 3
  local count
  # rg exits 1 on zero matches, which is a passing result for 0-budgets.
  count=$({ rg -n "$pattern" "${templates[@]}" -g "$ui_dir" "$@" || true; } | wc -l)
  if ((count > budget)); then
    echo "error: $name count is $count; budget is $budget" >&2
    echo "  pattern: $pattern" >&2
    rg -n "$pattern" "${templates[@]}" -g "$ui_dir" "$@" | head -5 >&2 || true
    fail=1
  else
    echo "ok: $name $count/$budget"
  fi
}

check_budget "raw btn markup" 48 '[ "]btn[ "]'
check_budget "raw card markup" 66 '[ "]card[ "]'
check_budget "arbitrary text-[..px]" 2 'text-\[[0-9]+px\]'
check_budget "off-convention radius" 0 '"[^"]*\brounded(-(sm|md|xl|2xl|3xl))?[ "]'
check_budget "raw hex colors in templates" 0 '#[0-9a-fA-F]{6}\b' --glob '*.heex'
check_budget "inline style attrs" 30 '\bstyle="'

if ((fail)); then
  echo "Design consistency check failed. Fix the overage or discuss raising the budget." >&2
  exit 1
fi

echo "Design consistency budgets passed."
