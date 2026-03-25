# Core Self-hosting

`core` is the default self-host profile:

- Phoenix app
- Postgres
- no Haraka
- no VPN
- no onion
- no edge proxy

1. Copy `.env.example` to `.env.production` and fill in real values.
   For the bundled Docker Postgres service, keep `DATABASE_SSL_ENABLED=false`.
2. Start the stack:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault
```

3. Run migrations once the database is healthy:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault --skip-up
```

Optional add-ons:

- add Caddy with `--profile caddy`
- add Bluesky PDS with `-f deploy/docker/compose.bluesky.yml`
- see `mail.md`, `vpn.md`, and `../addons/onion.md` for advanced modules
