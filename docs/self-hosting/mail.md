# Mail Self-hosting

Elektrine mail is a two-deployment setup.

- this repo owns mailbox UI, storage, JMAP, WKD, and Haraka-facing webhooks
- `elektrine-haraka` owns SMTP edge, submission, outbound delivery, and queueing

You can run both deployments on the same bare-metal server.

To enable mail:

1. add the `email` module in `ELEKTRINE_RELEASE_MODULES` and `ELEKTRINE_ENABLED_MODULES`
2. merge settings from `env/mail.env.example`
3. deploy Haraka separately
4. connect the two systems with `HARAKA_BASE_URL`, outbound API auth, and inbound webhook auth

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
PHX_HOST=example.com
EMAIL_DOMAIN=example.com
SUPPORTED_DOMAINS=example.com
ELEKTRINE_RELEASE_MODULES=chat,social,email,vault
ELEKTRINE_ENABLED_MODULES=chat,social,email,vault

EMAIL_SERVICE=haraka
HARAKA_BASE_URL=https://mail.example.com
HARAKA_HTTP_API_KEY=replace-me
PHOENIX_API_KEY=replace-me
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

Suggested split:

- Elektrine: `80/443` for web, plus `993/995` and optionally a remapped `SMTP_TLS_BIND` only if you want Phoenix mail protocol ports exposed
- Haraka: `25` for inbound SMTP, `587` or `465` for submission, `443` for Haraka admin/API if that repo exposes it through HTTPS

If you do not want to run a second deployment, do not enable the `email` module.
