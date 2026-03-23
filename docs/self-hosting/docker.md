# Docker deploy

This keeps the main app and worker in a single Docker deployment:

- one `app` container
- one `worker` container
- one Postgres container
- optional Caddy edge via `--profile caddy`
- optional Bluesky PDS via `--profile bluesky`
- optional authoritative DNS via `--profile dns`
- optional onion service inside the `app` container when `ELEKTRINE_ENABLE_TOR=true`

Recommended host layout:

1. clone this repo to `/opt/elektrine/app`
2. copy `env/core.env.example` to `/opt/elektrine/app/.env.production`
3. install Docker Engine with the Compose plugin
4. install `deploy/docker/elektrine-compose.service` as a systemd unit if you want boot-time restarts

Deploy manually:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault --profile caddy
```

Keep the repo owned by your deploy user and avoid running `git` operations as `root` inside the checkout. Use `sudo` only for Docker commands. If a generated compose file ever becomes unwritable because of ownership drift, render to a writable temporary path instead of the tracked repo file:

```bash
scripts/deploy/docker_deploy.sh --output /tmp/elektrine.generated.docker.yml --modules chat,social,vault --profile caddy
```

Enable email ports only when the `email` module is compiled in:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,email,vault --profile caddy
```

Enable the separate authoritative DNS service with:

```bash
scripts/deploy/docker_deploy.sh --modules all --profile dns
```

Enable onion hosting in the Docker deploy by merging `env/onion.env.example`
into `.env.production` or by exporting the same variables before you deploy:

```bash
cat env/onion.env.example >> .env.production
scripts/deploy/docker_deploy.sh --modules chat,social,vault --profile caddy
```

The Docker deploy keeps Tor off by default. Turn it on with:

- `ELEKTRINE_ENABLE_TOR=true`
- `ONION_TLS_ENABLED=true`
- persistent `/data` storage so the hidden-service keys survive restarts

The deploy wrapper:

- renders `deploy/docker/generated.docker.yml`
- keeps `app` and `worker` in the stack
- runs database migrations through the app release
- provisions required Postgres extensions such as `vector`
- suppresses POP3, IMAP, and SMTP port publishing when `email` is absent
- can start the dedicated `dns` service when the `dns` profile is enabled
- can expose the app as an onion service when Tor is enabled in `.env.production`

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

GitHub Actions variables for `.github/workflows/docker-deploy.yml`:

- `ELEKTRINE_RELEASE_MODULES` optional, defaults to `all`
- `DOCKER_BUILD_PRIMARY_DOMAIN`
- `DOCKER_BUILD_EMAIL_DOMAIN`
- `DOCKER_BUILD_SUPPORTED_DOMAINS`
- `DOCKER_BUILD_PROFILE_BASE_DOMAINS`
