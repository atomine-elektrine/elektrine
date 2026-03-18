# Mail Self-hosting

Elektrine mail is a two-deployment setup.

- this repo owns mailbox UI, storage, JMAP, WKD, and Haraka-facing webhooks
- `elektrine-haraka` owns SMTP edge, submission, outbound delivery, and queueing

To enable mail:

1. add the `email` module in `ELEKTRINE_RELEASE_MODULES` and `ELEKTRINE_ENABLED_MODULES`
2. merge settings from `env/mail.env.example`
3. deploy Haraka separately
4. connect the two systems with `HARAKA_BASE_URL`, outbound API auth, and inbound webhook auth

If you do not want to run a second deployment, do not enable the `email` module.
