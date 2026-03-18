# Elektrine

Elektrine is an Elixir umbrella application. The shared platform core lives in
`apps/elektrine`, the Phoenix shell lives in `apps/elektrine_web`, and the
major product areas ship as separate umbrella apps.

## Repository layout

- `apps/` umbrella apps
- `clients/` optional client artifacts that are not part of the server deploy
- `config/` shared compile-time and runtime config
- `deploy/` Docker, Fly, edge, onion, and installer assets
- `docs/` protocol, platform, and deployment notes
- `env/` profile-based environment examples
- `release_builder/` subset release tooling
- `scripts/` release, deploy, and ops helpers

Main apps:

- `apps/elektrine`: shared domain logic, `Repo`, supervisors, accounts,
  uploads, notifications, ActivityPub internals, calendar, and the platform
  module registry
- `apps/elektrine_web`: endpoint, router, plugs, shared layouts/components,
  admin shell, and the auth/navigation layer
- `apps/elektrine_chat`: chat UI and API
- `apps/elektrine_social`: timeline, communities, federation, and the social
  web surface
- `apps/elektrine_email`: mailbox, contacts, mail protocols, JMAP, WKD, and
  the public email surface
- `apps/elektrine_vpn`: WireGuard management and VPN UI/API
- `apps/elektrine_password_manager`: password vault

Requests enter through `ElektrineWeb.Router`, pass through the shared plugs and
module guards, and then land in the controller or LiveView owned by the
relevant app. Persistence stays centralized in `Elektrine.Repo`.

## Release modules and runtime modules

Elektrine separates build-time selection from runtime exposure:

- `ELEKTRINE_RELEASE_MODULES` controls which apps and module-specific code are
  compiled into a release
- `ELEKTRINE_ENABLED_MODULES` controls which compiled modules are exposed in the
  UI, routes, and optional runtime children

Use the first to build a smaller release. Use the second to hide or disable a
compiled module at runtime.

## Local development

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
```

Frontend assets live under `apps/elektrine/assets`.

## Building and deploying

The repo still supports a full umbrella release, but the supported path for
hosted or subset installs is the subset builder:

```bash
scripts/release/deploy_release.sh --modules email,vpn
```

This builds assets, selects the requested module apps, and writes the release
to `_deploy_release/`. `deploy/docker/Dockerfile` uses the same path.

For Fly deployments, use the wrapper instead of deploying the root template
directly:

```bash
scripts/deploy/fly_deploy.sh --modules chat,social --app your-app
```

The wrapper renders a module-aware Fly config first. If `email` is not enabled,
it strips the POP3, IMAP, and SMTP service blocks so a non-mail deployment does
not publish mail ports.

## Self-hosting profiles

The self-hosting docs are split by profile:

- `core`: Phoenix app and Postgres only
- `mail`: Haraka deployment layered on top of the `email` module
- `vpn`: `vpn` module plus fleet registration key
- `addons`: Caddy edge, Bluesky PDS, onion hosting, and client artifacts

Start with:

- `docs/self-hosting/README.md`
- `docs/self-hosting/core.md`
- `docs/self-hosting/mail.md`
- `docs/self-hosting/vpn.md`
- `docs/addons/onion.md`
- `docs/clients/password-manager-extension.md`

## Email deployment

The `email` module in this repo is only part of the mail stack. Mail transport
lives in
[`atomine-elektrine/elektrine-haraka`](https://github.com/atomine-elektrine/elektrine-haraka),
and a production email deployment needs both repositories.

This repo owns the mailbox product: UI, aliases, contacts, JMAP, WKD, message
storage, and the Phoenix endpoints that receive mail webhooks.
`elektrine-haraka` owns the SMTP edge and delivery pipeline: inbound SMTP,
authenticated submission, outbound send API, Redis-backed mail queueing, and
the worker that posts cleaned inbound message data back into Phoenix.

If you enable the `email` module, deploy `elektrine-haraka` alongside it and
configure `HARAKA_BASE_URL`, an outbound Haraka API key, and an inbound webhook
key.

## Bluesky integration

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

## Production configuration

Base production settings still include `DATABASE_URL`, `SECRET_KEY_BASE`,
`PHX_HOST`, and the relevant domain configuration.

Module-specific validation also fails fast at boot:

- `email` needs `PRIMARY_DOMAIN` or `EMAIL_DOMAIN`
- `email` currently expects `EMAIL_SERVICE=haraka`
- Haraka-backed email needs `HARAKA_BASE_URL`
- Haraka-backed email needs one outbound API key:
  `HARAKA_HTTP_API_KEY`, `HARAKA_OUTBOUND_API_KEY`, or `HARAKA_API_KEY`
- Haraka-backed email needs one inbound webhook key:
  `PHOENIX_API_KEY`, `HARAKA_INBOUND_API_KEY`, or `HARAKA_API_KEY`
- `vpn` needs `VPN_FLEET_REGISTRATION_KEY`

Bluesky is optional. Main settings:

- `BLUESKY_ENABLED` for outbound mirroring
- `BLUESKY_INBOUND_ENABLED` for notification and feed polling
- `BLUESKY_SERVICE_URL` for the ATProto service or PDS target
- `BLUESKY_MANAGED_ENABLED`, `BLUESKY_MANAGED_SERVICE_URL`,
  `BLUESKY_MANAGED_DOMAIN`, and `BLUESKY_MANAGED_ADMIN_PASSWORD` for managed
  account provisioning

## License

This repository is AGPL-3.0-only unless a file says otherwise.
