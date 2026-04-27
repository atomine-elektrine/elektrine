# Elektrine VPN

WireGuard VPN app for the Elektrine umbrella.

## What lives here

- VPN server records and self-host/fleet registration data
- Per-user WireGuard config lifecycle and key handling
- Connection logging, stats aggregation, and health monitoring
- Native WireGuard reconciliation for the Docker-managed self-host node
- VPN Phoenix routes: user LiveView, policy page, admin screens, authenticated API, and fleet API

## Notes

- Depends on shared repo/runtime services from `elektrine`.
- Uses shared layouts and components from `elektrine_web`.
- Main domain API is `Elektrine.VPN`.
- Router-mounted modules in this app still use `ElektrineWeb.*`; shared web helpers live in `ElektrineVPNWeb`.

## License

AGPL-3.0-only (see `../../LICENSE`).
