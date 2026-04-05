# Elektrine Chat

Chat application boundary for the Elektrine umbrella.

## What lives here

- Chat-facing API surface used by web/mobile chat clients
- Chat LiveView surface, chat JSON APIs, PAT chat API, and admin Arblarg chat views
- Chat-specific components and web helpers in `ElektrineChatWeb.*` and `ElektrineWeb.*`

## Notes

- The public facade is `ElektrineChat`.
- Domain calls still delegate to `Elektrine.Messaging` today.
- Reuses shared layouts/components from `elektrine_web` as the host shell.
- Router-mounted modules in this app still use the shared `ElektrineWeb.*` namespace where that keeps route integration simple.

## License

AGPL-3.0-only (see `../../LICENSE`).
