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

For wildcard issuance directly in Caddy through Cloudflare DNS, set instead:

- `CLOUDFLARE_API_TOKEN`

When you deploy through `scripts/deploy/docker_deploy.sh`, you usually do not
need to set `CADDY_CONFIG_PATH` manually. The deploy tooling auto-selects the
wildcard Cloudflare Caddyfile when it sees wildcard site entries together with
`CLOUDFLARE_API_TOKEN`, or the wildcard-external Caddyfile when it sees mounted
cert/key paths.

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

If you use Cloudflare DNS challenge instead, set `CLOUDFLARE_API_TOKEN` and let
the deploy wrapper select the wildcard Cloudflare Caddyfile automatically.

If you bypass the deploy script and run raw `docker compose`, set
`CADDY_CONFIG_PATH` yourself to one of:

- `../caddy/Caddyfile.wildcard-cloudflare`
- `../caddy/Caddyfile.baremetal.wildcard-cloudflare`
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
- wildcard Cloudflare mode lets Caddy issue and renew wildcard certs directly
- wildcard external mode is the recommended path for high-volume username subdomains
- stock on-demand TLS is still available in the default Caddyfile for explicit-host setups
- `mta-sts.<domain>` is treated as a built-in host so MTA-STS policy delivery can use the same edge
