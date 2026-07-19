FROM caddy:2.11.2-builder@sha256:1ecefa333507828a592aaecc68d5f62a993787057429c04e9b0438a65c980a30 AS builder

# Pinned commit of mholt/caddy-ratelimit (Jun 2026) for the edge_rate_limit
# snippet in the Caddyfiles. Bump deliberately alongside the caddy version.
RUN xcaddy build v2.11.2 \
	--with github.com/mholt/caddy-ratelimit@5625512f24f6f59d6f64fb3aafe5eecff0b286db

FROM caddy:2.11.2@sha256:25cdc846626b62d05f6b633b9b40c2c9f6ef89b515dc76133cefd920f7dbe562

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
