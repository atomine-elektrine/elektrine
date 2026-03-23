# Docker deploy

This keeps the main app and worker in a single Docker deployment:

- one `app` container
- one `worker` container
- optional `mail` container for SMTP, IMAP, and POP3 via `--profile email`
- optional `xmpp` container for MongooseIM via `--profile xmpp`
- one Postgres container
- optional Caddy edge via `--profile caddy`
- optional Bluesky PDS via `--profile bluesky`
- optional authoritative DNS via `--profile dns`
- optional onion service inside the `app` container via `--profile tor`

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
2. copy `env/core.env.example` to `/opt/elektrine/app/.env.production`
3. install Docker Engine with the Compose plugin
4. install `deploy/docker/elektrine-compose.service` as a systemd unit if you want boot-time restarts

Deploy manually:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault --profile caddy
```

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

Set `MONGOOSEIM_API_KEY` in `.env.production` to match the internal API auth key.
If it is unset, the deploy renderer falls back to `PHOENIX_API_KEY`.

Enable onion hosting in the Docker deploy by merging `env/onion.env.example`
into `.env.production` or by exporting the same variables before you deploy:

```bash
cat env/onion.env.example >> .env.production
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

GitHub Actions variables for `.github/workflows/docker-deploy.yml`:

- `ELEKTRINE_RELEASE_MODULES` optional, defaults to `all`
- `DOCKER_BUILD_PRIMARY_DOMAIN`
- `DOCKER_BUILD_EMAIL_DOMAIN`
- `DOCKER_BUILD_SUPPORTED_DOMAINS`
- `DOCKER_BUILD_PROFILE_BASE_DOMAINS`
