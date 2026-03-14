# Elektrine VPN

WireGuard VPN domain app for the Elektrine umbrella.

## What this app owns

- VPN server records and fleet registration data
- Per-user WireGuard config lifecycle and key handling
- Connection logging, stats aggregation, and health monitoring
- Extracted Phoenix surfaces for VPN:
  user LiveView, policy page, admin screens, authenticated API, and fleet API

## Notes

- Depends on shared repo/runtime services from `elektrine`.
- Reuses shared layouts/components from `elektrine_web` as the host shell.
- Main domain API surface is `Elektrine.VPN`.

## License

AGPL-3.0-only (see `../../LICENSE`).
