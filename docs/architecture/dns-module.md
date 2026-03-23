# DNS Module

Elektrine DNS is a first-party authoritative DNS service implemented inside the umbrella.

Initial architecture:

- `apps/elektrine_dns` contains the DNS runtime, schemas, and LiveView surface
- the main `elektrine` release includes the DNS module for account/UI access
- a separate `elektrine_dns` release is reserved for the dedicated authoritative runtime
- zone and record state live in Postgres
- `Elektrine.DNS.ZoneCache` mirrors authoritative zones into ETS for fast lookups
- `Elektrine.DNS.Authority` is the starting point for the novel UDP/TCP authority process

External API scopes:

- `read:dns` lists zones and records
- `write:dns` creates, updates, verifies, and deletes zones and records

Current PAT endpoints:

- `GET /api/ext/v1/dns/zones`
- `GET /api/ext/v1/dns/zones/:id`
- `POST /api/ext/v1/dns/zones`
- `PUT /api/ext/v1/dns/zones/:id`
- `DELETE /api/ext/v1/dns/zones/:id`
- `POST /api/ext/v1/dns/zones/:id/verify`
- `POST /api/ext/v1/dns/zones/:zone_id/records`
- `PUT /api/ext/v1/dns/zones/:zone_id/records/:id`
- `DELETE /api/ext/v1/dns/zones/:zone_id/records/:id`

Docker deployment notes:

- main app/web stays on the standard `elektrine` release
- authoritative DNS runs through the `dns` Compose profile
- the DNS service builds the `elektrine_dns` release from the same Dockerfile
- default internal listening ports are UDP/TCP `5300`, mapped to host port `53`
