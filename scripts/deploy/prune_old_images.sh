#!/bin/bash
# Prune old Elektrine app images on a Docker host.
#
# Keeps the N most recently created tags for the configured image repository,
# never removes images still referenced by a container, then optionally cleans
# dangling images and unused build cache.
#
# Env:
#   IMAGE_REPO / ELEKTRINE_IMAGE_REPO   Image repository (default ghcr.io/atomine-elektrine/elektrine)
#   ELEKTRINE_IMAGE_KEEP_COUNT          Tags to keep (default 3)
#   ELEKTRINE_PRUNE_DANGLING_IMAGES     1/0 prune dangling images (default 1)
#   ELEKTRINE_PRUNE_BUILD_CACHE         1/0 prune unused build cache (default 1)
#   DOCKER_CMD                          Docker binary prefix, e.g. "sudo -n docker"
#   ELEKTRINE_SKIP_IMAGE_PRUNE          1/true to no-op (for callers)
set -euo pipefail

truthy() {
  [[ "${1:-false}" =~ ^(1|true|TRUE|yes|YES)$ ]]
}

if truthy "${ELEKTRINE_SKIP_IMAGE_PRUNE:-false}"; then
  echo "Skipping image prune (ELEKTRINE_SKIP_IMAGE_PRUNE is set)"
  exit 0
fi

IMAGE_REPO="${ELEKTRINE_IMAGE_REPO:-${IMAGE_REPO:-ghcr.io/atomine-elektrine/elektrine}}"
KEEP_COUNT="${ELEKTRINE_IMAGE_KEEP_COUNT:-3}"
PRUNE_DANGLING="${ELEKTRINE_PRUNE_DANGLING_IMAGES:-1}"
PRUNE_BUILD_CACHE="${ELEKTRINE_PRUNE_BUILD_CACHE:-1}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: scripts/deploy/prune_old_images.sh [--keep N] [--repo REPO] [--dry-run]

Removes old tags of the Elektrine app image, keeping the newest N tags (default 3).
Images used by any container are never removed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      KEEP_COUNT="$2"
      shift 2
      ;;
    --repo)
      IMAGE_REPO="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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

if [[ ! "$KEEP_COUNT" =~ ^[0-9]+$ ]] || [[ "$KEEP_COUNT" -lt 1 ]]; then
  echo "Error: --keep / ELEKTRINE_IMAGE_KEEP_COUNT must be a positive integer" >&2
  exit 1
fi

if [[ -n "${DOCKER_CMD:-}" ]]; then
  # shellcheck disable=SC2206
  DOCKER_BIN=($DOCKER_CMD)
else
  DOCKER_BIN=(docker)
fi

if ! "${DOCKER_BIN[@]}" info >/dev/null 2>&1; then
  if [[ -z "${DOCKER_CMD:-}" ]] && sudo -n docker info >/dev/null 2>&1; then
    DOCKER_BIN=(sudo -n docker)
  else
    echo "Error: Docker daemon is not accessible" >&2
    exit 1
  fi
fi

# Collect full image digests referenced by any container (running or stopped).
declare -A IN_USE_IDS=()
while IFS= read -r image_id; do
  [[ -z "$image_id" ]] && continue
  image_id="${image_id#sha256:}"
  IN_USE_IDS["$image_id"]=1
done < <("${DOCKER_BIN[@]}" ps -aq | xargs -r "${DOCKER_BIN[@]}" inspect --format '{{.Image}}' 2>/dev/null || true)

# List tags for this repository, newest first (full digests for in-use matching).
# Format: created_at\tid\trepository:tag
mapfile -t IMAGE_LINES < <(
  "${DOCKER_BIN[@]}" images --no-trunc --format '{{.CreatedAt}}\t{{.ID}}\t{{.Repository}}:{{.Tag}}' \
    | awk -F '\t' -v repo="$IMAGE_REPO" '
        $3 ~ ("^" repo ":") && $3 !~ /:<none>$/ { print }
      ' \
    | sort -r
)

if [[ "${#IMAGE_LINES[@]}" -eq 0 ]]; then
  echo "No local images found for $IMAGE_REPO"
else
  echo "Found ${#IMAGE_LINES[@]} local tag(s) for $IMAGE_REPO (keeping $KEEP_COUNT)"

  declare -A KEEP_IDS=()
  kept=0
  to_remove=()

  for line in "${IMAGE_LINES[@]}"; do
    created="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    image_id="${rest%%$'\t'*}"
    ref="${rest#*$'\t'}"
    image_id="${image_id#sha256:}"

    if [[ "$kept" -lt "$KEEP_COUNT" ]]; then
      KEEP_IDS["$image_id"]=1
      kept=$((kept + 1))
      echo "  keep  $ref ($image_id, $created)"
      continue
    fi

    if [[ -n "${IN_USE_IDS[$image_id]:-}" || -n "${KEEP_IDS[$image_id]:-}" ]]; then
      echo "  skip  $ref ($image_id still in use or already kept)"
      continue
    fi

    to_remove+=("$ref")
    echo "  drop  $ref ($image_id, $created)"
  done

  if [[ "${#to_remove[@]}" -eq 0 ]]; then
    echo "No old $IMAGE_REPO tags to remove"
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry run: would remove ${#to_remove[@]} tag(s)"
  else
    # Remove by tag ref so multi-tagged digests are handled one tag at a time.
    removed=0
    for ref in "${to_remove[@]}"; do
      if "${DOCKER_BIN[@]}" rmi "$ref" >/dev/null 2>&1; then
        removed=$((removed + 1))
      else
        echo "  warn: could not remove $ref (may still be shared or in use)" >&2
      fi
    done
    echo "Removed $removed old tag(s) of $IMAGE_REPO"
  fi
fi

if truthy "$PRUNE_DANGLING"; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry run: would prune dangling images"
  else
    echo "Pruning dangling images..."
    "${DOCKER_BIN[@]}" image prune -f >/dev/null || true
  fi
fi

if truthy "$PRUNE_BUILD_CACHE"; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry run: would prune unused build cache"
  else
    echo "Pruning unused build cache..."
    # -f only; do not use -a so active/recent build cache for the current image remains.
    "${DOCKER_BIN[@]}" builder prune -f >/dev/null 2>&1 || true
  fi
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  df -h / 2>/dev/null | tail -1 || true
fi

echo "Image prune complete"
