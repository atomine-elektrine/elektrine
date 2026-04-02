# Core Self-hosting

`core` is the default self-host profile. It includes the Phoenix app and
Postgres only.

It does not include:

- Haraka
- VPN
- onion hosting
- an edge proxy

## Start

1. Copy `.env.example` to `.env.production` and fill in real values.
2. Keep `DATABASE_SSL_ENABLED=false` if you are using the bundled Docker Postgres service.
3. Start the stack:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault
```

4. Run migrations once the database is healthy:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault --skip-up
```

## Add-ons

- add Caddy with `--profile caddy`
- add self-hosted STUN/TURN for chat calls with `--profile turn`
- add Docker-managed WireGuard with `--modules chat,social,vault,vpn`
- add Bluesky PDS with `-f deploy/docker/compose.bluesky.yml`

See `mail.md`, `turn.md`, `vpn.md`, and `../addons/onion.md` for the optional
services.
