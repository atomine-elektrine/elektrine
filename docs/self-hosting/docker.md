# Docker deploy

This keeps the main app and worker in a single Docker deployment:

- one `app` container
- one `worker` container
- optional `mail` container when the `email` profile is enabled
- one Postgres container
- optional Caddy edge via `--profile caddy`
- optional Bluesky PDS via `--profile bluesky`
- optional authoritative DNS via `--profile dns`
- optional onion service inside the `app` container via `--profile tor`

The optional Caddy edge handles HTTP bootstrap on the server IP, automatic HTTPS
for your configured domains, optional mounted wildcard certs from an external
ACME client, and on-demand TLS for custom domains. See `docs/self-hosting/caddy.md`.

Deployment model:

| Concern | Uses | Examples |
| --- | --- | --- |
| product capabilities | `ELEKTRINE_ENABLED_MODULES` | `chat`, `social`, `email`, `vault`, `vpn` |
| long-lived infra/services | `DOCKER_PROFILES` | `email`, `dns`, `tor`, `caddy`, `bluesky` |
| runtime behavior inside a container | env vars | `ONION_TLS_ENABLED=true` |

Rule of thumb:

- if it is a feature in the app, treat it as a module
- if it opens ports or runs a dedicated daemon, treat it as a profile-backed service

Recommended host layout:

1. clone this repo to `/opt/elektrine/app`
2. copy `.env.minimal.example` to `/opt/elektrine/app/.env.production`
3. install Docker Engine with the Compose plugin
4. install `deploy/docker/elektrine-compose.service` as a systemd unit if you want boot-time restarts

Recommended simplification:

- start from `.env.minimal.example` for the easiest first deploy
- use `.env.example` only when you want the larger advanced template
- use the smaller files under `env/` as reference for feature-specific overrides

Minimal first-run values are usually just:

- `PRIMARY_DOMAIN`
- `DB_PASSWORD`
- `ELEKTRINE_MASTER_SECRET`
- `ACME_EMAIL` if you want automatic HTTPS via Caddy

By default, the DNS service derives:

- nameservers as `ns1.<PRIMARY_DOMAIN>` and `ns2.<PRIMARY_DOMAIN>`
- SOA contact as `hostmaster.<PRIMARY_DOMAIN>`

Override those only if you want custom DNS branding via `DNS_NAMESERVERS` or `DNS_SOA_RNAME`.

Local uploads without R2:

- if `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, and `R2_BUCKET_NAME` are unset, uploads stay on local disk
- Docker persists those files in the named `uploads` volume mounted at `/data/uploads`
- the container entrypoint links that volume into the release `priv/static/uploads` path so `/uploads/...` URLs keep working
- keep the `uploads` volume if you want avatars, attachments, and media to survive container replacement

Deploy manually:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault,vpn --profile caddy --profile dns
```

Fast path for local iteration:

```bash
scripts/deploy/build_and_push_image.sh --tag dev-$(git rev-parse --short HEAD)
scripts/deploy/deploy_pushed_image.sh --host linuxuser@your-host --tag dev-$(git rev-parse --short HEAD)
```

That path builds the main Elektrine image locally, pushes it to GHCR, then tells the
remote host to pull and deploy it without rebuilding the app image there.

For automatic HTTPS, set this key in `.env.production` before first deploy:

- `ACME_EMAIL` - ACME account email for Let's Encrypt / ZeroSSL

Then point your domains at the edge and let Caddy issue certificates for the
hostnames you actually use. If you only have an IP at first, bootstrap through
plain `http://<server-ip>` and add a domain later.

If you need one wildcard cert for many username subdomains, switch to the
alternate Caddyfile with:

- `CADDY_CONFIG_PATH=../caddy/Caddyfile.external-certs`
- `CADDY_TLS_MOUNT_DIR=/opt/elektrine/certs`
- `CADDY_MANAGED_SITE_1_CERT_PATH=/opt/elektrine/certs/example.com.fullchain.pem`
- `CADDY_MANAGED_SITE_1_KEY_PATH=/opt/elektrine/certs/example.com.key.pem`

Then renew that wildcard certificate outside Docker and keep the host cert
directory mounted read-only into the Caddy container.

Preview what a deploy will run:

```bash
scripts/deploy/explain_deploy.sh --modules all --profiles "caddy dns email tor"
```

Keep the repo owned by your deploy user and avoid running `git` operations as `root` inside the checkout. Use `sudo` only for Docker commands. If a generated compose file ever becomes unwritable because of ownership drift, render to a writable temporary path instead of the tracked repo file:

```bash
scripts/deploy/docker_deploy.sh --output /tmp/elektrine.generated.docker.yml --modules chat,social,vault --profile caddy
```

Enable the separate mail protocol service with:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,email,vault --profile caddy --profile email
```

Enable the separate authoritative DNS service with:

```bash
scripts/deploy/docker_deploy.sh --modules all --profile dns
```

Enable onion hosting in the Docker deploy by setting the onion variables already
present in `.env.example`, then deploy with:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault --profile caddy --profile tor
```

The Docker deploy keeps Tor off by default. Turn it on with the `tor` profile plus:

- `ONION_TLS_ENABLED=true`
- persistent `/data` storage so the hidden-service keys survive restarts

The deploy wrapper:

- renders `deploy/docker/generated.docker.yml`
- keeps `app` and `worker` in the stack
- can start the dedicated `mail` service when the `email` profile is enabled
- runs database migrations through the app release
- provisions required Postgres extensions such as `vector`
- can start the dedicated `dns` service when the `dns` profile is enabled
- can expose the app as an onion service when the `tor` profile is enabled
- runs a stock Caddy edge when the `caddy` profile is enabled

Postgres notes:

- Docker deploy uses `pgvector/pgvector:pg16` for the `postgres` service
- fresh databases load `vector` from `deploy/docker/initdb/010-extensions.sql`
- every deploy also runs `CREATE EXTENSION IF NOT EXISTS` for extensions listed in `POSTGRES_EXTENSIONS`
- `POSTGRES_EXTENSIONS` defaults to `vector`; set a comma-separated list in `.env.production` if you need more

Mail on the same server is supported too, but as a second Docker deployment.
Use this repo for Phoenix/mailbox/JMAP/WKD and run `elektrine-haraka` beside it
for SMTP edge and delivery. See `docs/self-hosting/mail.md`.

GitHub Actions deploy secrets for `.github/workflows/docker-deploy.yml`:

- `DEPLOY_HOST`
- `DEPLOY_USER`
- `DEPLOY_SSH_KEY`
- `DEPLOY_PATH` optional, defaults to `/opt/elektrine/app`
- `DEPLOY_PORT` optional, defaults to `22`
- `DOCKER_PROFILES` optional, defaults to `caddy`
- `MAIL_TLS_CERT_PATH` / `MAIL_TLS_KEY_PATH` required for native IMAPS/POP3S on the `email` profile; plain IMAP/POP remain on `143/110`
- `MAIL_TLS_MOUNT_DIR` optional, defaults to `/opt/elektrine/certs`, and is bind-mounted into the mail container for native IMAPS/POP3S cert access
- secure mail ports map to non-privileged internal listeners (`993 -> 2993`, `995 -> 2995`)

GitHub Actions variables for `.github/workflows/docker-deploy.yml`:

- `ELEKTRINE_ENABLED_MODULES` optional, defaults to `all`
- `ELEKTRINE_RELEASE_MODULES` optional advanced build override
- `DOCKER_BUILD_PRIMARY_DOMAIN`
- `DOCKER_BUILD_EMAIL_DOMAIN`
- `DOCKER_BUILD_SUPPORTED_DOMAINS`
- `DOCKER_BUILD_PROFILE_BASE_DOMAINS`
