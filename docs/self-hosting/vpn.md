# VPN Self-hosting

The VPN module is optional and should stay out of the default self-host path.

To enable it:

1. add `vpn` to `ELEKTRINE_ENABLED_MODULES`
2. fill in the VPN section already present in `.env.example` / `.env.production`
3. set `VPN_FLEET_REGISTRATION_KEY`

If you are not running a WireGuard fleet, leave the module disabled.
