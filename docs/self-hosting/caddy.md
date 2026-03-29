# Caddy edge

Elektrine ships with a Docker-friendly Caddy edge that stays self-hosting
friendly:

- stock app containers behind one reverse proxy
- automatic HTTPS for your owned domains
- optional external wildcard certificates mounted into Caddy
- on-demand TLS for custom/user domains
- plain HTTP bootstrap access over the server IP before a domain is ready

## What it manages

The edge has two configurable explicit certificate blocks:

- `CADDY_MANAGED_SITE_1`
- `CADDY_MANAGED_SITE_2`

Each value is a space-separated site list. Typical values look like:

```env
CADDY_MANAGED_SITE_1="example.com *.example.com mail.example.com imap.example.com pop.example.com smtp.example.com"
CADDY_MANAGED_SITE_2="alt.example.net *.alt.example.net mail.alt.example.net imap.alt.example.net pop.alt.example.net smtp.alt.example.net"
```

This lets self-hosters swap out bundled domains without editing the Caddyfile.
Managed domains use Caddy's normal ACME flow.
If you need a wildcard certificate for lots of username subdomains, you can also
switch to an alternate Caddyfile that loads cert/key files produced by an
external ACME client.

## Required environment

Set these keys in `.env.production` and use `.env.example` as the starting point:

- `ACME_EMAIL`
- `CADDY_MANAGED_SITE_1`

For external wildcard certificate mode, also set:

- `CADDY_CONFIG_PATH`
- `CADDY_TLS_MOUNT_DIR`
- `CADDY_MANAGED_SITE_1_CERT_PATH`
- `CADDY_MANAGED_SITE_1_KEY_PATH`

## Deploy

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,email,vault --profile caddy
```

For external wildcard certificates, point `CADDY_CONFIG_PATH` at
`../caddy/Caddyfile.external-certs` in `.env.production` for the edge-only
profile, or `../caddy/Caddyfile.baremetal.external-certs` for the full stack.
Mount the directory that contains your certs with `CADDY_TLS_MOUNT_DIR`, then
set the matching `CADDY_MANAGED_SITE_*_CERT_PATH` / `..._KEY_PATH` values to
container paths.

## Notes

- raw server IP access is expected to work over `http://` for first-run bootstrap
- raw server IP access is not expected to work over `https://`
- external wildcard mode keeps Caddy stock; certificate issuance happens outside Caddy
- on-demand TLS remains enabled for user-added/custom domains outside the
  explicitly managed site blocks
- profile subdomains like `maxfield.example.com` are covered by `*.example.com`
