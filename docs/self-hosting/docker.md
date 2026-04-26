# Docker Deploy

The Docker deployment keeps the main app and background services in one Compose
stack.

`scripts/deploy/docker_deploy.sh` is the module-aware wrapper around that stack.
If you run it without explicit profiles, it defaults to `caddy`.

## Services

- `app`
- `worker`
- `postgres`
- optional `mail` service when the `email` profile is enabled
- optional `dns` service when the `dns` profile is enabled
- optional `turn` service when the `turn` profile is enabled
- optional `vpn` service when the `vpn` module is enabled
- optional `caddy` edge when the `caddy` profile is enabled
- optional `bluesky` PDS when the `bluesky` profile is enabled
- optional onion hosting inside the `app` container when the `tor` profile is enabled

See `docs/self-hosting/caddy.md` for Caddy details.

## Model

| Concern | Uses | Examples |
| --- | --- | --- |
| product capabilities | `ELEKTRINE_ENABLED_MODULES` | `chat`, `social`, `email`, `vault`, `vpn`, `dns` |
| long-lived infra/services | `DOCKER_PROFILES` | `email`, `dns`, `tor`, `turn`, `vpn`, `caddy`, `bluesky` |
| runtime behavior inside a container | env vars | `ONION_TLS_ENABLED=true` |

Rule of thumb:

- If it is a feature in the app, treat it as a module.
- If it opens ports or runs a dedicated daemon, treat it as a profile-backed service.

`vpn` is the one intentional hybrid here: the app module stays enabled in
Elektrine, and the Docker deploy adds the bundled `vpn` service so WireGuard
runs in the same stack.

## Host Layout

1. clone this repo to `/opt/elektrine/app`
2. copy `.env.example` or one of the smaller files under `env/` to `/opt/elektrine/app/.env.production`
3. install Docker Engine with the Compose plugin
4. install `deploy/docker/elektrine-compose.service` as a systemd unit if you want boot-time restarts

## Environment Files

For a first deploy, generate a minimal `.env.production` instead of starting from
the full kitchen-sink example:

```bash
scripts/deploy/generate_env.sh --domain example.com --email admin@example.com
scripts/deploy/doctor.sh
scripts/deploy/docker_deploy.sh --modules chat,social,vault --profile caddy
```

Use the smaller files under `env/` as reference for feature-specific overrides,
and keep `.env.production` limited to the values you actually need on that host.

Minimal first-run values are usually:

- `PRIMARY_DOMAIN`
- `DB_PASSWORD`
- `ELEKTRINE_MASTER_SECRET`
- `ACME_EMAIL` if you want automatic HTTPS via Caddy

`scripts/deploy/doctor.sh` checks these values before deploy and also validates
the common Caddy, wildcard TLS, Magpie/S3, Docker, and stale bind-mount failure
points.

By default, the DNS service derives:

- nameservers as `ns1.<PRIMARY_DOMAIN>` and `ns2.<PRIMARY_DOMAIN>`
- SOA contact as `admin.<PRIMARY_DOMAIN>`

Override those only if you want custom DNS branding via `DNS_NAMESERVERS` or `DNS_SOA_RNAME`.

## Storage

Local uploads without S3-compatible object storage:

- if `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_ENDPOINT`, and `S3_BUCKET_NAME` are unset, uploads stay on local disk
- Docker persists those files in the named `uploads` volume mounted at `/data/uploads`
- the container entrypoint links that volume into the release `priv/static/uploads` path so `/uploads/...` URLs keep working
- keep the `uploads` volume if you want avatars, attachments, and media to survive container replacement

To use S3-compatible object storage, set the `S3_*` variables in
`.env.production`. This can point at Magpie, MinIO, Garage, AWS S3, Cloudflare
R2, Backblaze B2, or another compatible service. If `S3_PUBLIC_URL` points at a
public CDN/object-storage URL, no extra Docker networking is needed.

Magpie is optional. If you run a private Magpie service in another Compose
project and expose public media through Elektrine's Caddy route, set
`S3_PUBLIC_URL` to `https://media.<PRIMARY_DOMAIN>` and
`CADDY_MEDIA_UPSTREAM=magpie:8090`. The deploy wrapper automatically attaches
app, worker, and Caddy to the configured shared network and renders a media
route.

With a Magpie service on `elektrine-magpie-shared` using the `magpie` network
alias:

```bash
docker network create elektrine-magpie-shared
cd /path/to/magpie
docker compose -f docker-compose.yml -f docker-compose.network.example.yml up -d --build

cd /path/to/elektrine
scripts/deploy/docker_deploy.sh \
	--modules chat,social,vault \
	--profile caddy
```

Then set the storage endpoint to the object-store service name in
`.env.production`:

```env
S3_ENDPOINT=magpie:8090
S3_BUCKET_NAME=app-uploads
S3_PUBLIC_URL=https://media.example.com
S3_SCHEME=http://
S3_PORT=8090
CADDY_MEDIA_HOST=media.example.com
CADDY_MEDIA_UPSTREAM=magpie:8090
MAGPIE_DOCKER_NETWORK=elektrine-magpie-shared
```

If the shared network has a different name, set the same
`MAGPIE_DOCKER_NETWORK` value for both Magpie and Elektrine before deploying.

## Deploy

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault --profile caddy --profile dns
```

When `vpn` is in the module list, `scripts/deploy/docker_deploy.sh` also enables the `vpn`
profile automatically so the bundled WireGuard container comes up with the stack.

To enable VPN explicitly:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault,vpn --profile caddy
```

## Fast Iteration

```bash
scripts/deploy/build_and_push_image.sh --tag dev-$(git rev-parse --short HEAD)
scripts/deploy/deploy_pushed_image.sh --host linuxuser@your-host --tag dev-$(git rev-parse --short HEAD)
```

That path builds the main Elektrine image locally, pushes it to GHCR, then has
the remote host pull and deploy it without rebuilding the app image there.

## HTTPS

For automatic HTTPS, set this key in `.env.production` before first deploy:

- `ACME_EMAIL` - ACME account email for Let's Encrypt / ZeroSSL

Then point your domains at the edge and let Caddy issue certificates for the
hostnames you actually use. If you only have an IP at first, bootstrap through
plain `http://<server-ip>` and add a domain later. For full LiveView/browser
interactivity over the raw IP, set `EXTRA_CHECK_ORIGINS=http://<server-ip>` in
`.env.production`.

If you need one wildcard cert for many username subdomains, switch to the
wildcard Caddy path with Elektrine DNS challenge or an external cert.

For external wildcard certs, set:

- `CADDY_MANAGED_SITE_1="example.com *.example.com"`
- `CADDY_TLS_MOUNT_DIR=/opt/elektrine/certs`

The deploy wrapper now infers the cert paths automatically as:

- `/opt/elektrine/certs/example.com.fullchain.pem`
- `/opt/elektrine/certs/example.com.key.pem`

Override `CADDY_MANAGED_SITE_1_CERT_PATH` and `CADDY_MANAGED_SITE_1_KEY_PATH`
only if your cert files live somewhere else or use a different filename.

If Elektrine hosts the authoritative DNS zone, the deploy wrapper issues and
installs the initial wildcard certificate automatically when Oban renewal is
enabled. The issuer uses the existing `CADDY_EDGE_API_KEY`
for the internal DNS-01 endpoint and saves that config into acme.sh. Pass
`--domain=example.com` to `scripts/acme/issue_elektrine_wildcard_cert.sh` only
when you need to run it manually with an override.

Enable Oban renewals with:

```env
ACME_WILDCARD_RENEWAL_ENABLED=true
ACME_HOME=/data/acme.sh
```

Oban runs `acme.sh --cron` daily. acme.sh only renews certificates near expiry
and runs the reload command saved during initial issuance.

Keep the host cert directory mounted read-only into the Caddy container.
`scripts/deploy/docker_deploy.sh`
auto-selects the wildcard Caddyfile for this combination, so `CADDY_CONFIG_PATH`
usually does not need to be set manually.

## Preview

```bash
scripts/deploy/explain_deploy.sh --modules all --profiles "caddy dns email tor"
```

Keep the repo owned by your deploy user and avoid running `git` operations as
`root` inside the checkout. Use `sudo` only for Docker commands. If a rendered
compose file becomes unwritable because of ownership drift, render to a
writable temporary path instead:

```bash
scripts/deploy/docker_deploy.sh --output /tmp/elektrine.generated.docker.yml --modules chat,social,vault --profile caddy
```

## Optional Services

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

Enable self-hosted STUN/TURN for chat calls with:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,vault --profile caddy --profile turn
```

This runs coturn on the host network and auto-wires the app's WebRTC ICE
configuration to your own instance domain. See `turn.md` if you need firewall,
NAT, or DNS details.

The Docker deploy keeps Tor off by default. Turn it on with the `tor` profile plus:

- `ONION_TLS_ENABLED=true`
- persistent `/data` storage so the hidden-service keys survive restarts

## What The Wrapper Does

- renders `deploy/docker/generated.docker.yml`
- keeps `app` and `worker` in the stack
- can start the dedicated `mail` service when the `email` profile is enabled
- runs database migrations through the app release
- provisions required Postgres extensions such as `vector`
- can start the dedicated `dns` service when the `dns` profile is enabled
- can expose the app as an onion service when the `tor` profile is enabled
- runs a stock Caddy edge when the `caddy` profile is enabled

## Postgres

- Docker deploy uses `pgvector/pgvector:pg16` for the `postgres` service
- fresh databases load `vector` from `deploy/docker/initdb/010-extensions.sql`
- every deploy also runs `CREATE EXTENSION IF NOT EXISTS` for extensions listed in `POSTGRES_EXTENSIONS`
- `POSTGRES_EXTENSIONS` defaults to `vector`; set a comma-separated list in `.env.production` if you need more

Mail on the same server is supported too, but as a second Docker deployment.
Use this repo for Phoenix, mailbox, JMAP, and WKD, and run
`elektrine-haraka` beside it for SMTP edge and delivery. See
`docs/self-hosting/mail.md`.

## GitHub Actions

Deploy secrets for `.github/workflows/docker-deploy.yml`:

- `DEPLOY_HOST`
- `DEPLOY_USER`
- `DEPLOY_SSH_KEY`
- `DEPLOY_PATH` optional, defaults to `/opt/elektrine/app`
- `DEPLOY_PORT` optional, defaults to `22`
- `DOCKER_PROFILES` optional, defaults to `caddy`; add `dns`, `email`, `tor`, `turn`, or `bluesky` only when this host should run those services
- `MAIL_TLS_CERT_PATH` / `MAIL_TLS_KEY_PATH` required for native IMAPS/POP3S on the `email` profile; plain IMAP/POP remain on `143/110`
- `MAIL_TLS_MOUNT_DIR` optional, defaults to `/opt/elektrine/certs`, and is bind-mounted into the mail container for native IMAPS/POP3S cert access
- secure mail ports map to non-privileged internal listeners (`993 -> 2993`, `995 -> 2995`)
- TURN profile exposes `3478` plus relay ports `49160-49200` on the host; adjust `TURN_PORT`, `TURN_MIN_PORT`, and `TURN_MAX_PORT` if needed

Variables for `.github/workflows/docker-deploy.yml`:

- `ELEKTRINE_ENABLED_MODULES` optional, defaults to `chat,social,vault`
- `ELEKTRINE_RELEASE_MODULES` optional advanced build override
- `DOCKER_BUILD_PRIMARY_DOMAIN`
- `DOCKER_BUILD_EMAIL_DOMAIN`
- `DOCKER_BUILD_SUPPORTED_DOMAINS`
- `DOCKER_BUILD_PROFILE_BASE_DOMAINS`
