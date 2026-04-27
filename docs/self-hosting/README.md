# Self-hosting

Start with the default `core` deployment, then add only the pieces you need.

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
- `../clients/password-manager-extension.md`
