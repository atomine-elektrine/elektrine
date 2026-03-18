# Composable Platform

Elektrine has two different module switches:

- `ELEKTRINE_RELEASE_MODULES` controls what gets compiled into a release
- `ELEKTRINE_ENABLED_MODULES` controls what stays visible at runtime

That split is useful for hosters because it lets you build a smaller release
and still hide compiled modules later if you need to.

Current platform module ids:

- `chat`
- `social`
- `email`
- `vault`
- `vpn`

Operational rules:

- use `scripts/release/deploy_release.sh` for hoster builds
- use `scripts/deploy/fly_deploy.sh` for Fly deployments
- use `deploy/docker/compose.core.yml` as the default self-host path
- treat `email`, `vpn`, `onion`, and client artifacts as add-ons
