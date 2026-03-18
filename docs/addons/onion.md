# Onion Hosting

Onion hosting is an add-on, not part of the default self-host profile.

Relevant files:

- `deploy/onion/torrc`
- `deploy/docker/start.sh`
- `deploy/docker/docker-entrypoint.sh`
- `scripts/onion/sync-onion-key-secrets.sh`

To enable it:

1. merge settings from `env/onion.env.example`
2. make sure `/data` is persistent
3. if you deploy on Fly, use `scripts/onion/sync-onion-key-secrets.sh` after the hidden service is created

If you do not need an onion address, leave Tor off entirely.
