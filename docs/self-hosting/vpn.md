# VPN Self-hosting

VPN is optional. When you enable the `vpn` module, the Docker deploy starts a
bundled WireGuard service in the same stack.

## Recommended Setup

For most self-hosters, use one server running both Elektrine and WireGuard.

1. add `vpn` to `ELEKTRINE_ENABLED_MODULES`
2. optionally set `VPN_SELFHOST_ENDPOINT_HOST` or `VPN_SELFHOST_PUBLIC_IP` if you want to pin the client endpoint explicitly
3. optionally set `VPN_SELFHOST_PRIVATE_KEY`
4. deploy or restart the Docker stack

The bundled `vpn` container then:

- creates or restores the WireGuard private key
- derives the public key
- auto-detects the public IP when no endpoint is configured
- reconciles peers directly from Elektrine

## Configuration

Defaults:

- `VPN_SELFHOST_ADDRESS=10.8.0.1/24`
- `VPN_SELFHOST_LISTEN_PORT=51820`
- `VPN_SELFHOST_ENDPOINT_PORT=<same as listen port by default>`
- `VPN_SELFHOST_INTERNAL_IP_RANGE=10.8.0.0/24`
- `VPN_SELFHOST_DNS_SERVERS=1.1.1.1, 1.0.0.1`

Optional labels:

- `VPN_SELFHOST_NAME`
- `VPN_SELFHOST_LOCATION`

If neither `VPN_SELFHOST_ENDPOINT_HOST` nor `VPN_SELFHOST_PUBLIC_IP` is set,
the `vpn` container falls back to outbound IP autodetection.

If `VPN_SELFHOST_ENDPOINT_PORT` is unset, generated client configs use
`VPN_SELFHOST_LISTEN_PORT` so future deploys keep advertising the live WireGuard port.

If you are not using WireGuard, remove `vpn` from `ELEKTRINE_ENABLED_MODULES`.

## Fleet Mode

For a multi-server VPN fleet, set `VPN_FLEET_REGISTRATION_KEY` on the control
plane so nodes can self-register through the API.

Two ways to run fleet nodes:

- **Standalone agent (recommended at scale)** — `scripts/vpn/` ships a DB-free
  WireGuard node agent. It registers over HTTPS, then pulls peers, applies them,
  reports stats, and heartbeats — without a database connection. See
  `scripts/vpn/README.md`. This is the right choice for dozens to hundreds of
  nodes, since it keeps Postgres connections and exposure off the edge.
- **Bundled container** — run the Elektrine image with `ELEKTRINE_RUNTIME_ROLE=vpn`
  pointed at the central database. Simplest for a few nodes and required for
  Shadowsocks nodes (per-port `ss-server` management).

Each WireGuard node is auto-assigned a distinct internal `/24` at registration,
carved from `VPN_WG_SUPERNET` (default `10.8.0.0/16`; widen it before you
approach ~256 nodes). Nodes that stop heartbeating for ~5 minutes are drained
automatically (marked `offline`) so no new users are assigned to them.

## What The Docker VPN Service Does

- removes stale or revoked peers from `wg0`
- applies current peers with `wg set`
- reads handshake and bandwidth counters from `wg show <interface> dump`
- updates Elektrine's VPN stats and heartbeat automatically

## Notes

- the `vpn` service runs with `host` networking and `NET_ADMIN` so it can own the WireGuard interface
- enable `net.ipv4.ip_forward=1` and, if you use IPv6 routing, `net.ipv6.conf.all.forwarding=1` on the host before starting the `vpn` profile
- `scripts/deploy/docker_deploy.sh` enables the `vpn` profile automatically when the `vpn` module is selected
- if you need a different interface name, set `VPN_SELFHOST_WG_INTERFACE`
