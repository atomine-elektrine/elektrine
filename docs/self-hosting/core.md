# Core Self-hosting

`core` is the default self-host profile:

- Phoenix app
- Postgres
- no Haraka
- no VPN
- no onion
- no edge proxy

1. Copy `env/core.env.example` to `.env.production` and fill in real values.
2. Start the stack:

```bash
docker compose -f deploy/docker/compose.core.yml up --build -d
```

3. Run migrations once the database is healthy:

```bash
docker compose -f deploy/docker/compose.core.yml run --rm app bin/elektrine eval "Elektrine.Release.migrate()"
```

Optional add-ons:

- add Caddy with `-f deploy/docker/compose.edge.yml`
- add Bluesky PDS with `-f deploy/docker/compose.bluesky.yml`
- see `mail.md`, `vpn.md`, and `../addons/onion.md` for advanced modules
