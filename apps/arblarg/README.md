# Arblarg

Chat application boundary for the Elektrine umbrella.

## What lives here

- Chat APIs used by web and mobile clients
- Chat LiveViews, JSON APIs, PAT APIs, and admin Arblarg views
- Chat-specific components and web helpers in `ArblargWeb.*` and `ElektrineWeb.*`

## Notes

- The public facade is `Arblarg`.
- Domain calls still delegate to `Elektrine.Messaging` today.
- Uses shared layouts and components from `elektrine_web`.
- Router-mounted modules in this app still use the shared `ElektrineWeb.*` namespace where that keeps route integration simple.

## License

AGPL-3.0-only (see `../../LICENSE`).
