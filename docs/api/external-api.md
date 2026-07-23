# External API

Elektrine exposes a versioned HTTP API at `/api/ext/v1` for programmatic
integrations. The machine-readable OpenAPI spec is served at
`/openapi/ext-v1.yaml` (source:
`apps/elektrine/priv/static/openapi/ext-v1.yaml` — update it by hand whenever
the `/api/ext/v1` routes change).

## Authentication

All endpoints use personal access tokens (PATs), created in the app under
**Account → Developer** (`/account?tab=developer`). Tokens are prefixed
`ekt_`, are shown only once at creation, and are limited to 20 per user.

```text
Authorization: Bearer ekt_...
```

Each token carries a set of scopes; requests outside the token's scopes are
rejected with `403`. Valid scopes:

| Area | Read | Write |
| --- | --- | --- |
| Email | `read:email` | `write:email` |
| Chat | `read:chat` | `write:chat` |
| Social | `read:social` | `write:social` |
| Contacts | `read:contacts` | `write:contacts` |
| Calendar | `read:calendar` | `write:calendar` |
| Account | `read:account` | `write:account` |
| Nerve | `read:nerve` | `write:nerve` |
| Kairo | `read:kairo` | `write:kairo` |
| DNS | `read:dns` | `write:dns` |
| Proofs | `read:proofs` | `write:proofs` |
| Static site | `read:static_site` | `write:static_site` |
| Moderation | `read:moderation` | `write:moderation` |
| Exports | `export` | `export` |
| Webhooks | `webhook` | `webhook` |

Use `GET /api/ext/v1/capabilities` to inspect a token's scopes and the
endpoints it can reach — useful for SDKs, CLIs, and setup wizards.

## Conventions

- Success responses wrap the payload: `{"data": {...}, "meta": {"request_id": "..."}}`.
  List endpoints include a `pagination` object in `meta`.
- Errors return `{"error": {"code": "...", "message": "...", "details": ...}, "meta": {...}}`
  with a machine-readable `code` (e.g. `missing_parameter`, `rate_limited`,
  `validation_failed`).
- All PAT pipelines are rate limited; expect `429` with code `rate_limited`
  under sustained load.
- Request bodies may be sent flat or wrapped in a resource key (e.g.
  `{"email": {...}}`, `{"zone": {...}}`); both forms are accepted.

## Quick start: send an email

Requires the `write:email` scope. `from` is optional and defaults to your
primary mailbox address. When supplied, it must be a mailbox address or alias
owned by your account. Sending to external recipients spends 1 Identity Credit.

```bash
curl -X POST https://elektrine.com/api/ext/v1/email/messages \
  -H "Authorization: Bearer ekt_..." \
  -H "Content-Type: application/json" \
  -d '{
    "from": "notifications@example.com",
    "to": "someone@example.com",
    "subject": "Hello",
    "text_body": "Plain text body",
    "html_body": "<p>Optional HTML body</p>"
  }'
```

Other fields: `from`, `cc`, `bcc`, `reply_to`, `encryption_mode`. An unowned
`from` address returns `403` with code `unauthorized_from_address`.

## Endpoints

Summaries, parameters, and request bodies for every operation live in the
OpenAPI spec; this is the map of what exists and the scope each family needs.

### Meta and search (any PAT / `read:account` / varies)

| Endpoint | Description |
| --- | --- |
| `GET /capabilities` | Token scopes, presets, and allowed endpoints (any PAT) |
| `GET /me` | Authenticated user and token metadata (`read:account`) |
| `GET /search` | Global search across resources the token can read |
| `GET /search/actions` | List actions available to the token's scopes |
| `POST /search/actions/execute` | Execute an action by command (scope varies by action) |

### Email (`read:email` / `write:email`)

| Endpoint | Description |
| --- | --- |
| `GET /email/messages` | List messages across your mailboxes (`limit`, `offset`, `folder`, `mailbox_id`) |
| `GET /email/messages/:id` | Get a single message |
| `POST /email/messages` | Send an email (see quick start) |

### Contacts (`read:contacts`)

| Endpoint | Description |
| --- | --- |
| `GET /contacts` | List address book contacts (`q`, `limit`, `offset`) |
| `GET /contacts/:id` | Get a single contact |

### Chat (`read:chat` / `write:chat`)

| Endpoint | Description |
| --- | --- |
| `GET /chat/conversations` | List conversations |
| `GET /chat/conversations/:id` | Get a conversation with recent messages |
| `GET /chat/conversations/:id/messages` | List messages (`limit`, `before_id`, `after_id`) |
| `POST /chat/conversations/:id/messages` | Send a message (`content`, `message_type`, `media_urls`, `reply_to_id`) |

### Social (`read:social` / `write:social`)

| Endpoint | Description |
| --- | --- |
| `GET /social/feed` | Home or public feed (`scope=home\|public`) |
| `GET /social/posts/:id` | Get a visible post |
| `GET /social/users/:user_id/posts` | List a user's visible posts |
| `POST /social/posts` | Create a timeline post (`content`, `visibility`, `title`, `media_urls`) |

### Calendars (`read:calendar` / `write:calendar`)

| Endpoint | Description |
| --- | --- |
| `GET /calendars` | List calendars |
| `POST /calendars` | Create a calendar |
| `GET /calendars/:id/events` | List events |
| `POST /calendars/:id/events` | Create an event |
| `PUT /events/:id` | Update an event |
| `DELETE /events/:id` | Delete an event |

### DNS (`read:dns` / `write:dns`)

| Endpoint | Description |
| --- | --- |
| `GET /dns/zones` | List managed zones |
| `POST /dns/zones` | Create a zone (`domain` required) |
| `GET /dns/zones/:id` | Get a zone with records |
| `PUT /dns/zones/:id` | Update a zone |
| `DELETE /dns/zones/:id` | Delete a zone |
| `POST /dns/zones/:id/verify` | Verify delegation to Elektrine nameservers |
| `POST /dns/zones/:id/services/:service/apply` | Apply managed records for a service (`mail`, `web`, `turn`, `dns`, `vpn`, `bluesky`) |
| `DELETE /dns/zones/:id/services/:service` | Disable a managed service |
| `POST /dns/zones/:zone_id/records` | Create a record (`name`, `type`, `ttl`, `content`) |
| `PUT /dns/zones/:zone_id/records/:id` | Update a record |
| `DELETE /dns/zones/:zone_id/records/:id` | Delete a record |

### Kairo (`read:kairo` / `write:kairo`)

| Endpoint | Description |
| --- | --- |
| `GET /kairo/projects` | List projects |
| `POST /kairo/projects` | Create a project (`name` required) |
| `PATCH/PUT /kairo/projects/:id` | Update a project |
| `DELETE /kairo/projects/:id` | Delete a project |
| `GET /kairo/sources` | List ingested sources |
| `POST /kairo/sources` | Ingest a source (JSON, or multipart `file` upload) |
| `GET /kairo/sources/:id` | Get a source |
| `PATCH/PUT /kairo/sources/:id` | Update a source |
| `POST /kairo/sources/:id/retry` | Retry a failed ingestion |
| `DELETE /kairo/sources/:id` | Delete a source |

### Nerve (`read:nerve` / `write:nerve`)

Entry payloads are end-to-end encrypted; `encrypted_metadata` and
`encrypted_password` are required on writes.

| Endpoint | Description |
| --- | --- |
| `GET /nerve/entries` | List encrypted entries |
| `POST /nerve/entries` | Create an entry |
| `GET /nerve/entries/:id` | Get an entry |
| `PUT /nerve/entries/:id` | Update an entry |
| `DELETE /nerve/entries/:id` | Delete an entry |
| `POST /nerve/setup` | Deprecated — always returns 400 (Nerve uses the account password) |

### Identity proofs (`read:proofs` / `write:proofs`)

| Endpoint | Description |
| --- | --- |
| `GET /proofs` | List proofs and current proof score |
| `GET /proofs/score` | Get the proof score |
| `GET /proofs/:id` | Get a proof |
| `POST /proofs` | Create a proof (`kind`: `dns`/`web`/`social`; `subject` required) |
| `POST /proofs/:id/check` | Run the verification check |
| `DELETE /proofs/:id` | Delete a proof |

### Static site (`read:static_site` / `write:static_site`)

| Endpoint | Description |
| --- | --- |
| `GET /static-site` | Inspect the current deployment |
| `POST /static-site/deploy` | Deploy from a multipart ZIP upload (`site`) |
| `POST /static-site/deploy/github` | Deploy from GitHub Actions (GitHub OIDC token, not a PAT) |
| `POST /static-site/deploy/github/webhook` | GitHub push webhook (HMAC `X-Hub-Signature-256`, not a PAT) |

See `docs/clients/static-site-github-deploys.md` for the GitHub flows.

### Exports (`export`)

| Endpoint | Description |
| --- | --- |
| `GET /exports` | List exports |
| `POST /exports` | Queue a data export |
| `GET /exports/:id` | Get export status |
| `GET /exports/:id/download` | Download a completed export |
| `DELETE /exports/:id` | Delete an export |

### Webhooks (`webhook`)

| Endpoint | Description |
| --- | --- |
| `GET /webhooks` | List webhooks with recent deliveries |
| `POST /webhooks` | Create a webhook (`name`, `url`, `events`) |
| `GET /webhooks/:id` | Get a webhook |
| `DELETE /webhooks/:id` | Delete a webhook |
| `POST /webhooks/:id/test` | Send a test delivery |
| `POST /webhooks/:id/rotate-secret` | Rotate the signing secret |
| `GET /webhooks/:id/deliveries` | Delivery history |
| `POST /webhooks/:id/deliveries/:delivery_id/replay` | Replay a delivery |

Valid event types: `email.received`, `email.sent`, `message.received`,
`post.created`, `post.liked`, `follow.new`, `export.completed` (1–20 per
webhook).

The signing secret is returned only when the webhook is created (or the
secret is rotated). Each delivery is a JSON POST with headers:

```text
x-elektrine-event: email.received
x-elektrine-delivery-id: <event id>
x-elektrine-timestamp: <ISO 8601>
x-elektrine-signature: sha256=<HMAC-SHA256 of the raw request body>
```

Verify by computing HMAC-SHA256 over the raw body with your secret and
comparing against the signature header.

## MCP

`POST /api/ext/v1/mcp` is a stateless MCP (Model Context Protocol)
streamable-HTTP endpoint, authenticated with a normal PAT; tool discovery and
calls are filtered by the token's scopes. See `docs/clients/mcp.md`.

## Other programmatic surfaces

Beyond the PAT API, standard protocols are available:

- **JMAP** (RFC 8620/8621): session at `GET /.well-known/jmap`, API at
  `POST /jmap/`, plus `/jmap/eventsource` and blob upload/download. Supports
  sending via `EmailSubmission/set`.
- **CardDAV**: address books under `/addressbooks/:username/contacts`.
- **IMAP/POP/SMTP**: classic mail clients, including authenticated SMTP
  submission (SMTPS on 465, optionally STARTTLS on 587; the app listens on
  2587 internally — see `docs/self-hosting/mail.md`). Server names and ports
  are surfaced in the app's mail client settings and via
  autoconfig/autodiscover.
- **OIDC**: Elektrine can act as an OpenID Connect provider; clients are
  managed under `/account/developer/oidc/clients`.


