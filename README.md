# Elektrine

Elektrine is an Elixir umbrella app. The shortest accurate description is:
`elektrine` is the shared product core, `elektrine_web` is the Phoenix shell,
and the major product areas now live in their own apps.

That split matters because this repo supports two different ways of working:

- everyday development, where you usually treat the umbrella as one system
- hoster builds, where you compile only the modules you actually want

If you are new here, read this file once, then jump into the app README that
matches the area you need to change.

## The shape of the repo

Most of the real work lives in a few top-level directories:

- `apps/` contains the umbrella apps
- `config/` contains shared compile-time and runtime config
- `release_builder/` is the supported path for subset releases
- `scripts/` contains deployment wrappers and config renderers
- `docs/` contains longer protocol and platform notes

The umbrella apps break down like this:

- `apps/elektrine`: shared domain logic, `Repo`, supervisors, accounts, uploads,
  notifications, ActivityPub internals, calendar, and the platform module
  registry
- `apps/elektrine_web`: endpoint, router, plugs, shared layouts/components,
  admin shell, and the navigation/auth layer that sits in front of every module
- `apps/elektrine_chat`: chat UI/API ownership
- `apps/elektrine_social`: timeline, communities, federation, and social web
  surface ownership
- `apps/elektrine_email`: mailbox, contacts, mail protocols, JMAP/WKD/public
  email surface ownership
- `apps/elektrine_vpn`: WireGuard management and VPN web/API ownership
- `apps/elektrine_password_manager`: password vault ownership

There is still one shared Phoenix shell. The feature apps own their code, but
`elektrine_web` is where requests enter, auth is applied, layouts are chosen,
and navigation is filtered.

## How the pieces fit together

A normal web request starts in `ElektrineWeb.Router`, goes through the shared
plugs and module guards, and then lands in a controller or LiveView owned by
the relevant feature app. Domain work usually drops into contexts in
`elektrine`, `elektrine_email`, `elektrine_social`, `elektrine_vpn`, or the
other feature apps. Persistence is still shared through `Elektrine.Repo`.

If you notice modules inside feature apps still using the `ElektrineWeb.*`
namespace, that is deliberate. We kept those names stable while moving code
ownership out of `apps/elektrine_web`, so routes and call sites did not need a
second cleanup pass at the same time.

## Composable builds and runtime modules

Elektrine is now composable in two different ways.

`ELEKTRINE_RELEASE_MODULES` decides what gets compiled into a release. This is
for hosters who want a smaller build and do not want to pay for apps they are
not using.

`ELEKTRINE_ENABLED_MODULES` decides what is exposed at runtime. This is for
cases where a compiled module should still be hidden or turned off.

In practice that means:

- compile-time selection controls which apps, jobs, and module-specific code
  make it into the release
- runtime selection controls nav visibility, guarded routes, and optional
  runtime children

The detailed notes are in `docs/composable-platform.md`, but the important
operational rule is simple: if you want a minimal hoster build, use
`release_builder/`, not the legacy root release.

## Running the app locally

From the repo root:

```bash
mix setup
```

To start the web app:

```bash
cd apps/elektrine
mix phx.server
```

Useful commands while working:

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

There are two release paths in this repo, and only one of them is meant for
hosters.

The root umbrella release still exists. It builds the whole platform. That is
fine for local development and full installs.

The supported hoster path is the subset builder:

```bash
scripts/deploy_release.sh --modules email,vpn
```

That script builds assets, selects the requested module apps, and produces a
release under `_deploy_release/`. The `Dockerfile` also uses this path now, so
container builds default to the subset builder instead of the full umbrella.

For Fly, use the wrapper instead of calling `fly deploy` against the root
template directly:

```bash
scripts/fly_deploy.sh --modules chat,social --app your-app
```

That wrapper renders a module-aware Fly config first. If `email` is not in the
module set, it removes the POP3, IMAP, and SMTP service blocks so you do not
accidentally publish mail ports for a non-mail deployment.

## Email is a two-repo deployment

The `email` module in this repo is not the whole mail stack by itself.
Elektrine's mail transport lives in
[`atomine-elektrine/elektrine-haraka`](https://github.com/atomine-elektrine/elektrine-haraka),
and you should treat that repo as part of any real email deployment.

In practice, this repo owns the mailbox product: UI, aliases, contacts, JMAP,
WKD, message storage, and the Phoenix endpoints that receive mail webhooks.
`elektrine-haraka` owns the SMTP edge and delivery pipeline: inbound SMTP,
authenticated submission, outbound send API, Redis-backed mail queueing, and
the worker that posts cleaned inbound message data back into Phoenix.

That is why production email config here is Haraka-specific. If you enable the
`email` module, plan to deploy `elektrine-haraka` alongside it and wire the two
systems together with `HARAKA_BASE_URL`, the outbound Haraka API key, and the
inbound webhook key.

## Configuration that matters in production

The usual production basics still apply: `DATABASE_URL`, `SECRET_KEY_BASE`,
`PHX_HOST`, and a real domain configuration.

On top of that, module-specific validation now fails fast on boot:

- `email` needs `PRIMARY_DOMAIN` or `EMAIL_DOMAIN`
- `email` currently expects `EMAIL_SERVICE=haraka`
- Haraka-backed email needs `HARAKA_BASE_URL`
- Haraka-backed email also needs one outbound API key:
  `HARAKA_HTTP_API_KEY`, `HARAKA_OUTBOUND_API_KEY`, or `HARAKA_API_KEY`
- Haraka-backed email also needs one inbound webhook key:
  `PHOENIX_API_KEY`, `HARAKA_INBOUND_API_KEY`, or `HARAKA_API_KEY`
- `vpn` needs `VPN_FLEET_REGISTRATION_KEY`

If a hoster enables one of those modules without the required env, boot should
fail immediately instead of half-working.

## Where to start reading

If you just want a map:

- `apps/README.md`
- `apps/elektrine/README.md`
- `apps/elektrine_web/README.md`
- `release_builder/README.md`
- `docs/composable-platform.md`

If you are chasing a bug, start here:

- chat problems: `apps/elektrine_chat/` and shared messaging code in
  `apps/elektrine/`
- social or federation problems: `apps/elektrine_social/`
- email or protocol problems: `apps/elektrine_email/`
- VPN problems: `apps/elektrine_vpn/`
- vault problems: `apps/elektrine_password_manager/`
- routing, auth, layouts, shared UI, or nav problems: `apps/elektrine_web/`

If you are chasing a deploy issue:

- build selection: `release_builder/`
- runtime env handling: `config/runtime.exs`
- Docker path: `Dockerfile`
- Fly path: `fly.toml`, `scripts/render_fly_toml.sh`,
  `scripts/fly_deploy.sh`

## A few practical notes

There is still one shared database repo, and the migrations still live in
`apps/elektrine/priv/repo/migrations`. Code ownership is modular now, but data
ownership is still centralized.

Background work runs on Oban. Subset releases filter out queues and cron
entries for apps that were not compiled in.

Tests are mostly organized by umbrella app. Browser tests are still gated by
`ENABLE_WALLABY`.

## License

This repository is AGPL-3.0-only unless a file says otherwise.
