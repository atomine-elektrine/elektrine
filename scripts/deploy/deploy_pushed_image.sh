#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/atomine-elektrine/elektrine}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)}"
TARGET_IMAGE="$IMAGE_REPO:$IMAGE_TAG"
DEPLOY_HOST="${DEPLOY_HOST:-}"
DEPLOY_USER="${DEPLOY_USER:-}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"
DEPLOY_PATH="${DEPLOY_PATH:-/opt/elektrine}"
RELEASE_MODULES="${ELEKTRINE_RELEASE_MODULES:-all}"
DOCKER_PROFILES_VALUE="${DOCKER_PROFILES:-caddy dns email tor}"

usage() {
  cat <<'EOF'
Usage: scripts/deploy/deploy_pushed_image.sh --host user@example.com [--tag custom-tag]

Deploys an already-pushed GHCR image to the remote Docker host.
Requires the remote host to have access to the image registry.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      DEPLOY_USER="$2"
      shift 2
      ;;
    --port)
      DEPLOY_PORT="$2"
      shift 2
      ;;
    --path)
      DEPLOY_PATH="$2"
      shift 2
      ;;
    --tag)
      IMAGE_TAG="$2"
      TARGET_IMAGE="$IMAGE_REPO:$IMAGE_TAG"
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

if [[ -z "$DEPLOY_USER" ]]; then
  echo "Error: --host user@host is required" >&2
  exit 1
fi

PROFILE_ARGS=""
for profile in $DOCKER_PROFILES_VALUE; do
  PROFILE_ARGS="$PROFILE_ARGS --profile $profile"
done

ssh -p "$DEPLOY_PORT" "$DEPLOY_USER" \
  "DEPLOY_PATH='$DEPLOY_PATH' TARGET_IMAGE='$TARGET_IMAGE' ELEKTRINE_RELEASE_MODULES='$RELEASE_MODULES' PROFILE_ARGS='$PROFILE_ARGS' bash -s" <<'EOF'
set -euo pipefail

if docker info >/dev/null 2>&1; then
  :
elif sudo -n docker info >/dev/null 2>&1; then
  alias docker='sudo -n docker'
else
  echo "No Docker access on remote host" >&2
  exit 1
fi

cd "$DEPLOY_PATH"

override_file="$(mktemp /tmp/elektrine.manual-image.override.XXXXXX.yml)"
trap 'rm -f "$override_file"' EXIT

cat > "$override_file" <<OVERRIDE
services:
  app:
    image: ${TARGET_IMAGE}
  worker:
    image: ${TARGET_IMAGE}
  mail:
    image: ${TARGET_IMAGE}
  dns:
    image: ${TARGET_IMAGE}
OVERRIDE

COMPOSE_PROJECT_NAME="docker" COMPOSE_PROJECT_DIRECTORY="$DEPLOY_PATH/deploy/docker" \
  bash scripts/deploy/docker_deploy.sh \
  --modules "$ELEKTRINE_RELEASE_MODULES" \
  --env-file "$DEPLOY_PATH/.env.production" \
  --output "$DEPLOY_PATH/deploy/docker/generated.docker.yml" \
  --pull \
  --skip-build \
  --compose-override "$override_file" \
  $PROFILE_ARGS
EOF

echo "Deployed $TARGET_IMAGE"
