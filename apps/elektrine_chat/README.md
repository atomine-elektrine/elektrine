# Elektrine Chat

Chat application boundary for the Elektrine umbrella.

## What this app owns

- Chat-facing API surface used by web/mobile chat clients
- Chat migration boundary away from the core `elektrine` app

## Notes

- During migration, this app delegates behavior to `Elektrine.Messaging`.
- Call sites should prefer `ElektrineChat` instead of `Elektrine.Messaging`.

## License

MIT (see `../../LICENSE`).
