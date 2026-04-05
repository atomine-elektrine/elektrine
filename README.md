# Elektrine

Elektrine is an Elixir umbrella app. Shared runtime and persistence live in
`apps/elektrine`, the Phoenix host app lives in `apps/elektrine_web`, and the
product areas are split into their own umbrella apps.

## Layout

- `apps/`: umbrella apps
- `clients/`: client-side artifacts that are not shipped with the server release
- `config/`: shared compile-time and runtime config
- `deploy/`: Docker, Caddy, onion, and VPN deploy assets
- `docs/`: architecture, protocol, and self-hosting docs
- `env/`: example environment files
- `release_builder/`: module-aware release build project
- `scripts/`: release, deploy, and ops helpers

## Main apps

- `apps/elektrine`: shared domain logic, `Repo`, supervisors, accounts, uploads, notifications, calendar, and module selection
- `apps/elektrine_web`: endpoint, router, plugs, layouts, shared components, and the host shell
- `apps/elektrine_chat`: chat facade plus chat LiveView and API surface
- `apps/elektrine_social`: timeline, communities, federation, and social web surface
- `apps/elektrine_email`: mailbox, contacts, mail protocols, JMAP, WKD, and email web surface
- `apps/elektrine_vpn`: WireGuard management and VPN UI/API
- `apps/elektrine_password_manager`: password vault domain and extracted vault routes
- `apps/elektrine_dns`: managed DNS runtime, DNS API, and DNS LiveView surface

Requests enter through `ElektrineWeb.Router`, pass through shared plugs and
module guards, and then land in the controller or LiveView mounted for the
selected feature set. Persistence stays centralized in `Elektrine.Repo`.

## Identity Provider

Elektrine exposes an OpenID Connect-compatible identity provider on top of the
existing OAuth tables:

- discovery: `/.well-known/openid-configuration`
- browser consent: `/oauth/authorize`
- public keys: `/oauth/jwks`
- token exchange: `/oauth/token`
- user info: `/oauth/userinfo`
- app management UI: `/account/developer/oidc/clients`
- grant review UI: `/account/developer/oidc/grants`
- dynamic registration: `POST /oauth/register` while signed in

Register OAuth apps with `openid`, `profile`, and `email` scopes to use this
flow. The current implementation supports the authorization code flow and
issues `RS256` `id_token`s for confidential clients.

## Module Selection

Normal deployments use one public module switch:

- `ELEKTRINE_ENABLED_MODULES` controls which product modules are turned on
- release builds default to that same module list
- `ELEKTRINE_RELEASE_MODULES` still exists as an advanced override when you need
  to compile more modules than you expose at runtime

Supported module ids are `chat`, `social`, `email`, `vault`, `vpn`, and `dns`.
`password-manager` and `password_manager` are accepted aliases for `vault` in
the deploy scripts.

In normal use, set `ELEKTRINE_ENABLED_MODULES` and leave
`ELEKTRINE_RELEASE_MODULES` unset.

## Local Development

From the repo root:

```bash
mix setup
```

Start the web app:

```bash
cd apps/elektrine
mix phx.server
```

Useful commands:

```bash
mix compile
mix test
mix test apps/elektrine/test
mix test apps/elektrine_web/test
mix test apps/elektrine_email/test
mix test apps/elektrine_social/test
mix test apps/elektrine_vpn/test
mix test apps/elektrine_password_manager/test
mix test apps/elektrine_dns/test
```

Frontend assets live under `apps/elektrine/assets`.

## Build And Deploy

The supported path for hosted or subset installs is the release builder:

```bash
scripts/release/deploy_release.sh --modules email,vpn
```

This builds assets, selects the requested feature apps, and writes the release
to `_deploy_release/`. `deploy/docker/Dockerfile` uses the same path.

For Docker deployments, use the wrapper instead of invoking `docker compose`
against `deploy/docker/compose.full.yml` directly:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social --profile caddy
```

The wrapper renders a module-aware Compose file first, sets
`ELEKTRINE_ENABLED_MODULES`, derives release modules from it by default, sets
mail runtime flags, and removes POP3, IMAP, and SMTP port bindings when
`email` is not selected.

When `vpn` is selected, the Docker deploy also enables the bundled `vpn`
service automatically. That service runs the Docker-managed WireGuard node,
creates or restores its private key, derives the public key, and reconciles
peer state in-app.

## Self-hosting

The self-hosting docs are split by profile:

- `core`: Phoenix app and Postgres only
- `mail`: Haraka deployment layered on top of the `email` module
- `dns`: optional authoritative DNS service enabled through the Docker `dns` profile
- `vpn`: optional Docker-managed WireGuard on the same stack, with optional fleet mode
- `addons`: Caddy edge, Bluesky PDS, onion hosting, and client artifacts

Start with:

- `docs/self-hosting/README.md`
- `docs/self-hosting/docker.md`
- `docs/self-hosting/core.md`
- `docs/self-hosting/mail.md`
- `docs/architecture/dns-module.md`
- `docs/self-hosting/vpn.md`
- `docs/addons/onion.md`
- `docs/clients/password-manager-extension.md`

## Email Deployment

The `email` module in this repo is only part of the mail stack. Mail transport
lives in
[`atomine-elektrine/elektrine-haraka`](https://github.com/atomine-elektrine/elektrine-haraka),
and a production email deployment needs both repositories.

This repo owns the mailbox product: UI, aliases, contacts, JMAP, WKD, message
storage, and the Phoenix endpoints that receive mail webhooks.
`elektrine-haraka` owns the SMTP edge and delivery pipeline: inbound SMTP,
authenticated submission, outbound send API, Redis-backed queueing, and the
worker that posts cleaned inbound message data back into Phoenix.

If you enable the `email` module, deploy `elektrine-haraka` alongside it and
configure `HARAKA_BASE_URL`, an outbound Haraka API key, and an inbound webhook
key. Both deployments can live on the same bare-metal server as separate Docker
projects.

## Bluesky Integration

Bluesky support is part of the social stack.

- Outbound sync mirrors local public posts to Bluesky and keeps linked post
  state in sync for create, edit, delete, like, repost, and follow events.
  These jobs run through Oban, so failed outbound calls do not block the local
  action.
- Inbound sync, when `BLUESKY_INBOUND_ENABLED=true`, polls notifications for
  connected accounts and turns replies, mentions, quotes, likes, and reposts on
  mirrored posts into local notifications. It can also store timeline items
  locally.
- Managed mode, when `BLUESKY_MANAGED_ENABLED=true`, talks to a
  Bluesky-compatible PDS admin API to create per-user accounts, issue app
  passwords, and store the linkage. Without managed mode, users connect their
  own Bluesky identifier and app password.

## License

This repository is AGPL-3.0-only unless a file says otherwise.
