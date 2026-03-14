# Elektrine Chat

Chat application boundary for the Elektrine umbrella.

## What this app owns

- Chat-facing API surface used by web/mobile chat clients
- Chat migration boundary away from the core `elektrine` app
- Extracted Phoenix chat surface:
  `/chat` LiveView, chat JSON APIs, PAT chat API, and admin Arblarg chat views

## Notes

- During migration, this app delegates behavior to `Elektrine.Messaging`.
- Reuses shared layouts/components from `elektrine_web` as the host shell.
- Call sites should prefer `ElektrineChat` instead of `Elektrine.Messaging`.

## License

AGPL-3.0-only (see `../../LICENSE`).
