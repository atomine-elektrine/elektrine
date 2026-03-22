# Release Builder

This project builds hoster-specific Elektrine releases without compiling every
optional module app in the umbrella.

## Build any subset

```bash
scripts/release/deploy_release.sh --modules email,vpn
```

Each unique module set gets its own build output under
`_build/release_builder/<module-set>/`, so switching from one combination to
another does not reuse stale compiled app manifests.

`deploy/docker/Dockerfile` also uses `scripts/release/deploy_release.sh`, so container builds now
go through `release_builder/` by default instead of the root umbrella release.

## Docker deploy

Use the Docker wrapper for module-specific deployments:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social --profile caddy
```

It renders a temporary Compose file that matches the selected module set,
updates `ELEKTRINE_RELEASE_MODULES`, `ELEKTRINE_ENABLED_MODULES`, and
`ELEKTRINE_ENABLE_MAIL`, and removes POP3/IMAP/SMTP port bindings when `email`
is not selected.

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
