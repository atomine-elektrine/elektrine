# Self-hosting

Start with the default `core` deployment, then add only the pieces you need.

## Profiles

- `core`: app and Postgres only
- `mail`: separate Haraka deployment layered on top of the `email` module
- `vpn`: optional Docker-managed WireGuard, with optional fleet mode
- `addons`: Caddy edge, Bluesky PDS, onion hosting, and client artifacts

## Guides

- `docker.md`
- `core.md`
- `mail.md`
- `turn.md`
- `vpn.md`
- `../addons/onion.md`
- `../clients/password-manager-extension.md`
