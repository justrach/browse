# Connected apps

Another app on the Mac — Harness first — can use browse as its browser for
agent web tasks: the same tools graff has (`search`, `read_pages`, `open`,
`fill`, `drive`…), with the user's own sign-ins, limited to what the user
allowed, every request signed. The user switches it on in
Settings › Agent › Connected apps; it's off by default. The code is
`Sources/Browse/Connect.swift`, and `tools/connect-client.swift` is a
complete client to copy from (`swift tools/connect-client.swift check` runs
the refusals below against a running browse).

Protocol `v1-p256-sig`.

## Finding browse

While Connected apps is on and browse is running,
`~/Library/Application Support/browse/Agent/connect.json` (mode 0600) says
where it is:

```json
{"protocol": ["v1-p256-sig"], "port": 57232, "browse_key": "<base64>", "pid": 64650}
```

It holds no secret. The server is on `127.0.0.1:<port>` only.

## Encodings

- Keys: P-256, base64 (standard, padded) of the X9.63 uncompressed point,
  65 bytes (`SecKeyCopyExternalRepresentation`, CryptoKit `x963Representation`).
- Signatures: base64 of ASN.1 DER ECDSA over SHA-256 of the UTF-8 string
  (`SecKeyCreateSignature` with `.ecdsaSignatureMessageX962SHA256`, CryptoKit
  `derRepresentation`).
- Nonces: 16 random bytes, 32 lowercase hex characters.
- Timestamps: unix milliseconds, decimal.

## Pairing

1. `POST /pair`, unsigned:
   `{"client_key": "<b64>", "name": "Harness", "nonce": "<hex>", "protocol": ["v1-p256-sig"]}`
   → `200 {"protocol": "v1-p256-sig", "client_id": "<uuid>", "browse_key": "<b64>", "expires_in": 120}`.
   Errors: `403 connected_apps_off`, `409 pairing_in_progress`, `400 bad_request`.
2. Both apps show the code: the first 4 bytes of
   SHA-256(browse_key ‖ client_key ‖ nonce), raw bytes (65 + 65 + 16), read as
   a big-endian UInt32, mod 1,000,000, as 6 digits. The user checks they
   match, and picks scopes in browse.
3. `POST /pair/status`, signed with the new client_id, body `{}` →
   `{"status": "pending" | "paired" | "declined" | "expired", "scopes": [...]}`.

## Every request

`POST /mcp` with an MCP JSON-RPC message. The answer is always one
`application/json` body, never a stream, and there's no MCP session to carry.
Headers:

| Header | |
| --- | --- |
| `X-Client-Id` | from pairing |
| `X-Timestamp` | within 60 s of browse's clock |
| `X-Nonce` | never reused within 120 s |
| `X-Signature` | over `METHOD\|path\|sha256hex(body)\|timestamp\|nonce\|client_id` |

`path` is the request target as sent (`/mcp`); `sha256hex` is lowercase hex
of the raw body bytes. Refused with `401` and `unknown_client`,
`bad_signature`, `stale` or `replayed`. A request with any `Origin`, or a
`Host` other than `127.0.0.1:<port>`, is refused with `403 bad_origin`.

Every answer to a signed request carries `X-Signature`, by `browse_key`, over
`sha256hex(response body)|request nonce`. A notification's `202` has an
empty body, signed the same way.

### Sessions

An app running several agents keeps them apart with
`params._meta["browse/session"]` on `tools/call` (up to 64 of
`[A-Za-z0-9._:-]`). A session sees and closes only its own pages. Without
one, calls share the app's own pool. `POST /session/close`
`{"session": "<id>"}`, signed, closes a session's pages → `{"closed": n}`.

## Scopes

| Scope | Tools | Default |
| --- | --- | --- |
| `read` | `search`, `read_pages`, `tabs` (titles and addresses), `read` and `links` on the app's own pages | on |
| `act-own-pages` | `open`, `go`, `back`, `forward`, `reload`, `form_fields`, `fill`, `click`, `type`, `submit`, `drive`, `screenshot`, `close`, `show`, on pages opened for the app | on |
| `act-user-tabs` | the same, and `read`/`links`, in the user's own tabs; browse asks the user once each time it opens | off |
| `run-js` | `run_js` in the app's own pages (and the user's tabs with `act-user-tabs`) | off |

`tools/list` shows only what the app may use. A call outside its scopes, or
to a tool no app may use (`theme`), is refused with
`403 {"error": "out_of_scope", "tool", "scope"}`; the user saying no to their
tabs, with `403 {"error": "declined"}`. For every app, browse never types
into a password field, and `drive` stops before paying, sending, posting,
booking, deleting or signing up.

## Visibility and revocation

A pill over the page names the app while it's driving, with its page count.
Settings › Agent › Connected apps lists each app, its scopes (changeable),
and when it was last used, with Revoke. An app unused for 30 days is
forgotten. A revoked or forgotten app gets `401 unknown_client`, and pairs
again.
