# Self-hosting

Start with the small Docker self-hosting path, then enable only the pieces you
need.

```bash
scripts/deploy/self_host.sh init --domain example.com --email admin@example.com
scripts/deploy/self_host.sh doctor
scripts/deploy/self_host.sh up
```

Advanced services are enabled as presets:

```bash
scripts/deploy/self_host.sh presets
scripts/deploy/self_host.sh enable mail
scripts/deploy/self_host.sh enable dns
scripts/deploy/self_host.sh enable turn
scripts/deploy/self_host.sh doctor
scripts/deploy/self_host.sh up
```

The generated `.env.production` stays small. Preset-specific settings are
appended only when you enable that feature.

## Profiles

- `core`: app and Postgres only
- `mail`: Elektrine mail protocols plus Haraka for production SMTP edge/delivery
- `dns`: optional authoritative DNS service enabled through the Docker `dns` profile
- `vpn`: optional Docker-managed WireGuard, with optional fleet mode
- `addons`: Caddy edge, TURN, Bluesky PDS, onion hosting, and client artifacts

## Guides

- `docker.md`
- `core.md`
- `caddy.md`
- `mail.md`
- `../architecture/dns-module.md`
- `turn.md`
- `vpn.md`
- `../addons/onion.md`
- `../clients/nerve-extension.md`
