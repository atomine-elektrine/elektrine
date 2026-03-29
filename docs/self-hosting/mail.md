# Mail Self-hosting

Elektrine mail is a two-deployment setup.

- this repo owns mailbox UI, storage, JMAP, WKD, and Haraka-facing webhooks
- `elektrine-haraka` owns SMTP edge, submission, outbound delivery, and queueing

You can run both deployments on the same bare-metal server.

To enable mail:

1. add the `email` module in `ELEKTRINE_RELEASE_MODULES` and `ELEKTRINE_ENABLED_MODULES`
2. fill in the mail section already present in `.env.example` / `.env.production`
3. deploy Haraka separately
4. connect the two systems with `HARAKA_BASE_URL`; internal API and webhook secrets are derived automatically from `ELEKTRINE_MASTER_SECRET` if omitted

## Same-server option

Recommended layout on one host:

- `elektrine` at `/opt/elektrine/app`
- `elektrine-haraka` at `/opt/elektrine/haraka`
- one public web domain for Phoenix, for example `example.com`
- one public mail domain for Haraka, for example `mail.example.com`

Run Elektrine with the email module enabled:

```bash
scripts/deploy/docker_deploy.sh --modules chat,social,email,vault --profile caddy
```

Elektrine-side env values usually look like:

```dotenv
PRIMARY_DOMAIN=example.com
ELEKTRINE_MASTER_SECRET=replace-with-long-random-secret
EMAIL_DOMAIN=example.com
ELEKTRINE_RELEASE_MODULES=chat,social,email,vault
ELEKTRINE_ENABLED_MODULES=chat,social,email,vault

HARAKA_BASE_URL=https://mail.example.com
DATABASE_SSL_ENABLED=false
```

`EMAIL_DOMAIN` is the mailbox domain, so it is usually your main domain like
`example.com`. Do not set it to the Haraka host unless you actually want
addresses and built-in profile URLs under that host. Keep the mail server host in
`HARAKA_BASE_URL`, and use `CUSTOM_DOMAIN_MX_HOST=mail.example.com` when custom
domains should point their MX records at the Haraka host.

Same-server networking guidance:

- keep Elektrine and Haraka as separate Compose projects
- publish Haraka's public SMTP ports on the host used for mail delivery
- keep Elektrine web traffic on Caddy/Phoenix
- for same-server Docker, point `HARAKA_BASE_URL` at Haraka's shared-network API endpoint such as `http://haraka-outbound:8080`
- if Haraka owns public SMTPS on `465`, move Phoenix's `SMTP_TLS_BIND` off that port (for example `127.0.0.1:2465:2587`)
- share only the API credentials and webhook secrets, not the Compose project itself
- by default Elektrine derives `INTERNAL_API_KEY`, `HARAKA_HTTP_API_KEY`, `PHOENIX_API_KEY`, `HARAKA_INTERNAL_SIGNING_SECRET`, and `EMAIL_RECEIVER_WEBHOOK_SECRET` from `ELEKTRINE_MASTER_SECRET`

Suggested split:

- Elektrine: `80/443` for web, plus mailbox access on `143/110` and native secure mailbox access on `993/995`
- Haraka: `25` for inbound SMTP, `587` or `465` for submission, `443` for Haraka admin/API if that repo exposes it through HTTPS

SMTP delivery/submission stays with Haraka in this split setup.
Elektrine does not bind public `25`, `465`, or `587` when Haraka is the SMTP edge.

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

Required env for native TLS mailbox access:

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
IMAP_TLS_CERT_PATH=/opt/elektrine/certs/imap.crt
IMAP_TLS_KEY_PATH=/opt/elektrine/certs/imap.key
POP3_TLS_CERT_PATH=/opt/elektrine/certs/pop.crt
POP3_TLS_KEY_PATH=/opt/elektrine/certs/pop.key
```

If you do not want to run a second deployment, do not enable the `email` module.
