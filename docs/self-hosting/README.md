# Self-hosting

Supported profiles:

- `core`: app + Postgres only
- `mail`: separate Haraka deployment layered on top of the `email` module
- `vpn`: enable the `vpn` module and fleet registration key
- `addons`: Caddy edge, Bluesky PDS, onion hosting, and client artifacts

Start with `core`, then add only the pieces you actually need.

Guides:

- `docker.md`
- `core.md`
- `mail.md`
- `vpn.md`
- `../addons/onion.md`
- `../clients/password-manager-extension.md`
