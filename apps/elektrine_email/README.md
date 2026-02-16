# Elektrine Email

Email domain and protocol services for the Elektrine umbrella.

## What this app owns

- Mailbox/message contexts and email workflows
- Alias, filter, template, folder, and label management
- IMAP, POP3, SMTP, and JMAP server modules
- Email processing, categorization, and outbound delivery workers

## Notes

- Uses shared persistence/runtime from `elektrine`.
- API surface is exposed via `Elektrine.Email`.
- Primary outbound queueing uses Oban (`Elektrine.Email.SendEmailWorker`).

## Pipeline Boundaries

- Outbound (`Elektrine.Email.Sender`): parse raw SMTP payload first, then sanitize once, then route.
- Inbound routing (`Elektrine.Email.InboundRouting`): resolve recipient mailbox/forwarding and validate routing match.
- Inbound webhook (`ElektrineWeb.HarakaWebhookController`): extract/validate first, then sanitize once before forwarding or storage.
- Render boundary (`elektrine_web`): sanitize HTML for display in iframe/UI contexts.

## License

MIT (see `../../LICENSE`).
