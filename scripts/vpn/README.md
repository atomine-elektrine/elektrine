# Elektrine VPN fleet agent

A DB-free node agent for running WireGuard exit nodes at fleet scale.

## Why

The bundled Docker `vpn` service reconciles peers straight from Postgres. That's
perfect for one box, but once you run dozens or hundreds of nodes, giving every
node a database connection exhausts the pool and widens the database's exposure.

This agent talks only to the control-plane HTTP API over HTTPS:

- **register once** with the fleet bootstrap key, then store a per-node API key
- **every interval**: pull the peer set, apply it to WireGuard, push bandwidth
  stats, and send a heartbeat

So nodes never touch the database. The control plane auto-allocates each node a
distinct internal `/24` at registration, so you don't hand-assign ranges.

## Requirements

- Linux with WireGuard (`wg`, `ip`)
- `curl`, `jq`
- root / `CAP_NET_ADMIN`

Shadowsocks nodes are out of scope here — run the bundled Elektrine `vpn`
container for those (it manages `ss-server` per port).

## Control-plane setup (once)

Set `VPN_FLEET_REGISTRATION_KEY` to a strong secret on the control plane.
Optionally set `VPN_WG_SUPERNET` (default `10.8.0.0/16`, up to 256 nodes) if you
need more nodes or a different private range — widen it before you approach the
limit.

## Per-node install

```sh
install -m 0755 elektrine-vpn-agent.sh /usr/local/bin/elektrine-vpn-agent.sh
install -m 0600 elektrine-vpn-agent.env.example /etc/elektrine-vpn-agent.env
# edit /etc/elektrine-vpn-agent.env: CONTROL_PLANE_URL, VPN_FLEET_REGISTRATION_KEY, NODE_*
install -m 0644 elektrine-vpn-agent.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now elektrine-vpn-agent
```

Open UDP `ENDPOINT_PORT` (default 51820) in the node's firewall/security group.
With `MANAGE_INTERFACE=1` (default) the agent brings up `wg0`, enables
`ip_forward`, and adds a MASQUERADE rule for its allocated range. Set it to `0`
if your provisioning (cloud-init/Ansible) owns the interface and NAT.

## Lifecycle notes

- Node credentials live in `${STATE_DIR}/agent.env` (`SERVER_ID`, `API_KEY`) and
  the WireGuard private key in `${STATE_DIR}/wg-private.key`. Back these up if you
  want to rebuild a node without re-registering.
- Registration is keyed on public IP. If a node's record already exists but the
  local state is gone, the fleet API will **not** hand back credentials (by
  design). Either delete the stale server in the admin UI and let it re-register,
  or restore `agent.env`.
- Missed heartbeats: the control plane drains a node (marks it `offline`, so no
  new users are assigned) after ~5 minutes without a heartbeat.

## Verify a node

```sh
journalctl -u elektrine-vpn-agent -f     # watch reconcile/heartbeat logs
wg show wg0                              # peers applied by the agent
```
