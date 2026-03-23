#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REQUESTED_MODULES="${ELEKTRINE_RELEASE_MODULES:-all}"
RAW_PROFILES="${DOCKER_PROFILES:-caddy dns email}"

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

normalize_platform_modules "$REQUESTED_MODULES"

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

printf 'Modules: %s\n' "$NORMALIZED_MODULES"
printf 'Profiles: %s\n' "$RAW_PROFILES"
printf '\n'
printf 'Code included in release:\n'
printf '  - chat/social/email/vault/vpn come from ELEKTRINE_RELEASE_MODULES\n'
printf '  - dns is built as a separate release-backed service\n'
printf '\n'
printf 'Containers expected to run:\n'
printf '  - postgres: yes\n'
printf '  - app: yes\n'
printf '  - worker: yes\n'
printf '  - mail: %s\n' "$(bool_label has_profile email)"
printf '  - dns: %s\n' "$(bool_label has_profile dns)"
printf '  - caddy_edge: %s\n' "$(bool_label has_profile caddy)"
printf '  - bluesky_pds: %s\n' "$(bool_label has_profile bluesky)"
printf '\n'
printf 'Runtime toggles:\n'
printf '  - tor lives inside app via ELEKTRINE_ENABLE_TOR\n'
printf '  - mail protocols live in the mail container when the email profile is enabled\n'
