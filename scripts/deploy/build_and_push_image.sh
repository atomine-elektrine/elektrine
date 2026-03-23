#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/atomine-elektrine/elektrine}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)}"
FULL_IMAGE="$IMAGE_REPO:$IMAGE_TAG"
RELEASE_MODULES="${ELEKTRINE_RELEASE_MODULES:-all}"
PRIMARY_DOMAIN_VALUE="${DOCKER_BUILD_PRIMARY_DOMAIN:-example.com}"
EMAIL_DOMAIN_VALUE="${DOCKER_BUILD_EMAIL_DOMAIN:-example.com}"
SUPPORTED_DOMAINS_VALUE="${DOCKER_BUILD_SUPPORTED_DOMAINS:-example.com}"
PROFILE_BASE_DOMAINS_VALUE="${DOCKER_BUILD_PROFILE_BASE_DOMAINS:-example.com}"
PUSH_LATEST=0

usage() {
  cat <<'EOF'
Usage: scripts/deploy/build_and_push_image.sh [--tag custom-tag] [--latest]

Builds the main Elektrine Docker image locally and pushes it to GHCR.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      IMAGE_TAG="$2"
      FULL_IMAGE="$IMAGE_REPO:$IMAGE_TAG"
      shift 2
      ;;
    --latest)
      PUSH_LATEST=1
      shift
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

docker build \
  -f "$ROOT_DIR/deploy/docker/Dockerfile" \
  -t "$FULL_IMAGE" \
  --build-arg RELEASE_NAME=elektrine \
  --build-arg ELEKTRINE_RELEASE_MODULES="$RELEASE_MODULES" \
  --build-arg PRIMARY_DOMAIN="$PRIMARY_DOMAIN_VALUE" \
  --build-arg EMAIL_DOMAIN="$EMAIL_DOMAIN_VALUE" \
  --build-arg SUPPORTED_DOMAINS="$SUPPORTED_DOMAINS_VALUE" \
  --build-arg PROFILE_BASE_DOMAINS="$PROFILE_BASE_DOMAINS_VALUE" \
  "$ROOT_DIR"

docker push "$FULL_IMAGE"

if [[ "$PUSH_LATEST" -eq 1 ]]; then
  docker tag "$FULL_IMAGE" "$IMAGE_REPO:latest"
  docker push "$IMAGE_REPO:latest"
fi

echo "Pushed $FULL_IMAGE"
