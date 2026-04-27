# Elektrine Email

Email domain and protocol services for the Elektrine umbrella.

## What lives here

- Mailbox/message contexts and email workflows
- Alias, filter, template, folder, and label management
- IMAP, POP3, SMTP, and JMAP server modules
- Email processing, categorization, and outbound delivery workers
- Mailbox, contacts, admin mail, CardDAV, JMAP, WKD, unsubscribe routes, and Haraka webhooks

## Notes

- Uses shared persistence/runtime from `elektrine`.
- Public domain API is exposed via `Elektrine.Email`.
- Primary outbound queueing uses Oban (`Elektrine.Email.SendEmailWorker`).
- Router-mounted controllers and LiveViews in this app still use `ElektrineWeb.*`; shared entrypoints live in `ElektrineEmailWeb`.

## Pipeline Boundaries

- Outbound (`Elektrine.Email.Sender`): parse raw SMTP payload first, then sanitize once, then route.
- Inbound routing (`Elektrine.Email.InboundRouting`): resolve recipient mailbox/forwarding and validate routing match.
- Inbound webhook (`ElektrineEmailWeb.HarakaWebhookController`): extract/validate first, then sanitize once before forwarding or storage.
- Render boundary (`elektrine_web`): sanitize HTML for display in iframe/UI contexts.

## Shell Integration

- `elektrine_web` still owns shared account/admin pages and the outer layout.
- Email-specific controllers and LiveViews live in `apps/elektrine_email` even when they keep the `ElektrineWeb.*` namespace.

## License

AGPL-3.0-only (see `../../LICENSE`).
