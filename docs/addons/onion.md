# Onion Hosting

Onion hosting is an add-on, not part of the default self-host profile.

Relevant files:

- `deploy/onion/torrc`
- `deploy/docker/start.sh`
- `deploy/docker/docker-entrypoint.sh`
- `scripts/onion/sync-onion-key-secrets.sh`

To enable it:

1. fill in the onion section already present in `.env.example` / `.env.production`
2. make sure `/data` is persistent
3. if you deploy on Fly, use `scripts/onion/sync-onion-key-secrets.sh` after the hidden service is created

Docker deploy notes:

- Docker keeps Tor off by default; set `ELEKTRINE_ENABLE_TOR=true` to enable it
- the `app` container runs Tor and the Phoenix release together
- `/data/tor/elektrine/hostname` inside the persistent volume holds the generated onion host
- if you replace the volume, `ONION_HOST`, `ONION_HS_SECRET_KEY_B64`, and `ONION_HS_PUBLIC_KEY_B64` can restore the hidden-service identity

If you do not need an onion address, leave Tor off entirely.
