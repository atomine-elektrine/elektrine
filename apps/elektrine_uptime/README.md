# Elektrine Uptime

Uptime-monitor app for the Elektrine umbrella.

## What lives here

- User-owned uptime monitors (HTTP/TCP/ping checks)
- Append-only check history and incident records
- SSRF-safe check targeting (validated through `Elektrine.Security.URLValidator`)
- Uptime Phoenix routes: user LiveView dashboard

## Notes

- Depends on shared repo/runtime services from `elektrine`.
- Uses shared layouts and components from `elektrine_web`.
- Main domain API is `Elektrine.Uptime`.
- Router-mounted modules in this app still use `ElektrineWeb.*`; shared web helpers live in `ElektrineUptimeWeb`.

## License

AGPL-3.0-only (see `../../LICENSE`).
