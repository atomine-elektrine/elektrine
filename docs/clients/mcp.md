# MCP

Elektrine exposes an authenticated MCP JSON-RPC endpoint for tool clients:

```text
POST /api/ext/v1/mcp
Authorization: Bearer ekt_...
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2025-11-25
```

Use a normal personal access token. Tool discovery and tool calls are filtered by
the token's scopes.

The endpoint implements MCP Streamable HTTP as a stateless server:

- `POST /api/ext/v1/mcp` accepts one JSON-RPC message per request.
- JSON-RPC notifications and client responses return `202 Accepted`.
- `GET /api/ext/v1/mcp` returns `405 Method Not Allowed`; Elektrine does not open
  a server-sent events stream because it does not send server-initiated MCP
  messages.
- No `Mcp-Session-Id` is issued or required.
- Browser-originated requests must use an `Origin` matching the Elektrine host.

Minimum handshake:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}
```

List available tools:

```json
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
```

Call a tool:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "kairo.sources.create",
    "arguments": {
      "source_type": "markdown",
      "title": "Captured note",
      "content": "Saved through MCP"
    }
  }
}
```

Initial tools cover account metadata, scoped global search, command actions,
email messages, Kairo projects/sources, and encrypted Nerve entries.
