# Core Self-hosting

`core` is the minimal app-plus-Postgres profile.

This guide covers the plain app-plus-Postgres baseline in
`deploy/docker/compose.core.yml`. For a normal public Docker host, use
`docs/self-hosting/docker.md`; the wrapper renders the larger stack and defaults
to all modules and profiles unless you override them.

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

The core compose file binds the app HTTP port to `127.0.0.1` by default so it
does not bypass an edge proxy on public hosts. Set `APP_HTTP_BIND=8080:8080`
only for local testing or when an external firewall/proxy already protects the
port.

If you want the module-aware wrapper, use `docs/self-hosting/docker.md` instead.
That path is for the generated multi-service stack and defaults to all modules
and profiles unless you override them.

## Add-ons

These apply when you choose a smaller generated Docker stack instead of the full
default profile set.

- Add Caddy with `--profile caddy`
- Add self-hosted STUN/TURN for chat calls with `--profile turn`
- Add Docker-managed WireGuard with `--modules chat,social,nerve,vpn,atomine`
- Add the dedicated DNS service with `--profile dns`
- Add the Bluesky PDS with `--profile bluesky`

See `mail.md`, `turn.md`, `vpn.md`, and `../addons/onion.md` for the optional
services.
