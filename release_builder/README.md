# Release Builder

This project builds module-specific Elektrine releases without compiling every
optional umbrella app.

## Build any subset

```bash
scripts/release/deploy_release.sh --modules email,vpn
```

Each unique module set gets its own build output under
`_build/release_builder/<module-set>/`, so switching module combinations does
not reuse stale compiled manifests.

`deploy/docker/Dockerfile` uses `scripts/release/deploy_release.sh` too, so
container builds go through `release_builder/` by default instead of the root
umbrella release.

## Docker deploy

Use the Docker wrapper for module-specific deployments:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social --profile caddy
```

It renders a Compose file that matches the selected module set, sets
`ELEKTRINE_ENABLED_MODULES`, derives `ELEKTRINE_RELEASE_MODULES` from it by
default, sets mail runtime flags, and removes POP3, IMAP, and SMTP port
bindings when `email` is not selected.

If `vpn` is in the selected module set, the deploy wrapper also turns on the
bundled Docker `vpn` service automatically. If `vpn` is not selected, that
service stays off.

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

Everything else is selected from `ELEKTRINE_ENABLED_MODULES` by default.
`ELEKTRINE_RELEASE_MODULES` is still available as an advanced build override.
