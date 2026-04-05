# Elektrine Password Manager

Standalone umbrella app for password-vault domain logic.

## What lives here

- `Elektrine.PasswordManager` context
- `Elektrine.PasswordManager.VaultEntry` schema
- Domain tests for create/list/retrieve/delete flows
- Vault LiveView, external API controller, and route macros under `ElektrinePasswordManagerWeb.*`

## Current integration

- Uses `Elektrine.Repo` for persistence.
- Requires explicit vault setup with a browser-encrypted verifier payload.
- Stores browser-encrypted ciphertext envelopes and never decrypts secrets server-side.
- `elektrine_web` imports route macros from this app instead of owning the vault UI/API modules directly.
- The deploy scripts use the module id `vault`; `password-manager` and `password_manager` are accepted aliases.

## Path to external open-source extraction

1. Replace `Elektrine.Repo` references with a configurable repo behaviour.
2. Move migration ownership into this app/repo package.
3. Replace direct `Elektrine.Accounts.User` coupling with a generic owner schema key.
4. Publish as a library with install and migration docs.

## License

AGPL-3.0-only (see `../../LICENSE`).
