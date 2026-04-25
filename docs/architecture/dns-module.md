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
- `POST /api/ext/v1/dns/zones/:id/services/:service/apply`
- `DELETE /api/ext/v1/dns/zones/:id/services/:service`
- `POST /api/ext/v1/dns/zones/:zone_id/records`
- `PUT /api/ext/v1/dns/zones/:zone_id/records/:id`
- `DELETE /api/ext/v1/dns/zones/:zone_id/records/:id`

Internal endpoints:

- `POST /_edge/acme/dns/v1/txt` creates `_acme-challenge.*` TXT records for DNS-01
- `DELETE /_edge/acme/dns/v1/txt` removes matching DNS-01 TXT records
- `GET /_edge/dns/v1/health` reports authority/cache health for internal deploy checks

Docker deployment notes:

- main app/web stays on the standard `elektrine` release
- authoritative DNS runs through the `dns` Compose profile
- the DNS service reuses the main `elektrine` release from the same Dockerfile and disables unrelated runtime components
- default internal listening ports are UDP/TCP `5300`, mapped to host port `53`
- the Docker `dns` profile enables recursive mode by default for local/private clients with `DNS_RECURSIVE_ENABLED=true`

Recursive mode notes:

- set `:dns, recursive_enabled: true` to resolve recursion-desired queries that are outside hosted zones
- recursion starts from the configured `recursive_root_hints` list instead of depending on a public forwarder by default
- recursive answers are cached in ETS with positive and negative TTL-based entries
- recursion is restricted to private/local CIDRs by default via `recursive_allow_cidrs`

Authoritative behavior:

- hosted-zone answers are authoritative regardless of the query's recursion-desired bit
- unsupported `ANY` queries are refused
- query resolution emits `[:elektrine, :dns, :query]` telemetry with zone, qname, qtype, rcode, and authoritative metadata

Record validation notes:

- `CNAME` records cannot coexist with other record types at the same owner name
- apex `CNAME` remains rejected; use `ALIAS` for apex flattening
- wildcard labels must be the full left-most label, such as `*.example.com`
- `MX`, `NS`, `SRV`, and `CNAME` targets must be hostname-shaped values, not IP literals or URLs
- `A` and `AAAA` content is validated as IPv4 and IPv6 respectively before records are saved
- long TXT values are split into DNS character strings during packet encoding

Not implemented yet:

- DNSSEC signing and DS rollover automation
- AXFR/IXFR secondary DNS with TSIG

Those are intentionally deferred because they need operator UX and failure-mode design, not just packet support.
