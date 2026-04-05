# DNS Module

Elektrine DNS is a first-party DNS service implemented inside the umbrella.

Current layout:

- `apps/elektrine_dns` contains the DNS runtime, schemas, and LiveView surface
- the main `elektrine` release includes the DNS module for account/UI access
- the dedicated DNS container runs the `elektrine_dns` release for authoritative service
- zone and record state live in Postgres
- `Elektrine.DNS.ZoneCache` mirrors authoritative zones into ETS for fast lookups
- `Elektrine.DNS.Authority` fronts the UDP/TCP authority process
- `Elektrine.DNS.Recursive` provides an optional recursive forwarding path for non-authoritative queries

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
- the DNS service reuses the main `elektrine` release from the same Dockerfile and disables unrelated runtime components
- default internal listening ports are UDP/TCP `5300`, mapped to host port `53`
- the Docker `dns` profile enables recursive mode by default with `DNS_RECURSIVE_ENABLED=true`

Recursive mode notes:

- set `:dns, recursive_enabled: true` to resolve recursion-desired queries that are outside hosted zones
- recursion starts from the configured `recursive_root_hints` list instead of depending on a public forwarder by default
- recursive answers are cached in ETS with positive and negative TTL-based entries
- recursion is restricted to private/local CIDRs by default via `recursive_allow_cidrs`
