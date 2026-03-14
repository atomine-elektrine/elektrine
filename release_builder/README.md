# Release Builder

This project builds hoster-specific Elektrine releases without compiling every
optional module app in the umbrella.

## Build any subset

```bash
scripts/deploy_release.sh --modules email,vpn
```

Each unique module set gets its own build output under
`_build/release_builder/<module-set>/`, so switching from one combination to
another does not reuse stale compiled app manifests.

The Dockerfile also uses `scripts/deploy_release.sh`, so container builds now
go through `release_builder/` by default instead of the root umbrella release.

## Fly Deploy

Use the Fly wrapper for module-specific deployments:

```bash
scripts/fly_deploy.sh --modules chat,social --app your-fly-app
```

It renders a temporary Fly config that matches the selected module set, updates
`ELEKTRINE_RELEASE_MODULES` and `ELEKTRINE_ENABLED_MODULES`, and removes the
POP3/IMAP/SMTP service blocks when `email` is not selected.

## Supported module ids

- `chat`
- `social`
- `email`
- `vault`
- `vpn`

Special values:

- `all`
- `none`

The builder always includes:

- `elektrine`
- `elektrine_web`

Everything else is selected from `ELEKTRINE_RELEASE_MODULES`.
