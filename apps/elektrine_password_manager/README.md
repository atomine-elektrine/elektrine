# Elektrine Password Manager

Standalone umbrella app for encrypted password-vault domain logic.

## Included

- `Elektrine.PasswordManager` context
- `Elektrine.PasswordManager.VaultEntry` schema
- Domain tests for create/list/reveal/delete flows

## Current integration

- Uses `Elektrine.Repo` for persistence.
- Uses `Elektrine.Encryption` for at-rest encryption.
- Consumed by `elektrine_web` for Settings UI and LiveViews.

## Path to external open-source extraction

1. Replace `Elektrine.Repo` references with a configurable repo behaviour.
2. Move migration ownership into this app/repo package.
3. Replace direct `Elektrine.Accounts.User` coupling with a generic owner schema key.
4. Publish as a library with install and migration docs.

## License

MIT (see `../../LICENSE`).
