# Elektrine DNS

Managed DNS app for the Elektrine umbrella.

## What lives here

- `Elektrine.DNS` context for zones, records, service configs, verification, and query stats
- authoritative UDP and TCP DNS servers
- optional recursive resolution path and cache
- DNS LiveView surface and PAT-backed DNS API routes
- DNS-specific generators for web, mail, VPN, TURN, and Bluesky records

## Notes

- Depends on shared repo/runtime services from `elektrine`.
- Reuses the Phoenix host app from `elektrine_web` for routing and shared layout concerns.
- The Docker `dns` profile runs the dedicated DNS service for authoritative queries.

## License

AGPL-3.0-only (see `../../LICENSE`).
