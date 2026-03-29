#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIX_ENV="${MIX_ENV:-prod}"
RELEASE_NAME="${RELEASE_NAME:-elektrine}"
REQUESTED_MODULES=""

# shellcheck source=scripts/lib/module_selection.sh
source "$ROOT_DIR/scripts/lib/module_selection.sh"

usage() {
  cat <<'EOF'
Usage: scripts/release/deploy_release.sh [--modules chat,email] [--release-name elektrine] [--mix-env prod]

Builds a hoster release through release_builder/, never through the root umbrella.
The release artifact is copied to _deploy_release/<release-name>/ for packaging.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --modules)
      REQUESTED_MODULES="$2"
      shift 2
      ;;
    --release-name)
      RELEASE_NAME="$2"
      shift 2
      ;;
    --mix-env)
      MIX_ENV="$2"
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
  REQUESTED_MODULES="$(default_release_modules)"
fi

normalize_platform_modules "$REQUESTED_MODULES"

export MIX_ENV
export RELEASE_NAME
export ELEKTRINE_RELEASE_MODULES="$NORMALIZED_MODULES"

echo "Building ${RELEASE_NAME} via release_builder for modules: ${ELEKTRINE_RELEASE_MODULES}"

cd "$ROOT_DIR/release_builder"

mix tailwind elektrine --minify
mix esbuild elektrine --minify
mix phx.digest ../apps/elektrine/priv/static --no-compile
rm -rf ../_build/release_builder
mix clean
mix compile
mix release "$RELEASE_NAME" --overwrite

RELEASE_DIR="$ROOT_DIR/_build/release_builder/$BUILD_SLUG/$MIX_ENV/rel/$RELEASE_NAME"
DEPLOY_DIR="$ROOT_DIR/_deploy_release/$RELEASE_NAME"
RELEASE_CONFIG_DIR="$RELEASE_DIR/config"

if [[ ! -d "$RELEASE_DIR" ]]; then
  echo "Expected release output was not created: $RELEASE_DIR" >&2
  exit 1
fi

mkdir -p "$RELEASE_CONFIG_DIR"
cp "$ROOT_DIR/config/runtime.exs" "$RELEASE_CONFIG_DIR/runtime.exs"

rm -rf "$DEPLOY_DIR"
mkdir -p "$(dirname "$DEPLOY_DIR")"
cp -R "$RELEASE_DIR" "$DEPLOY_DIR"

echo "Release copied to $DEPLOY_DIR"
