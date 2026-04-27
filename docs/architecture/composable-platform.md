# Composable Platform

Elektrine has one public module switch and one advanced override:

- `ELEKTRINE_ENABLED_MODULES` controls the normal deployment module set
- `ELEKTRINE_RELEASE_MODULES` optionally overrides build-time selection only

That means most deploys only need `ELEKTRINE_ENABLED_MODULES`. The release
override stays available for hosters who want to compile a broader image and
hide some compiled modules later.

Current platform module ids:

- `chat`
- `social`
- `email`
- `vault`
- `vpn`
- `dns`

Accepted aliases:

- `password-manager`
- `password_manager`

Operational rules:

- use `scripts/release/deploy_release.sh` for hosted or subset builds
- use `scripts/deploy/docker_deploy.sh` for normal Docker self-hosts
- use `deploy/docker/compose.core.yml` only when you want the app-plus-Postgres baseline
- treat `email`, `dns`, `vpn`, `onion`, TURN, and client artifacts as add-ons around the default self-host image
