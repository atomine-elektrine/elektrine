# Arblarg 1.0 Specification

## Status

This document defines the current normative Arblarg 1.0 wire contract.

Arblarg 1.0 is a stable protocol version:

- `protocol = "arblarg"`
- `protocol_id = "arblarg"`
- `default_protocol_version = "1.0"`
- `protocol_label = "arblarg/1.0"`

Breaking wire changes require a new protocol version. Additive changes are
allowed inside `1.0` only when they remain backward compatible.

Arblarg 1.0 is specified by:

- this document for semantics, authorization, and interoperability rules
- the JSON schemas under `external/arblarg/schemas/v1/` for payload shape
- the discovery and profiles documents exposed by an implementation

If prose and generated artifacts disagree, this document is normative for
semantics and the JSON schemas are normative for field shape.

## 1. Overview

Arblarg is a federated, Discord-shaped chat protocol built around signed events,
ordered room streams, explicit recovery, and room-scoped replication.

Arblarg 1.0 is optimized for:

- domain-to-domain federation over signed HTTP
- ordered durable event delivery with idempotent retries
- compact refs on the hot path
- optional long-lived websocket sessions between domains
- explicit replay and snapshot recovery
- peer-filtered bootstrap and visibility-aware fanout
- ephemeral presence and typing

Arblarg 1.0 is intentionally not:

- a Matrix-style state DAG
- a general-purpose XML messaging substrate
- an end-to-end encrypted device protocol
- a media transport for voice or video

Arblarg's product model is:

- `domain`: trust, signing, and transport authority
- `server`: user-facing community container hosted by a domain
- `channel` or `room`: the participation unit inside a server
- `actor`: canonical user identity carried in event payloads

A domain MAY host multiple Arblarg servers. A server is not the same thing as a
domain.

## 2. Core Model

### 2.1 Domains, servers, rooms, and mirrors

Every event is authenticated by a federating domain. A server and its rooms are
protocol objects hosted under that domain.

Remote state is stored locally as a mirror:

- a local mirror is a projection of remote server and room state
- a mirror is created or repaired by replay and snapshot import
- a mirror is not authoritative for objects hosted elsewhere

### 2.2 Streams and ordering

Durable ordering is scoped by `(origin_domain, stream_id)`.

`stream_id` values:

- `server:{server_id}`
- `channel:{channel_id}`
- `dm:{dm_id}`

Rules:

- `sequence` is monotonic per `(origin_domain, stream_id)`
- `idempotency_key` is retry-stable per semantic event
- receivers MUST deduplicate by `(origin_domain, idempotency_key)`
- receivers MUST track high-water marks per `(origin_domain, stream_id)`

Arblarg does not define a full state DAG. Receivers accept authorized signed
events and maintain latest-state projections.

### 2.3 Multi-origin rooms

Arblarg 1.0 supports direct multi-origin room participation.

For room participation traffic:

- `message.create`
- `message.update`
- `message.delete`
- `reaction.add`
- `reaction.remove`
- `read.cursor`
- `membership.upsert`
- `typing.start`
- `typing.stop`
- room-scoped `presence.update`

the acting domain MUST be allowed to author events for its own actors inside a
room hosted by another domain.

The room is still identified by a single authoritative `channel_id`, but
durable ordering is per `(origin_domain, stream_id)`, not per room globally.

### 2.4 Shared room governance

Arblarg 1.0 also supports shared room governance events:

- `invite.upsert`
- `ban.upsert`
- `role.upsert`
- `role.assignment.upsert`
- `permission.overwrite.upsert`
- `thread.upsert`
- `thread.archive`
- `moderation.action.recorded`

These events are room-scoped and multi-origin, but they are not a DAG. Receivers
project latest accepted state per governed object key.

Governance authorization is based on effective room permissions, not just the
sender homeserver.

### 2.5 Built-in roles and permissions

The default interoperable permission vocabulary is:

- `read_messages`
- `send_messages`
- `invite_members`
- `manage_moderation`
- `manage_roles`
- `manage_permissions`

Built-in interoperable roles are:

- `owner`
- `admin`
- `moderator`
- `member`
- `readonly`

Implementations MAY add additional permission strings, but unsupported tokens
are only synchronized metadata unless a receiver understands them.

## 3. Identifiers and actor rules

### 3.1 Federation identifiers

Arblarg federation identifiers SHOULD be absolute HTTPS URLs.

Examples:

- server id: `https://example.com/_arblarg/servers/42`
- channel id: `https://example.com/_arblarg/channels/7`
- message id: `https://example.com/_arblarg/messages/9001`
- dm id: `https://example.com/_arblarg/dms/3`

### 3.2 Origin ownership

Actor-bearing and actor-authored identifiers MUST be origin-owned by the event
`origin_domain`.

That means:

- actor URIs MUST resolve to the sender domain
- actor-authored object ids such as message ids MUST resolve to the sender
  domain
- room context ids do not have to resolve to the sender domain in a multi-origin
  room event

Room context ids identify the governed room authority. Actor-authored ids
identify the sender's objects.

### 3.3 Compact refs

Room and DM events MAY carry compact refs:

```json
{
  "refs": {
    "server_id": "https://authority.example/_arblarg/servers/1",
    "channel_id": "https://authority.example/_arblarg/channels/2"
  }
}
```

Rules:

- if both object blocks and refs are present, they MUST agree
- receivers MUST treat refs and expanded object ids as the same context
- compact refs are preferred on hot-path delivery

### 3.4 Canonical actor representation

Actor payloads MUST include:

- `uri`
- `username`
- `domain`
- `handle`

Optional fields:

- `id`
- `display_name`
- `avatar_url`
- `key_id`

Actor identity equality is by `uri`, not by `handle`.

## 4. Discovery, profiles, and trust

### 4.1 Discovery endpoints

Federating domains SHOULD publish:

- `GET /.well-known/_arblarg`
- `GET /.well-known/_arblarg/{version}`

The current version string is `1.0`.

### 4.2 Discovery document

The discovery document is signed JSON and SHOULD include:

- `protocol`
- `protocol_id`
- `default_protocol_version`
- `domain`
- `identity`
- `endpoints`
- `signature`

Recommended optional fields:

- `protocol_versions`
- `protocol_labels`
- `default_protocol_label`
- `version`
- `features`
- `limits`
- `transport_profiles`
- `relay_transport`

`identity.keys[].public_key` MUST be base64url public-key material. Invalid
public keys MUST be rejected.

### 4.3 Profiles document

Implementations SHOULD expose:

- `GET /_arblarg/profiles`

The profiles document advertises:

- compatibility claims
- extension registry
- supported event types
- transport profiles
- feature flags
- schema URLs
- conformance metadata

Senders MUST use discovery plus profiles data for capability negotiation.

### 4.4 Required discovery endpoints map

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

### 4.5 Trust and key continuity

Discovery key continuity states are:

- `trusted`
- `rotated`
- `replaced`

Rules:

- `trusted`: fingerprint unchanged
- `rotated`: fingerprint changed with overlapping key material
- `replaced`: fingerprint changed without overlap
- implementations SHOULD quarantine `replaced` peers for incoming traffic until
  explicitly trusted again
- refreshed discovery state MUST still pass trust policy checks before new keys
  are accepted

## 5. Transport and request security

### 5.1 Base transport

Arblarg uses HTTPS by default.

Primary durable transport endpoints:

- `POST /_arblarg/events`
- `POST /_arblarg/events/batch`
- `POST /_arblarg/sync`
- `GET /_arblarg/streams/events`
- `GET /_arblarg/servers/{server_id}/snapshot`

Ephemeral transport endpoint:

- `POST /_arblarg/ephemeral`

Optional session transport:

- websocket at `/_arblarg/session`
- subprotocol `arblarg.session.v1`

### 5.2 Content types

Arblarg 1.0 uses JSON for:

- single durable events
- snapshot transport
- ephemeral batches

Batch transport MAY additionally offer CBOR or other encodings when profiles
advertise them.

### 5.3 Required request headers

Signed federation requests use:

- `x-arblarg-domain`
- `x-arblarg-key-id`
- `x-arblarg-timestamp`
- `x-arblarg-content-digest`
- `x-arblarg-request-id`
- `x-arblarg-signature-algorithm`
- `x-arblarg-signature`

### 5.4 Body digest and signature string

The request body digest is computed over the raw request body.

The canonical request signature string MUST bind:

- domain
- method
- request path
- query string
- timestamp
- content digest
- request id

### 5.5 Replay protection

Receivers MUST reject request replays using at least:

- signed timestamp freshness
- request id / nonce tracking

### 5.6 Transport profiles

If `transport_profiles` is advertised, senders SHOULD follow:

- `preferred_order`
- `fallback_order`

Implementations MAY downgrade transport when the peer returns capability-related
HTTP errors such as `404`, `406`, `410`, `415`, `426`, or `501`.

## 6. Durable event envelope

Every durable event envelope MUST include:

- `version`
- `event_type`
- `origin_domain`
- `stream_id`
- `sequence`
- `event_id`
- `idempotency_key`
- `occurred_at`
- `payload`

Durable envelopes SHOULD also include:

- `signature`

Rules:

- the payload MUST validate against the matching schema
- durable extension events MUST use canonical URN `event_type` values on wire
- aliases MAY be accepted as SDK input before signing
- receivers MUST verify payload semantics in addition to schema validation

### 6.1 Event signatures

Durable envelopes SHOULD be signed with Ed25519 over canonical JSON for the
envelope without its `signature` block.

### 6.2 Canonical JSON

Canonical JSON MUST be deterministic:

- object keys sorted lexicographically
- no insignificant whitespace
- stable number/string encoding

### 6.3 Deduplication and retries

Rules:

- `event_id` is unique per delivery artifact
- `idempotency_key` is stable across retries of the same semantic event
- retries MUST preserve `idempotency_key`
- receivers MUST tolerate duplicate deliveries

## 7. Event classes

### 7.1 Core room participation events

Core room participation events are:

- `message.create`
- `message.update`
- `message.delete`
- `reaction.add`
- `reaction.remove`
- `read.cursor`
- `membership.upsert`

General rules:

- `stream_id` MUST be `channel:{effective_channel_id}` for room-scoped events
- the acting participant MUST be an active room member unless the event itself
  is establishing a join request or accepted membership
- the sender domain MAY only author actor-bearing objects for its own actors

`membership.upsert` rules:

- describes effective room state for a participant
- typical states are `invited`, `active`, `left`, and `banned`
- a self-authored join request is represented as a membership projection that
  remains non-active until accepted
- room authorities or authorized moderators MAY later update the effective role
  or state

### 7.2 Shared room governance events

Governance events are:

- `invite.upsert`
- `ban.upsert`
- `role.upsert`
- `role.assignment.upsert`
- `permission.overwrite.upsert`
- `thread.upsert`
- `thread.archive`
- `moderation.action.recorded`

Rules:

- governance is room-scoped
- governance is multi-origin
- authorization is based on effective room permissions
- concurrent governance is projected as latest accepted state per governed
  object key

Expected permission checks:

- `invite.upsert` requires `invite_members`
- `ban.upsert` and `moderation.action.recorded` require `manage_moderation`
- `role.upsert` and `role.assignment.upsert` require `manage_roles`
- `permission.overwrite.upsert` requires `manage_permissions`
- `thread.upsert` and `thread.archive` require thread ownership or sufficient
  room moderation privilege

### 7.3 Bootstrap event

`server.upsert` is a bootstrap advertisement event.

Rules:

- it describes a server and a peer-visible subset of its channels
- it MUST omit non-public channels for unauthenticated bootstrap
- channel entries MAY include policy hints such as `is_public` and
  `approval_mode_enabled`
- receivers MUST still enforce actual authorization from room governance state

### 7.4 Direct messages

`dm.message.create` is a durable DM event.

Rules:

- `stream_id` MUST be `dm:{dm_id}`
- DM sender identity MUST be validated by actor `uri`
- DM event context is DM-scoped, not room-scoped

## 8. Extension registry and negotiation

Current extension URNs are:

- `urn:arblarg:ext:bootstrap:1`
- `urn:arblarg:ext:roles:1`
- `urn:arblarg:ext:permissions:1`
- `urn:arblarg:ext:threads:1`
- `urn:arblarg:ext:presence:1`
- `urn:arblarg:ext:moderation:1`
- `urn:arblarg:ext:dm:1`
- `urn:arblarg:ext:voice:1`

`urn:arblarg:ext:voice:1` is reserved in 1.0 and defines no wire events.

Negotiation rules:

- senders MUST only emit optional extension events to peers that advertise
  compatible support
- support MAY be advertised in discovery, profiles, static peer config, or all
  three
- receivers that do not support an extension event MUST reject it as
  `unsupported_event_type`

## 9. Visibility and routing

Arblarg is not a global broadcast protocol.

### 9.1 Room visibility

Peers are allowed to see a room when at least one of these is true:

- the room is public and publicly bootstrap-visible
- the peer has an active member in the room
- the peer is the target or host of an active invite or pending join workflow

`server.upsert`, snapshots, replay, and live fanout MUST respect peer visibility.

### 9.2 Live fanout

Durable room events MUST be routed only to homeservers that currently share
authorized participation or visibility in that room.

Ephemeral room events MUST be routed only to homeservers that currently
participate in that room.

### 9.3 Mirrors

A receiver stores remote rooms as mirrors:

- mirrors are queryable local projections
- mirrored rooms may be writable for local users when federation membership and
  ACL permit it
- mirrored rooms are not a separate protocol type; they are local projections of
  authoritative remote rooms

## 10. Snapshots and recovery

### 10.1 Snapshot purpose

A snapshot is a signed coarse export used for:

- initial mirror bootstrap
- coarse repair after unrecoverable replay gaps
- reseeding local high-water marks

### 10.2 Snapshot contents

A snapshot MAY include:

- `server`
- `channels`
- `messages`
- `governance`
- `message_deletions`
- `reactions`
- `read_cursors`
- `extensions`
- `stream_positions`
- `signature`

`stream_positions` are required for a complete snapshot.

### 10.3 Multi-origin snapshots

For multi-origin rooms:

- snapshots MAY include actor-bearing entries authored by domains other than the
  snapshot signer
- receivers MUST validate embedded actor origin from the payloads themselves
- `stream_positions` MUST be scoped by `(origin_domain, stream_id)`
- snapshots SHOULD include checkpoints for all known participant origins in the
  exported rooms, not only the snapshot sender

### 10.4 Snapshot visibility

Snapshots MUST be peer-filtered:

- only visible rooms MAY be exported to a requesting peer
- private rooms MUST NOT leak through public bootstrap or unrelated snapshot
  export
- room policy hints in channel entries MUST round-trip when available

### 10.5 Replay and gap handling

When a receiver detects a sequence gap:

1. it SHOULD attempt stream replay for the missing `(origin_domain, stream_id)`
2. if replay cannot repair the gap, it SHOULD fetch a snapshot
3. for room events, snapshot fallback SHOULD use the room authority identified
   by room refs, not merely the author of the triggering event

## 11. Ephemeral lane

### 11.1 Endpoint and batch shape

Ephemeral events are delivered through:

- `POST /_arblarg/ephemeral`

The request body is a batch containing:

- `version`
- `batch_id`
- `items`

Each item MUST include:

- `event_type`
- `origin_domain`
- `payload`

### 11.2 Allowed ephemeral event types

Allowed ephemeral event types are:

- `presence.update`
- `typing.start`
- `typing.stop`

These events MUST NOT appear inside durable signed envelopes.

### 11.3 Presence

`presence.update` carries:

- `presence.actor`
- `presence.status`
- `presence.updated_at`

Optional fields:

- `presence.activities`
- `presence.ttl_ms`
- room or server context via `channel` / `server` or `refs`

Presence semantics:

- if room context is present, the update is room-scoped occupant presence
- if room context is absent, the update is account presence
- account presence SHOULD only be federated to explicit subscribers
- room presence SHOULD only be federated to participating room homeservers
- presence is TTL-based and non-replayable

### 11.4 Typing

`typing.start` and `typing.stop` are room-scoped ephemeral hints.

Rules:

- they MUST include room context
- `typing.start` MAY include `ttl_ms`
- typing is not durable, not replayable, and not snapshotted

## 12. HTTP and session endpoints

### 12.1 Durable event ingest

`POST /_arblarg/events`

- accepts one durable signed event envelope
- returns applied, duplicate, stale, or recovery-aware statuses

### 12.2 Durable batch ingest

`POST /_arblarg/events/batch`

- accepts multiple durable envelopes
- applies each independently

### 12.3 Snapshot import

`POST /_arblarg/sync`

- imports a signed snapshot
- seeds mirrors and stream checkpoints

### 12.4 Snapshot export

`GET /_arblarg/servers/{server_id}/snapshot`

- exports a peer-filtered signed snapshot

### 12.5 Stream replay export

`GET /_arblarg/streams/events`

Query parameters SHOULD identify:

- `stream_id`
- `origin_domain`
- replay cursor or sequence start
- replay limit

### 12.6 Session websocket

The websocket session profile is optional.

It MAY carry:

- durable stream batches
- ephemeral batches
- replay requests
- snapshot control operations
- ping / flow-control ops

## 13. Error handling

Receivers SHOULD return structured error codes.

Common error classes include:

- `invalid_payload`
- `unsupported_event_type`
- `invalid_event_signature`
- `origin_domain_mismatch`
- `origin_actor_domain_mismatch`
- `origin_identifier_host_mismatch`
- `origin_stream_host_mismatch`
- `not_authorized_for_room`
- `unsupported_version`

Senders SHOULD treat authorization and capability errors as non-retryable unless
operator action or membership state changes.

## 14. Conformance and schema publication

Implementations SHOULD publish:

- schema index under `/_arblarg/{version}/schemas`
- profiles metadata under `/_arblarg/profiles`

The canonical schema set for 1.0 currently includes:

- `envelope`
- `message.create`
- `message.update`
- `message.delete`
- `reaction.add`
- `reaction.remove`
- `read.cursor`
- `membership.upsert`
- `invite.upsert`
- `ban.upsert`
- `server.upsert`
- `role.upsert`
- `role.assignment.upsert`
- `permission.overwrite.upsert`
- `thread.upsert`
- `thread.archive`
- `presence.update`
- `typing.start`
- `typing.stop`
- `moderation.action.recorded`
- `dm.message.create`

## 15. Minimal sender checklist

A conforming sender SHOULD:

1. Discover the peer and validate its signed discovery document.
2. Load peer capabilities from discovery and profiles.
3. Sign every federation request.
4. Sign every durable event envelope.
5. Use canonical extension URNs on wire for durable extension events.
6. Preserve `idempotency_key` across retries.
7. Maintain ordering per `(origin_domain, stream_id)`.
8. Restrict live fanout to authorized participant peers.
9. Restrict bootstrap and snapshots to peer-visible rooms.
10. Support replay and signed snapshot recovery with multi-origin
    `stream_positions`.
11. Reject invalid actor origin and invalid origin-owned identifiers.
12. Treat presence and typing as ephemeral only.

## 16. Future work

The following are intentionally outside Arblarg 1.0:

- native voice and video media transport
- end-to-end device identity and key graph semantics
- Matrix-style DAG state resolution
- richer transport profiles beyond the current HTTP and websocket model
