# Elektrine Core

Core domain app for the Elektrine umbrella.

## What lives here

- Accounts, auth, and privacy settings
- Shared persistence and runtime services consumed by the other umbrella apps
- ActivityPub domain logic and delivery workers
- Calendar, contacts, profiles, notifications, and uploads
- Module selection and shared platform wiring

This app still carries a large share of the cross-product domain code. Other
apps depend on it for `Elektrine.Repo`, shared schemas, and shared services.

## Notes

- `elektrine` is the main dependency for the feature apps.
- Migrations for core domain tables live under `apps/elektrine/priv/repo/migrations`.
- Chat call sites should prefer `ElektrineChat` over reaching into `Elektrine.Messaging` directly.

## License

AGPL-3.0-only (see `../../LICENSE`).
