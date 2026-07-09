# Deploy Runbook

Use the self-host wrapper for new installs:

```bash
scripts/deploy/self_host.sh init --domain example.com --email admin@example.com
scripts/deploy/self_host.sh doctor
scripts/deploy/self_host.sh up
```

Pick a deployment preset instead of composing modules and Docker profiles by
hand:

| Preset | Modules | Docker profiles | Admin default |
| --- | --- | --- | --- |
| `simple-web` | chat, social, nerve, atomine | caddy | public app admin |
| `web-mail` | simple-web + email | caddy, email | public app admin |
| `web-mail-dns` | web-mail + dns, vpn, uptime, kairo | caddy, email, dns | public app admin |
| `full-stack` | all major platform modules | caddy, email, dns, turn, bluesky, vpn | NetBird admin |

Example:

```bash
scripts/deploy/self_host.sh init \
  --domain example.com \
  --email admin@example.com \
  --preset web-mail-dns \
  --admin-access netbird \
  --public-dns-ip 203.0.113.10
```

## Simple Env Keys

Prefer these high-level values in `.env.production`:

```env
DEPLOYMENT_PRESET=web-mail-dns
ADMIN_ACCESS=netbird
TLS_MODE=external-wildcard
PUBLIC_DNS_BIND_IP=203.0.113.10
NETBIRD_ALLOWED_CIDRS="100.90.1.10/32 100.90.2.20/32"
```

The deploy scripts derive lower-level values:

- `PUBLIC_DNS_BIND_IP` derives `DNS_UDP_BIND` and `DNS_TCP_BIND`.
- `TLS_MODE=external-wildcard` or `letsencrypt-dns` selects the external-cert
  Caddyfile.
- `ADMIN_ACCESS=netbird` enables NetBird protection and defaults
  `CADDY_ADMIN_HOST` to `admin.<PRIMARY_DOMAIN>`.

## Admin Access

`ADMIN_ACCESS=public` keeps admin access on the normal app host and disables the
dedicated admin-host gate.

`ADMIN_ACCESS=netbird` uses `admin.<PRIMARY_DOMAIN>` and requires
`NETBIRD_ALLOWED_CIDRS` to contain exact NetBird peer `/32` addresses. Do not use
`100.64.0.0/10`; that is the whole NetBird CGNAT range.

The Caddy value must be whitespace-separated:

```env
NETBIRD_ALLOWED_CIDRS="100.90.1.10/32 100.90.2.20/32"
```

Comma-separated CIDRs are invalid for the Caddy `remote_ip` matcher.

## DNS Split

When this host runs both authoritative DNS and NetBird DNS, bind them to
different IPs:

```env
PUBLIC_DNS_BIND_IP=203.0.113.10
```

This derives:

```env
DNS_UDP_BIND=203.0.113.10:53:5300/udp
DNS_TCP_BIND=203.0.113.10:53:5300/tcp
```

That keeps public DNS on the public interface while NetBird can keep its private
listener on the NetBird interface.

## TLS Modes

Use `TLS_MODE=caddy-auto` when Caddy can issue normal, non-wildcard certificates.

Use `TLS_MODE=external-wildcard` when you already have a wildcard certificate
mounted into the Caddy container:

```env
CADDY_TLS_MOUNT_DIR=/opt/elektrine/certs
CADDY_MANAGED_SITE_1_CERT_PATH=/opt/elektrine/certs/example.com.fullchain.pem
CADDY_MANAGED_SITE_1_KEY_PATH=/opt/elektrine/certs/example.com.key.pem
```

Use `TLS_MODE=letsencrypt-dns` when Elektrine DNS/acme.sh issues the wildcard
certificate into those mounted files.

## Verify

Always run:

```bash
scripts/deploy/self_host.sh doctor
```

The doctor catches the common bad states:

- broad NetBird admin allowlists
- comma-separated Caddy CIDRs
- wildcard TLS without certificate paths
- DNS port conflicts from binding `0.0.0.0:53`
- stale Caddy bind mounts
- missing Docker access
