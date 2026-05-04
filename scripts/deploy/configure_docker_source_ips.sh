#!/bin/bash
set -euo pipefail

DAEMON_JSON="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"
CHECK_ONLY=0
RESTART_DOCKER=1

usage() {
  cat <<'EOF'
Usage: scripts/deploy/configure_docker_source_ips.sh [--check] [--no-restart] [--daemon-json /etc/docker/daemon.json]

Sets Docker Engine "userland-proxy": false so bridged Caddy containers can
receive kernel-forwarded connections with preserved source IPs on Linux.

The script backs up an existing daemon.json, validates the generated config when
dockerd is available, and restarts Docker unless --no-restart is provided.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --no-restart)
      RESTART_DOCKER=0
      shift
      ;;
    --daemon-json)
      DAEMON_JSON="$2"
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

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Error: Docker source IP preservation via userland-proxy=false is Linux-only." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required to update $DAEMON_JSON safely." >&2
  exit 1
fi

SUDO=()
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  daemon_parent="$(dirname "$DAEMON_JSON")"
  needs_sudo=0

  if [[ -e "$DAEMON_JSON" ]]; then
    if [[ ! -r "$DAEMON_JSON" || ! -w "$DAEMON_JSON" ]]; then
      needs_sudo=1
    fi
  elif [[ -d "$daemon_parent" ]]; then
    if [[ ! -w "$daemon_parent" ]]; then
      needs_sudo=1
    fi
  elif [[ ! -w "$(dirname "$daemon_parent")" ]]; then
    needs_sudo=1
  fi

  if [[ "$needs_sudo" -eq 1 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "Error: sudo is required to update $DAEMON_JSON." >&2
      exit 1
    fi

    SUDO=(sudo -n)

    if ! "${SUDO[@]}" true >/dev/null 2>&1; then
      echo "Error: passwordless sudo is required to update $DAEMON_JSON automatically." >&2
      echo "Hint: run this script as root, or update Docker daemon.json manually." >&2
      exit 1
    fi
  fi
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

current_json="$tmp_dir/current.json"
updated_json="$tmp_dir/daemon.json"
state_file="$tmp_dir/state"

if "${SUDO[@]}" test -f "$DAEMON_JSON"; then
  "${SUDO[@]}" cp "$DAEMON_JSON" "$current_json"
else
  printf '{}\n' > "$current_json"
fi

python3 - "$current_json" "$updated_json" "$state_file" <<'PY'
import json
import sys

source_path, target_path, state_path = sys.argv[1:]

try:
    with open(source_path, "r", encoding="utf-8") as source:
        config = json.load(source)
except json.JSONDecodeError as error:
    print(f"Error: invalid Docker daemon JSON: {error}", file=sys.stderr)
    sys.exit(1)

if not isinstance(config, dict):
    print("Error: Docker daemon JSON must be a top-level object.", file=sys.stderr)
    sys.exit(1)

changed = config.get("userland-proxy") is not False
config["userland-proxy"] = False

with open(target_path, "w", encoding="utf-8") as target:
    json.dump(config, target, indent=2, sort_keys=True)
    target.write("\n")

with open(state_path, "w", encoding="utf-8") as state:
    state.write("changed" if changed else "unchanged")
PY

state="$(<"$state_file")"

if [[ "$state" == "unchanged" ]]; then
  echo "ok: Docker daemon already has userland-proxy=false"
  exit 0
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "warn: Docker daemon does not have userland-proxy=false" >&2
  exit 1
fi

if command -v dockerd >/dev/null 2>&1; then
  if ! validation_output="$(dockerd --validate --config-file "$updated_json" 2>&1)"; then
    printf '%s\n' "$validation_output" >&2
    exit 1
  fi
else
  echo "warn: dockerd is not on PATH; skipping daemon.json validation" >&2
fi

"${SUDO[@]}" mkdir -p "$(dirname "$DAEMON_JSON")"

if "${SUDO[@]}" test -f "$DAEMON_JSON"; then
  backup_path="$DAEMON_JSON.elektrine-$(date -u +%Y%m%d%H%M%S).bak"
  "${SUDO[@]}" cp -p "$DAEMON_JSON" "$backup_path"
  echo "Info: backed up existing Docker daemon config to $backup_path" >&2
fi

"${SUDO[@]}" install -m 0644 "$updated_json" "$DAEMON_JSON"
echo "Info: set Docker daemon userland-proxy=false in $DAEMON_JSON" >&2

if [[ "$RESTART_DOCKER" -ne 1 ]]; then
  echo "Info: restart Docker before redeploying for source IP preservation to take effect." >&2
  exit 0
fi

if command -v systemctl >/dev/null 2>&1; then
  "${SUDO[@]}" systemctl restart docker
elif command -v service >/dev/null 2>&1; then
  "${SUDO[@]}" service docker restart
else
  echo "Error: could not find systemctl or service to restart Docker." >&2
  echo "Hint: restart Docker manually before redeploying." >&2
  exit 1
fi

echo "Info: restarted Docker so source IP preservation can take effect." >&2
