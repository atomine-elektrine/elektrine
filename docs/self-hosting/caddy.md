# Caddy edge

Elektrine ships with a Docker-friendly Caddy edge that stays self-hosting
friendly:

- stock app containers behind one reverse proxy
- automatic HTTPS for your owned domains
- on-demand TLS for custom/user domains
- Cloudflare DNS challenge support for wildcard certificates

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

## Required environment

Merge `env/caddy.env.example` into `.env.production` and set at least:

- `ACME_EMAIL`
- `CLOUDFLARE_API_TOKEN`
- `CADDY_MANAGED_SITE_1`

## Deploy

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,email,vault --profile caddy
```

## Notes

- wildcard certificates require DNS-01, so Caddy needs Cloudflare DNS API access
- on-demand TLS remains enabled for user-added/custom domains outside the
  explicitly managed site blocks
- profile subdomains like `maxfield.example.com` are covered by `*.example.com`
- wildcard certificates only cover one label deep
