# Caddy edge

Elektrine ships with a Docker-friendly Caddy edge that stays self-hosting
friendly:

- stock app containers behind one reverse proxy
- automatic HTTPS for your owned domains
- optional wildcard certificates issued through Elektrine DNS and mounted into Caddy
- on-demand TLS for custom/user domains
- plain HTTP bootstrap access over the server IP before a domain is ready

## What it manages

The edge has two configurable explicit certificate blocks:

- `CADDY_MANAGED_SITE_1`
- `CADDY_MANAGED_SITE_2`

Each value is a space-separated site list. Typical values look like:

```env
CADDY_MANAGED_SITE_1="example.com mail.example.com imap.example.com pop.example.com smtp.example.com mta-sts.example.com"
CADDY_MANAGED_SITE_2="alt.example.net mail.alt.example.net imap.alt.example.net pop.alt.example.net smtp.alt.example.net mta-sts.alt.example.net"
```

Keep the two lists disjoint. If you only manage one domain family, leave `CADDY_MANAGED_SITE_2` unset.

Do not put wildcard hosts like `*.example.com` in `CADDY_MANAGED_SITE_*` with the stock Caddyfile. Those overlap the generic on-demand `https://` site and Caddy rejects the config as an ambiguous site definition.

This lets self-hosters swap out bundled domains without editing the Caddyfile.
Managed domains use Caddy's normal ACME flow.

If you expect lots of dynamic user/profile subdomains like
`username.example.com`, prefer the wildcard external-cert config. It avoids
per-host certificate issuance and keeps the runtime config simple.

## Required environment

Set these keys in `.env.production` and use `.env.example` as the starting point:

- `ACME_EMAIL`
- `CADDY_MANAGED_SITE_1`

For wildcard/external certificate mode, also set:

- `CADDY_TLS_MOUNT_DIR`
- `CADDY_MANAGED_SITE_1_CERT_PATH`
- `CADDY_MANAGED_SITE_1_KEY_PATH`

Elektrine can issue the wildcard cert with Elektrine DNS and use external
certificate mode. The issuer loads `.env.production` and infers the domain/API base from
`PRIMARY_DOMAIN`, `PHX_HOST`, and `CADDY_MANAGED_SITE_1`. It uses the existing
`PHOENIX_API_KEY` or `CADDY_EDGE_API_KEY` against Elektrine's internal DNS-01
endpoint and saves that config into acme.sh. If needed, override with
`--domain=example.com` or `--api-base=https://example.com`.

For automatic renewals through Oban, set:

```env
ACME_WILDCARD_RENEWAL_ENABLED=true
ACME_HOME=/data/acme.sh
```

Oban runs `acme.sh --cron` daily. acme.sh only renews certificates near expiry
and runs the reload command saved during initial issuance.

When deploying through `scripts/deploy/docker_deploy.sh`, initial issuance is
automatic when all of these are true:

- the `caddy` profile is enabled
- `CADDY_MANAGED_SITE_*` contains a wildcard host
- `ACME_WILDCARD_RENEWAL_ENABLED=true`

The script installs:

- `/opt/elektrine/certs/example.com.fullchain.pem`
- `/opt/elektrine/certs/example.com.key.pem`

When you deploy through `scripts/deploy/docker_deploy.sh`, you usually do not
need to set `CADDY_CONFIG_PATH` manually. The deploy tooling auto-selects the
wildcard-external Caddyfile when it sees mounted cert/key paths.

## Deploy

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,email,vault --profile caddy
```

For lots of dynamic subdomains, keep the domain list minimal and wildcard-based:

```env
CADDY_MANAGED_SITE_1="example.com *.example.com"
CADDY_MANAGED_SITE_2="alt.example.net *.alt.example.net"
```

If you use external wildcard certs, mount the directory that contains your certs
with `CADDY_TLS_MOUNT_DIR`, then set the matching `CADDY_MANAGED_SITE_*_CERT_PATH`
and `..._KEY_PATH` values to container paths.

If you use the Elektrine ACME script, those files are installed at the default
paths inferred by `scripts/deploy/docker_deploy.sh`, so normally only
`CADDY_MANAGED_SITE_1="example.com *.example.com"` and
`CADDY_TLS_MOUNT_DIR=/opt/elektrine/certs` are needed for Caddy.

If you bypass the deploy script and run raw `docker compose`, set
`CADDY_CONFIG_PATH` yourself to one of:

- `../caddy/Caddyfile.wildcard-external`
- `../caddy/Caddyfile.baremetal.wildcard-external`

If you only need a few explicit hosts and want Caddy itself to manage them,
keep using the stock `Caddyfile` and do not put wildcard hosts into
`CADDY_MANAGED_SITE_*`.

## Notes

- raw server IP access is expected to work over `http://` for first-run bootstrap
- raw server IP access is not expected to work over `https://`
- for full browser interactivity over raw IP, set `EXTRA_CHECK_ORIGINS=http://<server-ip>`
- wildcard external mode keeps certificate issuance outside Caddy
- Elektrine DNS wildcard automation uses acme.sh DNS-01 and then feeds Caddy external cert files
- Oban runs acme.sh renewal checks and acme.sh runs the saved Caddy reload command after renewal
- wildcard external mode is the recommended path for high-volume username subdomains
- stock on-demand TLS is still available in the default Caddyfile for explicit-host setups
- `mta-sts.<domain>` is treated as a built-in host so MTA-STS policy delivery can use the same edge
