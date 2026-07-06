# Docker Deploy

The Docker deployment keeps the main app and background services in one Compose
stack.

`scripts/deploy/self_host.sh` is the recommended entrypoint for self-hosts.
`scripts/deploy/docker_deploy.sh` remains the lower-level module-aware wrapper;
when run directly without explicit modules or profiles, it keeps the legacy
all-modules/all-profiles behavior.

## Services

- `app`
- `worker`
- `postgres`
- optional `mail` protocol container when the `email` profile is enabled
- optional `dns` service when the `dns` profile is enabled
- optional `turn` service when the `turn` profile is enabled
- optional `vpn` service when the `vpn` module is enabled
- optional `caddy` edge when the `caddy` profile is enabled
- optional `bluesky` PDS when the `bluesky` profile is enabled
- optional onion hosting inside the `app` container when the `tor` profile is enabled

See `docs/self-hosting/caddy.md` for Caddy details.

The Docker `email` profile starts Elektrine's mail protocol container. It is not
the Haraka SMTP edge; use `docs/self-hosting/mail.md` before exposing production
mail.

## Model

| Concern | Uses | Examples |
| --- | --- | --- |
| product capabilities | `ELEKTRINE_ENABLED_MODULES` | `chat`, `social`, `email`, `nerve`, `vpn`, `dns`, `atomine` |
| long-lived infra/services | `DOCKER_PROFILES` | `email`, `dns`, `tor`, `turn`, `vpn`, `caddy`, `bluesky` |
| runtime behavior inside a container | env vars | `ONION_TLS_ENABLED=true` |

Rule of thumb:

- If it is a feature in the app, treat it as a module.
- If it opens ports or runs a dedicated daemon, treat it as a profile-backed service.

`vpn` is the one intentional hybrid here: the app module stays enabled in
Elektrine, and the Docker deploy adds the bundled `vpn` service so WireGuard
runs in the same stack.

`atomine` powers Proofs and account trust/credit features. It runs inside the
main app release and does not have a separate Docker profile.

## Host Layout

1. Clone this repo to `/opt/elektrine/app`.
2. Copy `.env.example` or one of the smaller files under `env/` to `/opt/elektrine/app/.env.production`.
3. Install Docker Engine with the Compose plugin.
4. Install `deploy/docker/elektrine-compose.service` as a systemd unit if you want boot-time restarts.

Source deploy templates live under `deploy/docker/` and `deploy/caddy/`.
Rendered Compose and Caddy files are disposable and live under
`deploy/generated/`. Host-owned persistent data should live outside the repo,
usually under `/opt/elektrine/data` or Docker named volumes, so deploy worktrees
and generated files can be removed without touching user data.

Do not point generated Compose or Caddy output back into `deploy/docker/` or
`deploy/caddy/`. Those directories are source templates. If an older deploy left
files such as `deploy/docker/compose.override.yml`,
`deploy/docker/generated.docker.yml`, or `deploy/caddy/generated.Caddyfile`,
remove them after confirming they are not hand-maintained. `doctor.sh` now flags
those legacy locations because root-owned generated files there commonly cause
permission failures on the next deploy.

## Environment Files

For a first deploy, use the self-host wrapper instead of starting from the full
root example:

```bash
scripts/deploy/self_host.sh init --domain example.com --email admin@example.com
scripts/deploy/self_host.sh doctor
scripts/deploy/self_host.sh up
```

The wrapper creates a small `.env.production` for the normal web stack:
`chat,social,nerve,atomine` plus the `caddy` Docker profile. Use presets for
feature-specific overrides and keep `.env.production` limited to values this
host actually uses.

Minimal first-run values are usually:

- `PRIMARY_DOMAIN`
- `DB_PASSWORD`
- `ELEKTRINE_MASTER_SECRET`
- `ACME_EMAIL` if you want automatic HTTPS via Caddy

## Presets

List available presets:

```bash
scripts/deploy/self_host.sh presets
```

Enable only the services you need:

```bash
scripts/deploy/self_host.sh enable mail
scripts/deploy/self_host.sh enable dns
scripts/deploy/self_host.sh enable wildcard-tls
scripts/deploy/self_host.sh enable s3
scripts/deploy/self_host.sh enable vpn
scripts/deploy/self_host.sh enable tor
scripts/deploy/self_host.sh enable turn
scripts/deploy/self_host.sh enable bluesky
```

Preset snippets live under `env/presets/`. Enabling a preset updates
`ELEKTRINE_ENABLED_MODULES` and `DOCKER_PROFILES` when needed, appends a marked
env block, and generates secrets for presets that need local shared secrets.
Review the appended block before deploying; some presets intentionally leave
provider credentials or public hostnames commented.

`scripts/deploy/doctor.sh` checks these values before deploy and also validates
the common Caddy, wildcard TLS, Magpie/S3, Docker, and stale bind-mount failure
points.

The doctor also checks the self-host file layout:

- generated Compose/Caddy paths are under `deploy/generated/`
- source template directories do not contain legacy generated files
- generated files are writable by the deploy user or installable with sudo
- no stale `.deploy-worktree.*` directories are left behind
- `COMPOSE_PROJECT_NAME` is set for stable container, network, and volume names

By default, the DNS service derives:

- nameservers as `ns1.<PRIMARY_DOMAIN>` and `ns2.<PRIMARY_DOMAIN>`
- assigned customer-zone nameservers as short pairs under `ns1.<PRIMARY_DOMAIN>` and
  `ns2.<PRIMARY_DOMAIN>`, such as `rose.ns1.<PRIMARY_DOMAIN>` and
  `mint.ns2.<PRIMARY_DOMAIN>`
- SOA contact as `admin.<PRIMARY_DOMAIN>`

Override those only if you want custom DNS branding via `DNS_NAMESERVERS` or `DNS_SOA_RNAME`.
If `<PRIMARY_DOMAIN>` is hosted outside Elektrine DNS, add wildcard A/AAAA records for
`*.ns1.<PRIMARY_DOMAIN>` and `*.ns2.<PRIMARY_DOMAIN>` that point at the same DNS servers
as `ns1.<PRIMARY_DOMAIN>` and `ns2.<PRIMARY_DOMAIN>`.

## Storage

Local uploads without S3-compatible object storage:

- if `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_ENDPOINT`, and `S3_BUCKET_NAME` are unset, uploads stay on local disk
- Docker persists those files in the named `uploads` volume mounted at `/data/uploads`
- the container entrypoint links that volume into the release `priv/static/uploads` path so `/uploads/...` URLs keep working
- keep the `uploads` volume if you want avatars, attachments, and media to survive container replacement

To use S3-compatible object storage, set the `S3_*` variables in
`.env.production`. This can point at Magpie, MinIO, Garage, AWS S3,
Backblaze B2, or another compatible service. If `S3_PUBLIC_URL` points at a
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
docker compose -f docker-compose.yml -f docker-compose.network.yml up -d --build

cd /path/to/elektrine
scripts/deploy/docker_deploy.sh \
	--modules chat,social,nerve,atomine \
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
scripts/deploy/docker_deploy.sh
```

The public self-host path is:

```bash
scripts/deploy/self_host.sh up
```

Use `scripts/deploy/docker_deploy.sh` directly when you need low-level Compose
flags or are maintaining an existing raw-script deployment.

When `vpn` is in the module list, `scripts/deploy/docker_deploy.sh` also enables the `vpn`
profile automatically so the bundled WireGuard container comes up with the stack.

To enable VPN explicitly:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,nerve,vpn,atomine --profile caddy
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

## Client IPs

If you must keep Caddy in Docker bridge networking, first make sure Docker is
not hiding client source addresses before packets reach the Caddy container. On
a normal Linux Docker Engine host, use kernel port forwarding instead of the
Docker userland proxy:

```json
{
  "userland-proxy": false
}
```

The deploy wrapper can do this automatically, including a backup, validation,
and Docker restart:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,nerve,atomine --profile caddy --configure-docker-source-ips
```

You can also keep it enabled in `.env.production`:

```env
ELEKTRINE_AUTO_CONFIGURE_DOCKER_SOURCE_IPS=true
```

Do not use this path on Docker Desktop or rootless Docker expecting real public
source IPs; those port-forwarding layers commonly replace the client IP with a
local gateway address. If you set `ELEKTRINE_RESTART_DOCKER_FOR_SOURCE_IPS=false`,
restart Docker manually before redeploying.

If Caddy still only sees Docker gateway addresses such as `172.30.0.1`, the real
client IP is not present in the request path. Use PROXY protocol from a trusted
load balancer or a trusted CDN/load-balancer `X-Forwarded-For` path instead.
Only set `CADDY_TRUSTED_PROXY_CIDRS` to networks you trust to strip spoofed
forwarded headers before adding their own.

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
scripts/deploy/explain_deploy.sh --modules all --profiles "caddy dns email tor turn bluesky vpn"
```

Keep the repo owned by your deploy user and avoid running `git` operations as
`root` inside the checkout. Use `sudo` only for Docker commands. If a rendered
compose file becomes unwritable because of ownership drift, render to a
writable temporary path instead. The default generated path is
`deploy/generated/generated.docker.yml`.

```bash
scripts/deploy/docker_deploy.sh --output /tmp/elektrine.generated.docker.yml
```

## Optional Services

The mail preset enables Elektrine's separate mail protocol container. With the
lower-level wrapper, enable it with:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,email,nerve,atomine --profile caddy --profile email
```

The DNS preset enables the separate authoritative DNS service. With the
lower-level wrapper, enable it with:

```bash
scripts/deploy/docker_deploy.sh --modules all --profile dns
```

The Tor preset enables onion hosting. With the lower-level wrapper, set the
onion variables already present in `.env.example`, then deploy with:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,nerve,atomine --profile caddy --profile tor
```

The TURN preset enables self-hosted STUN/TURN for chat calls. With the
lower-level wrapper, enable it with:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,nerve,atomine --profile caddy --profile turn
```

This runs coturn on the host network and auto-wires the app's WebRTC ICE
configuration to your own instance domain. See `turn.md` if you need firewall,
NAT, or DNS details.

Tor starts when the `tor` profile is active. For custom profile subsets, include
`tor` plus:

- `ONION_TLS_ENABLED=true`
- persistent `/data` storage so the hidden-service keys survive restarts

## What The Wrapper Does

- renders `deploy/generated/generated.docker.yml`
- renders `deploy/generated/generated.Caddyfile` when the Caddy profile is active
- keeps `app` and `worker` in the stack
- can start the dedicated `mail` service when the `email` profile is enabled
- runs database migrations through the app release
- provisions required Postgres extensions such as `vector`
- can start the dedicated `dns` service when the `dns` profile is enabled
- can expose the app as an onion service when the `tor` profile is enabled
- runs a stock Caddy edge when the `caddy` profile is enabled

## Postgres

- Docker deploy uses `pgvector/pgvector:pg16` for the `postgres` service
- The Postgres container gets `POSTGRES_SHM_SIZE`, defaulting to `512m`, to avoid Docker's small default `/dev/shm` causing `ERROR 53100 (disk_full) could not resize shared memory segment` during larger/parallel queries
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
- `MAIL_TLS_CERT_PATH` / `MAIL_TLS_KEY_PATH` required for native IMAPS/POP3S on the `email` profile; plain IMAP/POP remain on `143/110`
- `MAIL_TLS_MOUNT_DIR` optional, defaults to `/opt/elektrine/certs`, and is bind-mounted into the mail container for native IMAPS/POP3S cert access
- secure mail ports map to non-privileged internal listeners (`993 -> 2993`, `995 -> 2995`)
- TURN profile exposes `3478` plus relay ports `49160-49200` on the host; adjust `TURN_PORT`, `TURN_MIN_PORT`, and `TURN_MAX_PORT` if needed

Variables for `.github/workflows/docker-deploy.yml`:

- The workflow pins `ELEKTRINE_ENABLED_MODULES=all`, `ELEKTRINE_RELEASE_MODULES=all`, and `DOCKER_PROFILES="caddy dns email tor turn bluesky vpn"` for full-stack CI/CD deploys. The recommended self-host wrapper starts smaller.
- `DOCKER_BUILD_PRIMARY_DOMAIN`
- `DOCKER_BUILD_EMAIL_DOMAIN`
- `DOCKER_BUILD_SUPPORTED_DOMAINS`
- `DOCKER_BUILD_PROFILE_BASE_DOMAINS`
