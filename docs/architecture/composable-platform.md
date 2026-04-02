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

Operational rules:

- use `scripts/release/deploy_release.sh` for hoster builds
- use `deploy/docker/compose.core.yml` as the default self-host path
- treat `email`, `vpn`, `onion`, and client artifacts as add-ons around the default self-host image
