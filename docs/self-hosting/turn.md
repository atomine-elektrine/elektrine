# Self-hosted TURN

Use the `turn` Docker profile when you want Elektrine chat calls to use your own
STUN/TURN service instead of public infrastructure.

Minimum setup:

1. set `PRIMARY_DOMAIN`
2. set `ELEKTRINE_MASTER_SECRET`
3. set `TURN_SHARED_SECRET`
4. deploy with `--profile turn`

Example:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault --profile caddy --profile turn
```

What the profile does:

- starts a coturn daemon on the host network
- uses `PRIMARY_DOMAIN` as the default TURN/STUN hostname
- uses `TURN_SHARED_SECRET` for TURN REST auth credentials
- makes the app advertise your own ICE servers to WebRTC clients automatically

Defaults:

- hostname: `PRIMARY_DOMAIN`
- listener port: `3478`
- relay range: `49160-49200`

Open these ports on your firewall:

- `3478/tcp`
- `3478/udp`
- `49160-49200/tcp`
- `49160-49200/udp`

Optional overrides in `.env.production`:

```env
TURN_HOST=turn.example.com
TURN_PORT=3478
TURN_MIN_PORT=49160
TURN_MAX_PORT=49200
TURN_EXTERNAL_IP=203.0.113.10
TURN_SHARED_SECRET=replace-me
```

Notes:

- if you use an HTTP proxy/CDN, the TURN hostname should be DNS-only, not proxied
- if your server sits behind NAT, set `TURN_EXTERNAL_IP` to the public IPv4
- if you omit `TURN_HOST`, clients use `PRIMARY_DOMAIN`
- raw `docker compose` users must still ensure `TURN_ENABLED=true` in the app
  environment; `scripts/deploy/docker_deploy.sh` does this automatically when
  the `turn` profile is enabled
