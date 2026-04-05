# Onion Hosting

Onion hosting is an add-on, not part of the default self-host profile.

Relevant files:

- `deploy/onion/torrc`
- `deploy/docker/start.sh`
- `deploy/docker/docker-entrypoint.sh`
- `scripts/onion/sync-onion-key-secrets.sh`

To enable it:

1. Fill in the onion section already present in `.env.example` / `.env.production`.
2. Make sure `/data` is persistent.
3. If you need the hosted-secret sync helper, run `scripts/onion/sync-onion-key-secrets.sh` after the hidden service is created.

Docker deploy notes:

- Docker keeps Tor off by default; enable the `tor` profile in `scripts/deploy/docker_deploy.sh`.
- The `app` container runs Tor and the Phoenix release together.
- `/data/tor/elektrine/hostname` inside the persistent volume holds the generated onion host.
- If you replace the volume, `ONION_HOST`, `ONION_HS_SECRET_KEY_B64`, and `ONION_HS_PUBLIC_KEY_B64` can restore the hidden-service identity.

Example:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault --profile caddy --profile tor
```

If you do not need an onion address, leave Tor off entirely.
