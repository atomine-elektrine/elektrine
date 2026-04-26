#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REQUESTED_MODULES=""
RAW_PROFILES="${DOCKER_PROFILES:-caddy}"

# shellcheck source=scripts/lib/module_selection.sh
source "$ROOT_DIR/scripts/lib/module_selection.sh"

usage() {
  cat <<'EOF'
Usage: scripts/deploy/explain_deploy.sh [--modules chat,social,email] [--profiles "caddy dns email"]

Prints which product modules are compiled and which Docker services/profiles run.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --modules)
      REQUESTED_MODULES="$2"
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

if [[ -z "$REQUESTED_MODULES" ]]; then
  REQUESTED_MODULES="$(default_enabled_modules)"
fi

normalize_platform_modules "$REQUESTED_MODULES"
ENABLED_MODULES="$NORMALIZED_MODULES"

REQUESTED_RELEASE_MODULES="${ELEKTRINE_RELEASE_MODULES:-$ENABLED_MODULES}"
normalize_platform_modules "$REQUESTED_RELEASE_MODULES"
RELEASE_MODULES="$NORMALIZED_MODULES"

read -r -a PROFILE_ARRAY <<< "$RAW_PROFILES"

has_profile() {
  local wanted="$1"
  local profile=""

  for profile in "${PROFILE_ARRAY[@]:-}"; do
    if [[ "$profile" == "$wanted" ]]; then
      return 0
    fi
  done

  return 1
}

bool_label() {
  if "$@"; then
    printf 'yes'
  else
    printf 'no'
  fi
}

printf 'Enabled modules: %s\n' "$ENABLED_MODULES"
printf 'Release modules: %s\n' "$RELEASE_MODULES"
printf 'Profiles: %s\n' "$RAW_PROFILES"
printf '\n'
printf 'Code included in release:\n'
printf '  - by default this matches --modules / ELEKTRINE_ENABLED_MODULES\n'
if [[ "$RELEASE_MODULES" != "$ENABLED_MODULES" ]]; then
  printf '  - ELEKTRINE_RELEASE_MODULES is overriding build-time selection\n'
fi
printf '  - dns is built as a separate release-backed service\n'
printf '\n'
printf 'Containers expected to run:\n'
printf '  - postgres: yes\n'
printf '  - app: yes\n'
printf '  - worker: yes\n'
printf '  - mail: %s\n' "$(bool_label has_profile email)"
printf '  - dns: %s\n' "$(bool_label has_profile dns)"
printf '  - tor: %s\n' "$(bool_label has_profile tor)"
printf '  - turn: %s\n' "$(bool_label has_profile turn)"
printf '  - caddy_edge: %s\n' "$(bool_label has_profile caddy)"
printf '  - bluesky_pds: %s\n' "$(bool_label has_profile bluesky)"
printf '\n'
printf 'Runtime toggles:\n'
printf '  - tor is enabled inside app when the tor profile is present\n'
printf '  - mail protocols live in the mail container when the email profile is enabled\n'
