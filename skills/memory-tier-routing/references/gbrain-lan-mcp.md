# Exposing gbrain MCP over LAN (HTTP)

Serve the host brain to other machines / agents over the LAN.

## Serve

```
gbrain serve --http --port 8447 --bind <lan-ip>
```

- Default bind is `127.0.0.1` — pass the LAN interface IP explicitly (or `0.0.0.0`).
- **Pitfall: `--public-url http://...` is rejected — the OAuth issuer must be HTTPS.** For plain-LAN HTTP, omit `--public-url` entirely; the server then works fine with the default issuer.
- Health probe: `GET /health` → `{"status":"ok",...}`. MCP endpoint: `POST /mcp`.

## Token

```
gbrain auth create <client-name> --scopes read,write
```

Printed once; store it out-of-band. Revoke with `gbrain auth revoke <client-name>`. This is the simple long-lived bearer path — prefer it over OAuth client-credentials for trusted LAN peers.

## Client wiring

MCP URL: `http://<lan-ip>:8447/mcp`, header `Authorization: Bearer <token>`.

Raw curl probe (both accept types are REQUIRED or the server answers `-32000 Not Acceptable`):

```
curl -X POST http://<lan-ip>:8447/mcp \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"1.0"}}}'
```

A request without the Bearer header must get `invalid_token` — probe that too, it proves auth is actually enforced, not silently open.

## Remote write path for a client machine

The remote agent writes via `put_page` through this endpoint; the page lands in the host brain. Write-through to the host repo follows the host's `sources.local_path` — the remote never touches the repo directly, so the host owns commit/sync/embed. Keep remote client tokens scoped (`read,write`, never `full`) and name them per-machine so revocation is surgical.
