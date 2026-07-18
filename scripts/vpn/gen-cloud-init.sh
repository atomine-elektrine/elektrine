#!/usr/bin/env bash
#
# Generate a provider-agnostic cloud-init (#cloud-config) blob that installs and
# starts the Elektrine VPN fleet agent on a fresh VPS.
#
# The output is self-contained: it inlines the agent script and systemd unit
# from this directory plus your node's env file, so it works as the "user data"
# for any provider (Hetzner, DigitalOcean, Vultr, AWS, …) or as Terraform
# user_data. Because the agent is inlined at generation time, there is a single
# source of truth — edit elektrine-vpn-agent.sh and regenerate.
#
# Usage:
#   ./gen-cloud-init.sh --env node.env > user-data.yaml
#
# Then paste user-data.yaml into the provider's user-data field, or reference it
# from Terraform: user_data = file("user-data.yaml").
#
# The env file is the same format as elektrine-vpn-agent.env.example. At minimum
# it must set CONTROL_PLANE_URL and VPN_FLEET_REGISTRATION_KEY.
#
# NOTE: user-data is readable via most providers' metadata API, so the fleet key
# it contains is exposed to anything on the node that can reach that API. That is
# acceptable for bootstrap (the key only grants registration); rotate it
# periodically and, at larger scale, fetch it at boot from a secrets store
# instead of embedding it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT="${SCRIPT_DIR}/elektrine-vpn-agent.sh"
UNIT="${SCRIPT_DIR}/elektrine-vpn-agent.service"

ENV_FILE=""

usage() {
  echo "usage: $0 --env <node.env>" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "$ENV_FILE" ]] || usage
[[ -f "$ENV_FILE" ]] || { echo "env file not found: $ENV_FILE" >&2; exit 1; }
[[ -f "$AGENT" ]] || { echo "agent script not found: $AGENT" >&2; exit 1; }
[[ -f "$UNIT" ]] || { echo "systemd unit not found: $UNIT" >&2; exit 1; }

# Sanity-check the required env keys are present (uncommented).
for key in CONTROL_PLANE_URL VPN_FLEET_REGISTRATION_KEY; do
  if ! grep -qE "^[[:space:]]*${key}=" "$ENV_FILE"; then
    echo "env file is missing required key: ${key}" >&2
    exit 1
  fi
done

# Indent a file's contents by 6 spaces for a YAML block scalar. Empty lines are
# left empty, which block scalars accept.
indent() {
  sed 's/^\(.\)/      \1/' "$1"
}

cat <<'HEADER'
#cloud-config
package_update: true
packages:
  - wireguard-tools
  - jq
  - curl
  - iptables
write_files:
  - path: /usr/local/bin/elektrine-vpn-agent.sh
    permissions: '0755'
    owner: root:root
    content: |
HEADER

indent "$AGENT"

cat <<'MID1'
  - path: /etc/systemd/system/elektrine-vpn-agent.service
    permissions: '0644'
    owner: root:root
    content: |
MID1

indent "$UNIT"

cat <<'MID2'
  - path: /etc/elektrine-vpn-agent.env
    permissions: '0600'
    owner: root:root
    content: |
MID2

indent "$ENV_FILE"

cat <<'FOOTER'
runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, elektrine-vpn-agent ]
FOOTER
