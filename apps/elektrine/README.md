# Elektrine Core

Core domain app for the Elektrine umbrella.

## What this app owns

- Accounts, auth, and privacy settings
- Shared persistence/runtime services consumed by other umbrella apps
- ActivityPub domain logic and delivery workers
- Calendar, contacts, profiles, notifications, and uploads
- Repo/runtime services used by other umbrella apps

Chat-facing app API now lives in `../elektrine_chat`.

## Notes

- `elektrine` is the main dependency for other umbrella apps.
- Migrations for core domain tables live under `apps/elektrine/priv/repo/migrations`.

## License

MIT (see `../../LICENSE`).
