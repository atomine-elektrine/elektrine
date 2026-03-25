# Docker deploy

This keeps the main app and worker in a single Docker deployment:

- one `app` container
- one `worker` container
- optional `mail` container when the `email` profile is enabled
- optional `xmpp` container for MongooseIM via `--profile xmpp`
- one Postgres container
- optional Caddy edge via `--profile caddy`
- optional Bluesky PDS via `--profile bluesky`
- optional authoritative DNS via `--profile dns`
- optional onion service inside the `app` container via `--profile tor`

The Caddy edge build includes the Cloudflare DNS provider module so it can issue
certificates for two configurable managed site blocks using the ACME DNS
challenge. See `docs/self-hosting/caddy.md`.

Deployment model:

| Concern | Uses | Examples |
| --- | --- | --- |
| product capabilities | `ELEKTRINE_RELEASE_MODULES` | `chat`, `social`, `email`, `vault`, `vpn` |
| long-lived infra/services | `DOCKER_PROFILES` | `email`, `dns`, `tor`, `xmpp`, `caddy`, `bluesky` |
| runtime behavior inside a container | env vars | `ONION_TLS_ENABLED=true` |

Rule of thumb:

- if it is a feature in the app, treat it as a module
- if it opens ports or runs a dedicated daemon, treat it as a profile-backed service

Recommended host layout:

1. clone this repo to `/opt/elektrine/app`
2. copy `.env.example` to `/opt/elektrine/app/.env.production`
3. install Docker Engine with the Compose plugin
4. install `deploy/docker/elektrine-compose.service` as a systemd unit if you want boot-time restarts

Recommended simplification:

- treat `.env.example` as the one main template
- edit only `.env.production` for your deployment
- use the smaller files under `env/` only as reference if you want examples for a specific add-on

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

For wildcard certificates, set these keys in `.env.production` before first deploy:

- `CLOUDFLARE_API_TOKEN` - token with DNS edit access for your managed zones
- `ACME_EMAIL` - ACME account email for Let's Encrypt / ZeroSSL
- `CADDY_MANAGED_SITE_1` - first explicit site list for wildcard + mail hostnames (quote the whole value)

Then point the domains in your managed site lists at your edge.

- Example: `example.com`, `*.example.com`, `mail.example.com`, `imap.example.com`, `pop.example.com`, `smtp.example.com`

Preview what a deploy will run:

```bash
scripts/deploy/explain_deploy.sh --modules all --profiles "caddy dns email tor xmpp"
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

Enable the separate MongooseIM XMPP service with:

```bash
scripts/deploy/docker_deploy.sh --modules all --profile xmpp
```

The MongooseIM profile uses Elektrine's existing internal auth endpoints at
`/_mongooseim/identity/v1/*` and renders a config file from:

- `deploy/mongooseim/mongooseim.toml.template`
- `scripts/deploy/render_mongooseim_config.sh`
- rendered output lives at `deploy/docker/generated.mongooseim.toml`

Set `MONGOOSEIM_API_KEY` in `.env.production` to match the internal API auth key.
If it is unset, the deploy renderer falls back to `PHOENIX_API_KEY`.

For PostgreSQL-backed XMPP storage, also set:

- `MONGOOSEIM_DB_NAME` (for example `mongooseim`)
- `MONGOOSEIM_DB_USER` (for example `mongooseim`)
- `MONGOOSEIM_DB_PASSWORD`

Create the matching Postgres role/database before first boot.

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
- builds a Cloudflare-enabled Caddy image when the `caddy` profile is enabled

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
- `MONGOOSEIM_API_KEY` required when using the `xmpp` profile
- `MAIL_TLS_CERT_PATH` / `MAIL_TLS_KEY_PATH` required for native IMAPS/POP3S on the `email` profile; plain IMAP/POP remain on `143/110`
- `MAIL_TLS_MOUNT_DIR` optional, defaults to `/opt/elektrine/certs`, and is bind-mounted into the mail container for native IMAPS/POP3S cert access
- secure mail ports map to non-privileged internal listeners (`993 -> 2993`, `995 -> 2995`)

GitHub Actions variables for `.github/workflows/docker-deploy.yml`:

- `ELEKTRINE_RELEASE_MODULES` optional, defaults to `all`
- `DOCKER_BUILD_PRIMARY_DOMAIN`
- `DOCKER_BUILD_EMAIL_DOMAIN`
- `DOCKER_BUILD_SUPPORTED_DOMAINS`
- `DOCKER_BUILD_PROFILE_BASE_DOMAINS`
