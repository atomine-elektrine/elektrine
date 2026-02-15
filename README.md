# Elektrine

Elektrine is an Elixir/Phoenix umbrella app that combines a few things in one place:

- email (web + IMAP/POP3 + SMTP integration)
- federated social features (ActivityPub)
- real-time messaging
- CalDAV/CardDAV support
- optional VPN and password manager modules

This repo is the development source for all of that.

## What You Get

Elektrine is split into focused umbrella apps:

- `apps/elektrine` - core domain logic, accounts, persistence, jobs
- `apps/elektrine_web` - Phoenix endpoint, controllers, LiveView UI
- `apps/elektrine_email` - email domain logic and protocol services
- `apps/elektrine_social` - timeline/social features
- `apps/elektrine_vpn` - VPN/WireGuard features
- `apps/elektrine_password_manager` - password vault features

See `apps/README.md` and per-app READMEs for deeper details.

## Quick Start (Local Dev)

### 1. Prerequisites

- Elixir + Erlang/OTP
- PostgreSQL

### 2. Configure env

Use the example file as a base:

```bash
cp .env.example .env
```

For local development, `EMAIL_SERVICE=local` is the simplest path.

### 3. Setup + run

```bash
# installs deps and sets up DB (alias runs setup in apps/elektrine)
mix setup

# start the app
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000).

## Running Tests

```bash
# full umbrella test run
mix test

# app-specific examples
mix test apps/elektrine_web/test
mix test apps/elektrine_email/test
```

## Configuration Notes

- Primary env reference: `.env.example`
- Runtime config lives mainly in `config/runtime.exs`
- Test config lives in `config/test.exs`

If you are running production, you will need real values for secrets, database, storage, and mail provider settings.

## Protocol/Integration Endpoints

A few useful ones:

- `POST /api/haraka/inbound` - inbound mail webhook
- `GET /.well-known/webfinger` - federation discovery
- `GET /.well-known/nodeinfo` - federation metadata
- `/.well-known/caldav` and `/.well-known/carddav` - DAV discovery

## Deploy

Current production deployment target is Fly.io.

```bash
fly deploy
fly logs
fly ssh console
```

## Contributing / Security / License

- Contributing: `CONTRIBUTING.md`
- Security policy: `SECURITY.md`
- Code of Conduct: `CODE_OF_CONDUCT.md`
- License: `LICENSE`
