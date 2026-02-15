# Contributing

Thanks for contributing to Elektrine.

## Scope

This repository is an umbrella project. All apps in `apps/` are open source under the same root `LICENSE`:

- `apps/elektrine`
- `apps/elektrine_web`
- `apps/elektrine_email`
- `apps/elektrine_social`
- `apps/elektrine_vpn`
- `apps/elektrine_password_manager`

## Development Setup

1. Install Elixir/Erlang and PostgreSQL.
2. Clone the repo.
3. Copy `.env.example` to `.env` and set local values.
4. Run setup:

```bash
mix setup
```

5. Start the app:

```bash
mix phx.server
```

## Running Checks

Run these before opening a PR:

```bash
mix format
mix compile --warnings-as-errors
mix test
```

## Pull Requests

1. Keep PRs focused and small.
2. Include tests for behavior changes.
3. Update docs when behavior/config changes.
4. Fill out the PR template.

## Commit Style

Use clear, imperative commit messages, for example:

- `Add federation outbox retry worker`
- `Fix sequence gap recovery for messaging events`

## Security

Do not open public issues for vulnerabilities. Use the process in `SECURITY.md`.
