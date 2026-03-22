# Docker deploy

This keeps the same Docker-based shape as the Fly setup:

- one `app` container
- one `worker` container
- one Postgres container
- optional Caddy edge via `--profile caddy`
- optional Bluesky PDS via `--profile bluesky`

Recommended host layout:

1. clone this repo to `/opt/elektrine/app`
2. copy `env/core.env.example` to `/opt/elektrine/app/.env.production`
3. install Docker Engine with the Compose plugin
4. install `deploy/docker/elektrine-compose.service` as a systemd unit if you want boot-time restarts

Deploy manually:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault --profile caddy
```

Enable email ports only when the `email` module is compiled in:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,email,vault --profile caddy
```

The deploy wrapper:

- renders `deploy/docker/generated.docker.yml`
- keeps `app` and `worker` in the stack
- runs database migrations through the app release
- suppresses POP3, IMAP, and SMTP port publishing when `email` is absent

Mail on the same server is supported too, but as a second Docker deployment.
Use this repo for Phoenix/mailbox/JMAP/WKD and run `elektrine-haraka` beside it
for SMTP edge and delivery. See `docs/self-hosting/mail.md`.

GitHub Actions deploy secrets for `.github/workflows/docker-deploy.yml`:

- `DEPLOY_HOST`
- `DEPLOY_USER`
- `DEPLOY_SSH_KEY`
- `DEPLOY_PATH` optional, defaults to `/opt/elektrine/app`
- `DEPLOY_PORT` optional, defaults to `22`
- `ELEKTRINE_RELEASE_MODULES` optional, defaults to `all`
- `DOCKER_PROFILES` optional, defaults to `caddy`
