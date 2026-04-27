# Core Self-hosting

`core` is the default self-host profile. It includes the Phoenix app and
Postgres only.

This guide covers the plain app-plus-Postgres baseline in
`deploy/docker/compose.core.yml`. For a normal public Docker host, use
`docs/self-hosting/docker.md`; the wrapper renders the larger stack and defaults
to the `caddy` profile unless you override profiles.

It does not include:

- Haraka
- VPN
- onion hosting
- an edge proxy

## Start

1. Copy `.env.example` to `.env.production` and fill in real values.
2. Keep `DATABASE_SSL_ENABLED=false` if you are using the bundled Docker Postgres service.
3. Start the core stack:

```bash
docker compose --env-file .env.production -f deploy/docker/compose.core.yml up -d --build
```

If you want the module-aware wrapper, use `docs/self-hosting/docker.md` instead.
That path is for the generated multi-service stack and defaults to `caddy` unless
you override profiles.

## Add-ons

- Add Caddy with `--profile caddy`
- Add self-hosted STUN/TURN for chat calls with `--profile turn`
- Add Docker-managed WireGuard with `--modules chat,social,vault,vpn`
- Add the dedicated DNS service with `--profile dns`
- Add the Bluesky PDS with `--profile bluesky`

See `mail.md`, `turn.md`, `vpn.md`, and `../addons/onion.md` for the optional
services.
