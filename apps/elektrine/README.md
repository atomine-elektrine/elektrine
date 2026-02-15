# Elektrine Core

Core domain app for the Elektrine umbrella.

## What this app owns

- Accounts, auth, and privacy settings
- Messaging/chat domain models and federation runtime
- ActivityPub domain logic and delivery workers
- Calendar, contacts, profiles, notifications, and uploads
- Repo/runtime services used by other umbrella apps

## Notes

- `elektrine` is the main dependency for other umbrella apps.
- Migrations for core domain tables live under `apps/elektrine/priv/repo/migrations`.

## License

MIT (see `../../LICENSE`).
