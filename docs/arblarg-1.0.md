# Arblarg 1.0 Specification

## Status

This document is the normative specification for Arblarg 1.0.

Arblarg 1.0 is a stable wire contract. `1.0` changes MUST remain backward
compatible. Additive changes are allowed. Breaking changes require a new
protocol version.

Canonical protocol naming:

- Human name: `Arblarg`
- Wire protocol token: `arblarg`
- Protocol id: `arblarg`
- Default protocol label: `arblarg/1.0`

Repository artifacts under `external/arblarg/` are generated publication
artifacts and test vectors. They are not normative by themselves. If an
artifact disagrees with this specification, the artifact is wrong and MUST be
regenerated.

## 1. Scope

Arblarg is a server-authoritative federated chat protocol optimized for:

- ordered per-stream event delivery
- idempotent retries
- compact ref-based payloads on the hot path
- signed HTTP federation between domains
- optional long-lived websocket sessions between domains
- batch transport
- stream replay catch-up
- signed snapshot bootstrap with governance state and stream checkpoints
- an ephemeral lane for presence and typing

Arblarg is intentionally not:

- a multi-writer room DAG
- a room-state conflict-resolution protocol
- an E2EE device graph protocol

Each durable stream has one authoritative origin domain.

## 2. Terminology

- `origin_domain`: domain that authored the event or snapshot
- `stream_id`: ordered durable log scope
- `sequence`: monotonic per-stream cursor
- `event_id`: unique event identifier
- `idempotency_key`: retry-stable semantic dedupe key
- `federation_id`: globally scoped object identifier, normally an absolute URL
- `actor`: canonical user identity object carried in payloads
- `snapshot`: coarse bootstrap export containing objects and stream checkpoints

The keywords `MUST`, `SHOULD`, and `MAY` are used in the RFC sense.

## 3. Discovery And Bootstrap

### 3.1 Canonical discovery endpoints

Federating domains SHOULD publish:

- `GET /.well-known/arblarg`
- `GET /.well-known/arblarg/{version}`

The current version string is `1.0`.

### 3.2 Discovery document

The discovery document is JSON.

Required fields:

- `protocol = "arblarg"`
- `protocol_id = "arblarg"`
- `default_protocol_version = "1.0"`
- `domain`
- `identity`
- `endpoints`
- `signature`

Optional descriptive metadata:

- `protocol_versions = ["1.0"]`
- `protocol_labels = ["arblarg/1.0"]`
- `default_protocol_label = "arblarg/1.0"`
- `version = 1`
- `features`
- `limits`
- `transport_profiles`
- `relay_transport`

`identity` has this shape:

```json
{
  "algorithm": "ed25519",
  "current_key_id": "k1",
  "keys": [
    {
      "id": "k1",
      "algorithm": "ed25519",
      "public_key": "<base64url-without-padding>"
    }
  ]
}
```

`signature` has this shape:

```json
{
  "algorithm": "ed25519",
  "key_id": "k1",
  "value": "<base64url-without-padding>"
}
```

The discovery signature is computed over `canonical_json(document_without_signature)`.

Receivers MUST ignore unknown discovery-document fields.

Receivers SHOULD treat these fields as descriptive metadata, not identity-bearing
material:

- `protocol_versions`
- `protocol_labels`
- `default_protocol_label`
- `version`
- `features`
- `limits`
- `transport_profiles`
- `relay_transport`

### 3.3 Discovery endpoints map

`endpoints` SHOULD include:

- `well_known`
- `well_known_versioned`
- `profiles`
- `events`
- `events_batch`
- `ephemeral`
- `sync`
- `stream_events`
- `session_websocket`
- `public_servers`
- `snapshot_template`
- `schema_template`
- `schemas`

### 3.4 Feature flags

Current 1.0 features include:

- `relay_transport`
- `batched_event_delivery`
- `stream_catch_up`
- `compact_event_refs`
- `binary_event_batches`
- `read_cursors`
- `ephemeral_lane`
- `structured_error_codes`
- `origin_owned_identifiers`
- `signed_snapshots`
- `snapshot_governance`
- `session_transport`
- `dynamic_peer_discovery`
- `open_domain_bootstrap`
- `key_continuity_tracking`
- `key_continuity_quarantine`
- `discovery_document_signature`
- `wire_contract_frozen`

If `limits` is present, senders MUST respect:

- `max_batch_events`
- `max_ephemeral_items`
- `max_snapshot_channels`
- `max_snapshot_messages`
- `max_snapshot_governance_entries`
- `max_stream_replay_limit`
- `max_session_inflight_batches`
- `max_session_inflight_events`

If `transport_profiles` is present, senders SHOULD follow the peer's
`preferred_order` and `fallback_order`.

### 3.5 Bootstrap algorithm

For unknown domains, an implementation SHOULD:

1. Fetch `https://{domain}/.well-known/arblarg`.
2. If unavailable, it MAY try the versioned Arblarg path.
3. Validate `protocol`, `protocol_id`, `default_protocol_version`, and
   `domain`.
4. Validate the discovery signature using a key in `identity.keys`.
5. Require discovery endpoint URLs to remain on the claimed domain or one of its
   subdomains.
6. Cache endpoint URLs and identity keys.
7. Compute a continuity fingerprint from `identity.current_key_id` and
   `identity.keys`.
8. Compare the new fingerprint to the previously cached fingerprint.

Trust-state semantics:

- `trusted`: fingerprint unchanged
- `rotated`: fingerprint changed, but at least one public key overlaps
- `replaced`: fingerprint changed with no overlapping keys

Required operator behavior:

- `trusted`: normal traffic is allowed
- `rotated`: traffic MAY continue, but operators SHOULD be warned
- `replaced`: traffic MUST be quarantined until operator approval

This is an HTTPS bootstrap model with signed discovery, domain-owned endpoint
validation, and key continuity tracking. Initial discovery trust is not pure
TOFU: first contact MUST be backed by either:

- a configured operator trust anchor for the remote domain, or
- a matching DNS TXT proof published under `_arblarg.<domain>` or
  `_arblarg-bootstrap.<domain>`

DNS proof requirements:

- the TXT record MUST match the discovery identity fingerprint or a discovery
  public key
- the TXT record MUST be either operator-authenticated out of band or bound to
  the current HTTPS identity with `tls_certificate_sha256={base64url_sha256}`
- receivers MUST fail bootstrap if the TXT proof exists but does not satisfy the
  authentication or TLS-binding requirement

If neither proof exists, discovery MUST fail.

## 4. Transport

### 4.1 Base transport

Arblarg uses signed HTTP requests. HTTPS is required in normal operation.

### 4.2 Content types

JSON is always valid.

The 1.0 fast path also supports:

- `application/arblarg-batch+cbor`
- `application/arblarg-ephemeral+cbor`

Single-event requests and snapshots are JSON in Arblarg 1.0.

### 4.3 Session transport profile

Peers MAY expose a long-lived websocket session at the discovery
`session_websocket` endpoint.

The current 1.0 session profile uses:

- websocket transport
- transport-neutral stream-session frames
- `GET /federation/messaging/session`
- the same request-signature fields used by HTTP federation, carried as
  `x-arblarg-*` HTTP headers on the upgrade request
- optional websocket subprotocol `arblarg.session.v1`
- JSON text or CBOR binary frames

The server MAY send an initial `hello` frame advertising limits and supported
encodings.

The 1.0 session profile supports:

- multiplexed in-flight deliveries across independent streams
- sender-enforced ordered delivery within a single stream
- `ack_window` flow control using `max_inflight_batches` and
  `max_inflight_events`
- durable delivery ops and control ops on the same long-lived session

### 4.4 Required request headers

Every signed federation request MUST include:

- `x-arblarg-domain`
- `x-arblarg-key-id`
- `x-arblarg-timestamp`
- `x-arblarg-content-digest`
- `x-arblarg-request-id`
- `x-arblarg-signature-algorithm`
- `x-arblarg-signature`

`x-arblarg-signature-algorithm` MUST be `ed25519`.

### 4.5 Body digest

The body digest is:

- SHA-256 of the raw request body bytes
- Base64URL encoded
- unpadded

For bodyless requests, the digest is computed over the empty string.

### 4.6 Request signature canonical string

The request signature payload is the UTF-8 string:

```text
lower(domain)
lower(method)
canonical_path(request_path)
trim(query_string)
timestamp
canonical_content_digest
request_id
```

Rules:

- `canonical_path(nil)` is `/`
- a non-empty path without a leading slash gets one prepended
- `query_string` is the raw trimmed query string
- the content digest is the provided digest, or the digest of the empty string

The signature is Ed25519 over the canonical string bytes. The signature value is
Base64URL encoded without padding.

### 4.7 Replay protection

Receivers MUST reject:

- timestamps outside the allowed skew window
- replayed signed requests

Arblarg 1.0 clock skew tolerance is `300` seconds.

## 5. Event Envelope

Durable events are carried in an envelope with these required fields:

- `protocol = "arblarg"`
- `protocol_id = "arblarg"`
- `protocol_version = "1.0"`
- `event_type`
- `event_id`
- `origin_domain`
- `stream_id`
- `sequence`
- `sent_at`
- `idempotency_key`
- `payload`
- `signature`

Current 1.0 emitters also include:

- `protocol_label = "arblarg/1.0"`

### 5.1 Event signature

Durable envelopes are signed independently from the HTTP request.

The canonical event signature payload is:

```text
arblarg
protocol_version
event_type
event_id
origin_domain
stream_id
sequence
sent_at
idempotency_key
canonical_json(payload)
```

### 5.2 Canonical JSON

`canonical_json` is defined as:

- object keys converted to strings
- object keys sorted lexicographically at every level
- arrays preserved in input order
- scalars encoded as normal JSON scalars
- no extra whitespace

### 5.3 Ordering and dedupe

Ordering is scoped by `(origin_domain, stream_id)`.

Sequence rules:

- the first event in a stream uses `sequence = 1`
- each new event increments by exactly `1`
- `sequence <= last_sequence` is stale or duplicate
- `sequence > last_sequence + 1` is a gap

Idempotency rules:

- senders MUST keep `idempotency_key` stable across semantic retries
- receivers MUST dedupe by `(origin_domain, idempotency_key)`

`event_id` rules:

- `event_id` MUST be unique within an origin domain
- receivers SHOULD treat repeated `(origin_domain, event_id)` as duplicates

## 6. Identifiers And Context

### 6.1 Federation ids

The 1.0 shape uses absolute URLs:

- server id: `https://{domain}/federation/messaging/servers/{server_id}`
- channel id: `https://{domain}/federation/messaging/channels/{channel_id}`
- message id: `https://{domain}/federation/messaging/messages/{message_id}`
- dm id: `https://{domain}/federation/messaging/dms/{conversation_id}`

Origin ownership rules:

- the authenticated `origin_domain` MUST own the host of every durable object id
- ownership includes the exact domain and any subdomain of that domain
- receivers MUST reject envelopes or snapshots that violate this rule

### 6.2 Stream ids

The current stream forms are:

- `server:{server_federation_id}`
- `channel:{channel_federation_id}`
- `dm:{dm_federation_id}`

The embedded federation id inside a `stream_id` MUST also be owned by the
authenticated `origin_domain`.

### 6.3 Compact refs

Hot-path channel events SHOULD use refs instead of repeating full objects:

```json
{
  "refs": {
    "server_id": "https://example.net/federation/messaging/servers/1",
    "channel_id": "https://example.net/federation/messaging/channels/9"
  }
}
```

Receivers MUST accept both:

- full `server` and `channel` context objects
- compact `refs`

where the event type defines either form.

## 7. Canonical Actor Representation

Arblarg 1.0 requires a canonical actor object on every user-authored event.

Required actor fields:

- `uri`
- `username`
- `domain`
- `handle`

Common optional actor fields:

- `id`
- `display_name`
- `avatar_url`
- `key_id`

Required rules:

- `handle` MUST be `username@domain`
- `uri` MUST be a stable absolute `http` or `https` actor URI
- the host of `uri` MUST be owned by the authenticated `origin_domain`
- `id`, if present, SHOULD equal `uri`
- actor identity equality MUST use `uri`, not `handle`
- `handle` is a presentation alias and MUST NOT be used as the primary actor key
- receivers MUST ignore unknown actor fields
- receivers MUST reject user-authored events whose actor domain does not match
  the authenticated `origin_domain`
- `key_id` MAY be omitted; when omitted, actor identity is server-asserted by
  the authenticated origin domain

Arblarg 1.0 is server-authoritative for user identity. It does not define
per-actor signature verification.

This origin-binding rule applies to:

- message authors
- reaction actors
- read-cursor actors
- membership, invite, and ban actors
- thread owners and archive actors
- presence and typing actors
- moderation actors
- DM senders

## 8. Core Durable Events

The mandatory core profile is `arblarg-core/1.0`.

### 8.1 `message.create`

Context:

- `server` and `channel`, or `refs`

Required payload fields:

- `message.id`
- `message.content`
- `message.sender`

Optional payload fields:

- `message.attachments`

If present, `message.attachments` is an array of structured attachment objects.
Each attachment includes:

- `id`
- `url`
- `mime_type`
- `authorization`
- `retention`

Common optional attachment fields:

- `byte_size`
- `sha256`
- `expires_at`
- `alt_text`
- `width`
- `height`
- `duration_ms`

Attachment semantics:

- `authorization = "public"` means the object is fetchable without additional
  origin credentials
- `authorization = "signed"` means access requires a signed URL or equivalent
  bearer capability minted by the origin
- `authorization = "origin-authenticated"` means the object requires origin
  server authentication
- `retention = "origin"` means the origin retains the canonical object
- `retention = "rehosted"` means the sender intentionally hosts a federated
  copy at the advertised URL
- `retention = "expiring"` means the attachment URL is expected to expire and
  `expires_at` SHOULD be present
- `media_urls` and `media_metadata` are not part of the Arblarg 1.0 wire
  contract

### 8.2 `message.update`

Same context rules as `message.create`.

Required payload fields:

- `message.id`
- `message.content`
- `message.sender`

`message.attachments`, when present, uses the same structured attachment shape
and semantics as `message.create`.

### 8.3 `message.delete`

Required payload fields:

- `message_id`

### 8.4 `reaction.add`

Required payload fields:

- `message_id`
- `reaction.emoji`
- `reaction.actor`

### 8.5 `reaction.remove`

Same shape as `reaction.add`.

### 8.6 `read.cursor`

Required payload fields:

- `actor`
- `read_through_message_id`
- `read_at`

Optional payload fields:

- `read_through_sequence`

`read.cursor` replaces per-message durable read receipts on the hot path.

### 8.7 `membership.upsert`

Required payload fields:

- `membership.actor`
- `membership.role`
- `membership.state`
- `membership.updated_at`

Allowed `membership.role` values:

- `owner`
- `admin`
- `moderator`
- `member`
- `readonly`

Allowed `membership.state` values:

- `active`
- `invited`
- `left`
- `banned`

### 8.8 `invite.upsert`

Required payload fields:

- `invite.actor`
- `invite.target`
- `invite.role`
- `invite.state`
- `invite.invited_at`
- `invite.updated_at`

Allowed `invite.state` values:

- `pending`
- `accepted`
- `declined`
- `revoked`

### 8.9 `ban.upsert`

Required payload fields:

- `ban.actor`
- `ban.target`
- `ban.state`
- `ban.banned_at`
- `ban.updated_at`

Allowed `ban.state` values:

- `active`
- `lifted`

Governance projection rules:

- these events are channel-scoped in Arblarg 1.0
- the event context channel, or `refs.channel_id`, identifies the governed room
- receivers maintain one effective membership projection per `(channel, actor_uri)`
- `membership.upsert` writes the effective role and state directly
- `invite.upsert` maps `pending -> invited`, `accepted -> active`, and
  `declined|revoked -> left`
- `ban.upsert` maps `active -> banned` and `lifted -> left`
- later applied governance events in the authoritative channel stream overwrite
  earlier projected state for the same actor

These governance events are authoritative because each stream has one origin.
Arblarg 1.0 does not define Matrix-style state resolution.

## 9. Extension Events

Canonical profile and schema metadata is published at:

- `GET /federation/messaging/arblarg/profiles`

Current extension URNs:

- `urn:arblarg:ext:bootstrap:1`
- `urn:arblarg:ext:roles:1`
- `urn:arblarg:ext:permissions:1`
- `urn:arblarg:ext:threads:1`
- `urn:arblarg:ext:presence:1`
- `urn:arblarg:ext:moderation:1`
- `urn:arblarg:ext:dm:1`
- `urn:arblarg:ext:voice:1`

Canonical event aliases are normalized by the SDK, for example:

- `server.upsert`
- `thread.upsert`
- `presence.update`
- `dm.message.create`

`urn:arblarg:ext:voice:1` is reserved in 1.0 and defines no event types.

## 10. Durable HTTP Endpoints

### 10.1 `POST /federation/messaging/events`

Request body:

- one signed durable event envelope

Success statuses:

- `200 { "status": "applied" }`
- `200 { "status": "duplicate" }`
- `200 { "status": "stale" }`
- `202 { "status": "recovered_via_stream" }`
- `202 { "status": "recovered_via_snapshot" }`

Recovery success semantics:

- a `202` recovery response means the receiver completed recovery and already
  retried the triggering event internally
- senders SHOULD treat either `202` status as terminal success for the original
  delivery attempt
- senders SHOULD NOT immediately resend the same event after a recovery success

Typical failures:

- `400` invalid payload, protocol, version, signature, actor binding, or
  snapshot checkpoint data
- `401` invalid request signature or replay
- `409` sequence gap or origin conflict
- `422` unsupported event type or semantic apply failure

### 10.2 `POST /federation/messaging/events/batch`

Accepted request body forms:

- object with `events`
- bare array of event envelopes

Success response body:

- `version = 1`
- `batch_id`
- `event_count`
- `counts`
- `error_counts`
- `results`

Each durable batch result entry includes:

- `event_id`
- `status`
- `code` when `status = "error"`

Batch result `status` values are:

- `applied`
- `duplicate`
- `stale`
- `recovered_via_stream`
- `recovered_via_snapshot`
- `error`

When CBOR is used, the response content type MUST be
`application/arblarg-batch+cbor`.

### 10.3 `POST /federation/messaging/sync`

Imports a coarse server snapshot.

Snapshot request fields:

- `version = 1`
- `origin_domain`
- `server`
- `channels`
- `messages`
- `governance`
- `stream_positions`
- `signature`

Each `stream_positions` entry includes:

- `stream_id`
- `last_sequence`

`governance` includes:

- `memberships`
- `invites`
- `bans`

### 10.4 `GET /federation/messaging/servers/{server_id}/snapshot`

Exports a local snapshot with:

- `version`
- `origin_domain`
- `server`
- `channels`
- `messages`
- `governance`
- `stream_positions`
- `signature`

Snapshots are bootstrap payloads. They are not durable event envelopes, but they
MUST be signed over `canonical_json(snapshot_without_signature)`.

### 10.5 `GET /federation/messaging/streams/events`

Query parameters:

- `stream_id`
- `after_sequence`
- `limit`

Success response body:

- `version = 1`
- `stream_id`
- `after_sequence`
- `next_after_sequence`
- `last_sequence`
- `has_more`
- `events`

`events` is an ordered list of signed durable event envelopes.

This endpoint is the normative gap-recovery path.

### 10.6 Session websocket operations

Server `hello` frame:

- `op = "hello"`
- `protocol = "arblarg"`
- `transport = "session_websocket"`
- `session_version = 1`
- `mode = "stream_session"`
- `encodings`
- `flow_control`

Client delivery frames use:

- `op`
- `delivery_id`
- `payload`

Client control frames use:

- `op`
- `request_id`
- `payload`

Server ack frames use:

- `op = "ack"`
- `delivery_id`
- `status`
- `payload` for success
- `code` for failure

Server response frames use:

- `op = "response"`
- `request_id`
- `status`
- `payload` for success
- `code` for failure

Supported delivery `op` values are:

- `stream_batch`
- `deliver_ephemeral`

Supported control `op` values are:

- `events_batch`
- `ephemeral_batch`
- `stream_events`
- `snapshot`
- `ping`

`stream_batch` payloads include:

- `version = 1`
- `delivery_id`
- `stream_id`
- `events`

`deliver_ephemeral` payloads include:

- `version = 1`
- `delivery_id`
- `items`

Ack payload bodies match the corresponding durable or ephemeral batch result
shapes. Control response payload bodies match the corresponding HTTP endpoint
shapes.

Within a single `stream_id`, senders MUST preserve delivery order. Independent
streams MAY be delivered concurrently up to the advertised flow-control window.

### 10.7 `GET /federation/messaging/servers/public`

This is a public server directory endpoint. Federating peers SHOULD key on
`federation_id`, not local integer ids.

## 11. Ephemeral Lane

### 11.1 Endpoint

- `POST /federation/messaging/ephemeral`

Accepted request body forms:

- object with `items`
- bare array of items

### 11.2 Item shape

Each item includes:

- `event_type`
- `origin_domain`
- `sent_at`
- `payload`

### 11.3 Allowed ephemeral event types

- `urn:arblarg:ext:presence:1#presence.update`
- `urn:arblarg:ext:presence:1#typing.start`
- `urn:arblarg:ext:presence:1#typing.stop`

### 11.4 Semantics

Ephemeral items:

- are not inserted into the durable ordered log
- are not replayed by `streams/events`
- are intended for coalesced soft-state updates

`typing.start` MAY include `ttl_ms`.

`presence.update` MAY include `presence.ttl_ms`.

Success response body:

- `version = 1`
- `batch_id`
- `event_count`
- `counts`
- `error_counts`
- `results`

Each ephemeral result entry includes:

- `event_type`
- `status`
- `code` when `status = "error"`

Ephemeral result `status` values are:

- `applied`
- `error`

When CBOR is used, the response content type MUST be
`application/arblarg-ephemeral+cbor`.

## 12. Recovery Rules

Receivers SHOULD recover gaps like this:

1. Detect `sequence > last_sequence + 1` for `(origin_domain, stream_id)`.
2. Fetch `GET /federation/messaging/streams/events`.
3. Apply replayed events in ascending order.
4. Retry the triggering event.
5. If replay is unavailable, fetch a snapshot and seed checkpoints from
   `stream_positions`.
6. Continue recovery from replay if additional events are still missing.

If a receiver returns `recovered_via_stream` or `recovered_via_snapshot`, the
triggering event has already been retried by the receiver as part of recovery.

Interoperability rules:

- stream replay is authoritative for ordered recovery
- snapshots are valid for bootstrap and coarse repair
- snapshot `stream_positions` seed local high-water marks
- snapshot `governance` seeds effective membership, invite, and ban state
- a snapshot without stream checkpoints is incomplete

## 13. Compatibility And Negotiation

Receivers:

- MUST ignore unknown object fields
- MUST reject unsupported `event_type` values
- MUST accept both refs and full context objects where defined

Senders:

- SHOULD prefer compact refs on hot-path events
- SHOULD batch when a peer advertises `batched_event_delivery`
- SHOULD use CBOR when a peer advertises `binary_event_batches`
- SHOULD use the ephemeral lane only when a peer advertises `ephemeral_lane`
- SHOULD follow `transport_profiles.preferred_order` when advertised
- MUST respect advertised batch and replay limits
- MUST fall back in `transport_profiles.fallback_order` when a preferred
  transport returns `404`, `406`, `410`, `415`, `426`, or `501`
- MUST fall back to JSON and durable paths when a peer does not advertise the
  fast path

## 14. Profiles, Schemas, And Conformance

Canonical endpoints:

- `GET /federation/messaging/arblarg/profiles`
- `GET /federation/messaging/arblarg/{version}/schemas/{name}`

Current profile ids:

- mandatory: `arblarg-core/1.0`
- optional: `arblarg-community/1.0`

Published JSON Schemas and test vectors in `external/arblarg/` are derived
artifacts. CI SHOULD verify that they match the live schema set.

## 15. Minimal Sender Checklist

An interoperable Arblarg 1.0 sender SHOULD:

1. Publish `/.well-known/arblarg`.
2. Publish Ed25519 discovery keys and a signed discovery document.
3. Sign every federation HTTP request.
4. Sign every durable event envelope.
5. Emit ordered sequences per `(origin_domain, stream_id)`.
6. Keep `idempotency_key` stable across retries.
7. Emit canonical actor objects on every user-authored event.
8. Support the core durable events.
9. Support stream replay.
10. Support snapshot import and export with `stream_positions`.
11. Support signed snapshots with `governance` and `stream_positions`.
12. Ignore unknown fields.
13. Prefer compact refs, batching, and the session transport when compatible.

## 16. Future Work

These items are intentionally outside Arblarg 1.0:

- HTTP/2 or HTTP/3 session transport profiles
- an E2EE device-key layer
- voice transport semantics

Those can be added as new compatible profiles or transport profiles without
changing the 1.0 durable event model.
