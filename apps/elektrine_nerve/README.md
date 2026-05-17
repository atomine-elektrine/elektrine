# Elektrine Nerve

Standalone umbrella app for Nerve domain logic.

## What lives here

- `Elektrine.Nerve` context
- `Elektrine.Nerve.NerveEntry` schema
- Domain tests for create/list/retrieve/delete flows
- Nerve LiveView, external API controller, and route macros under `ElektrineNerveWeb.*`

## Current Integration

- Uses `Elektrine.Repo` for persistence.
- Requires explicit nerve setup with a browser-encrypted verifier payload.
- Stores browser-encrypted ciphertext envelopes and never decrypts secrets server-side.
- `elektrine_web` imports route macros from this app instead of owning the nerve UI/API modules directly.
- The deploy scripts use the module id `nerve`.

## If This Splits Out Later

1. Replace `Elektrine.Repo` references with a configurable repo behaviour.
2. Move migration ownership into this app/repo package.
3. Replace direct `Elektrine.Accounts.User` coupling with a generic owner schema key.
4. Publish as a library with install and migration docs.

## License

AGPL-3.0-only (see `../../LICENSE`).
