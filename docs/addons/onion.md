# Onion Hosting

Onion hosting is included in the full Docker default profile set and can also be
enabled explicitly with the `tor` profile in smaller custom stacks.

Relevant files:

- `deploy/onion/torrc`
- `deploy/docker/start.sh`
- `deploy/docker/docker-entrypoint.sh`
- `scripts/onion/sync-onion-key-secrets.sh`

Default onion exposure:

- web: `80 -> $PORT` (defaults to `8080`), `443 -> $ONION_TLS_PORT` when `ONION_TLS_ENABLED=true` (defaults to `8443`)
- IMAP: `143 -> 2143`, `993 -> 2993`
- POP3: `110 -> 2110`, `995 -> 2995`

Docker renders the Tor config at container startup so onion targets follow the
actual runtime ports. Override `ONION_HTTP_TARGET_PORT` or
`ONION_HTTPS_TARGET_PORT` only if Tor should forward to something other than the
Elektrine app listener.

To enable it:

1. Fill in the onion section already present in `.env.example` / `.env.production`.
2. Make sure `/data` is persistent.
3. If you need the hosted-secret sync helper, run `scripts/onion/sync-onion-key-secrets.sh` after the hidden service is created.

Docker deploy notes:

- Docker enables Tor when the default full profile set is used; if you override profiles, include `tor`.
- The `app` container runs Tor and the Phoenix release together.
- `/data/tor/elektrine/hostname` inside the persistent volume holds the generated onion host.
- If you replace the volume, `ONION_HOST`, `ONION_HS_SECRET_KEY_B64`, and `ONION_HS_PUBLIC_KEY_B64` can restore the hidden-service identity.

Example:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,nerve,atomine --profile caddy --profile tor
```

If you do not need an onion address, override `DOCKER_PROFILES` without `tor`.
