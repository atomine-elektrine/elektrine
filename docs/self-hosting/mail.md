# Mail Self-hosting

For production internet mail, treat Elektrine and Haraka as two pieces:

- Elektrine owns mailbox UI, storage, JMAP, WKD, IMAP/POP3, SMTP submission, and
  webhooks that Haraka calls
- `elektrine-haraka` owns inbound SMTP on port 25, outbound delivery, and queueing

You can run both deployments on the same bare-metal server. The Docker `email`
profile starts Elektrine's mail protocol container; it is not a replacement for
Haraka when you need normal inbound and outbound internet mail.

To enable mail:

1. Add the `email` module in `ELEKTRINE_ENABLED_MODULES`.
2. Fill in the mail section already present in `.env.example` / `.env.production`.
3. Enable the Docker `email` profile if this host should expose Elektrine's IMAP/POP3/SMTP submission listeners.
4. Deploy Haraka for production inbound/outbound relay.
5. Connect the two systems with `HARAKA_BASE_URL`; internal API and webhook secrets are derived automatically from `ELEKTRINE_MASTER_SECRET` if omitted.

Managed DNS for mail also provisions:

- `_mta-sts` TXT for MTA-STS discovery
- `_smtp._tls` TXT for TLS-RPT reporting
- `mta-sts.<domain>` as the HTTPS policy host alias

Phoenix serves the MTA-STS policy at:

```text
https://mta-sts.<domain>/.well-known/mta-sts.txt
```

If you want SMTP DANE, add a manual `TLSA` record for your SMTP listener such as
`_25._tcp.mail` once you have the certificate association data to publish.

## Same-server option

Recommended layout on one host:

- `elektrine` at `/opt/elektrine/app`
- `elektrine-haraka` at `/opt/elektrine/haraka`
- one public web domain for Phoenix, for example `example.com`
- one public mail domain for Haraka, for example `mail.example.com`

Run Elektrine with the email module enabled:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,email,nerve,atomine --profile caddy
```

Elektrine-side env values usually look like:

```dotenv
PRIMARY_DOMAIN=example.com
ELEKTRINE_MASTER_SECRET=<generate-a-long-random-secret>
EMAIL_DOMAIN=example.com
EMAIL_RAW_SOURCE_MAX_BYTES=10485760
ELEKTRINE_ENABLED_MODULES=chat,social,email,nerve,atomine

HARAKA_BASE_URL=https://mail.example.com
DATABASE_SSL_ENABLED=false
```

`EMAIL_DOMAIN` is the mailbox domain, so it is usually your main domain like
`example.com`. Do not set it to the Haraka host unless you actually want
addresses and built-in profile URLs under that host. Keep the mail server host in
`HARAKA_BASE_URL`, and use `CUSTOM_DOMAIN_MX_HOST=mail.example.com` when custom
domains should point their MX records at the Haraka host.

`EMAIL_RAW_SOURCE_MAX_BYTES` limits how much original RFC822 source Elektrine
retains per message. The default is 10 MiB (`10485760`). Messages larger than the
limit are still delivered normally, but their duplicate raw source is omitted and
the omission is recorded in message metadata.

Same-server networking guidance:

- keep Elektrine and Haraka as separate Compose projects
- publish Elektrine's SMTP submission port on the host used for mail clients
- keep Elektrine web traffic on Caddy/Phoenix
- for same-server Docker, point `HARAKA_BASE_URL` at Haraka's shared-network API endpoint such as `http://haraka-outbound:8080`
- share only the API credentials and webhook secrets, not the Compose project itself
- by default Elektrine derives `INTERNAL_API_KEY`, `HARAKA_HTTP_API_KEY`, `PHOENIX_API_KEY`, `HARAKA_INTERNAL_SIGNING_SECRET`, and `EMAIL_RECEIVER_WEBHOOK_SECRET` from `ELEKTRINE_MASTER_SECRET`

Suggested split:

- Elektrine: `80/443` for web, public SMTPS submission on `465`, optional SMTP submission on `587`, plus mailbox access on `143/110` and native secure mailbox access on `993/995`
- Haraka: `25` for inbound SMTP, plus outbound relay/API as needed

SMTP submission terminates at Elektrine in this split setup.
Elektrine can still relay outbound mail through Haraka's HTTP/API path.

Elektrine can expose native secure mailbox access directly for clients:

- `143` for IMAP
- `110` for POP3
- `993` for IMAPS
- `995` for POP3S

Internally, Elektrine keeps non-privileged listener ports and Docker maps the standard
public ports onto them:

- `143 -> 2143`
- `110 -> 2110`
- `993 -> 2993`
- `995 -> 2995`

Recommended client settings:

- prefer `993` (IMAPS) or `995` (POP3S)
- use `143` / `110` only for clients that need plain IMAP/POP compatibility
- use `465` with `SSL/TLS` for SMTP submission; Docker exposes this publicly by default
- use `587` with `STARTTLS` only if you publish it externally, for example `SMTP_BIND=587:2587`

For Gmail on mobile, use IMAP over SSL/TLS on port `993` with a publicly trusted
certificate whose hostname matches the configured incoming mail server. If Gmail
has already cached an empty mailbox state after a protocol or TLS issue, remove
and re-add the account after the fixed mail service is running.

Required env for native TLS mailbox access and encrypted SMTP submission:

```dotenv
MAIL_TLS_CERT_PATH=/opt/elektrine/certs/mail.crt
MAIL_TLS_KEY_PATH=/opt/elektrine/certs/mail.key
MAIL_TLS_MOUNT_DIR=/opt/elektrine/certs
```

`MAIL_TLS_MOUNT_DIR` is the host directory bind-mounted into the mail container at
`/opt/elektrine/certs`. The entrypoint copies configured cert/key files into
`/data/certs/runtime` before dropping privileges, so the mounted files only need to
be readable by root inside the container.

Optional per-protocol cert overrides:

```dotenv
SMTP_TLS_CERT_PATH=/opt/elektrine/certs/smtp.crt
SMTP_TLS_KEY_PATH=/opt/elektrine/certs/smtp.key
IMAP_TLS_CERT_PATH=/opt/elektrine/certs/imap.crt
IMAP_TLS_KEY_PATH=/opt/elektrine/certs/imap.key
POP3_TLS_CERT_PATH=/opt/elektrine/certs/pop.crt
POP3_TLS_KEY_PATH=/opt/elektrine/certs/pop.key
```

## Haraka TLS with Elektrine wildcard certs

Haraka owns inbound SMTP on port `25`, so MTA-STS delivery depends on the
certificate Haraka serves, not only the certificate used by Caddy or Elektrine's
mail submission container. Do not keep Haraka on a separately copied
`deployment_ssl-certs` Docker volume; it can go stale after wildcard renewal.

For reproducible split deployments, keep `elektrine-haraka` as a separate
repo/deployment but make the interface explicit:

- `HARAKA_DEPLOY_DIR` points at the Haraka checkout/deploy directory.
- `HARAKA_COMPOSE_FILES` lists the committed Haraka base compose file or files.
  Use commas or colons for multiple files. Relative paths resolve from
  `HARAKA_DEPLOY_DIR`.
- Haraka compose services are named `haraka-inbound`, `haraka-submission`,
  `haraka-outbound`, and `haraka-worker`.

Example Elektrine production env:

```bash
HARAKA_DEPLOY_DIR=/opt/elektrine-haraka
HARAKA_COMPOSE_FILES=compose.yml
```

Use Elektrine's wildcard cert directory as the single source of truth:

```bash
scripts/deploy/configure_haraka_wildcard_tls.sh \
  --haraka-dir /opt/elektrine-haraka \
  --compose-file compose.yml \
  --domain example.com
```

The script writes `compose.override.yml` in the Haraka deployment. It
bind-mounts:

```text
/opt/elektrine/certs/example.com.fullchain.pem -> /app/ssl/cert.crt
/opt/elektrine/certs/example.com.key.pem       -> /app/ssl/cert.key
```

Recreate Haraka after writing the override:

```bash
cd /opt/elektrine-haraka
docker compose up -d --force-recreate haraka-inbound haraka-submission haraka-outbound haraka-worker
```

Or do both in one command:

```bash
scripts/deploy/configure_haraka_wildcard_tls.sh \
  --haraka-dir /opt/elektrine-haraka \
  --compose-file compose.yml \
  --domain example.com \
  --apply
```

After renewal, restarting or recreating Haraka is enough; no cert copy step is
needed because the bind mount points at the renewed wildcard files. If ACME runs
on the host, use the `--apply` command above as the renewal deploy hook.

Verify inbound SMTP before enabling or keeping MTA-STS `mode: enforce`:

```bash
openssl s_client -starttls smtp -connect localhost:25 \
  -servername mail.example.com \
  -verify_hostname mail.example.com
```

The output must include `Verify return code: 0 (ok)`.

When `scripts/deploy/docker_deploy.sh` runs on a host that has a Haraka
deployment configured with `HARAKA_DEPLOY_DIR` and `HARAKA_COMPOSE_FILES`, it
performs this configuration automatically after ensuring wildcard certs. For
older hosts, it can still try to discover a standard deployment at
`/opt/elektrine-haraka` or `/opt/elektrine/haraka`, but explicit env is the
reproducible path.

If you are not ready to run Haraka, keep the `email` module off for production
hosts. Enabling only Elektrine's `email` module/profile gives you mailbox and
protocol pieces, not a complete internet mail service.
