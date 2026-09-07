# Structured Codex subscription inference protocol

The internal command `fx structured-inference` exposes one local, native,
tool-free request boundary. It does not create an interactive runtime, session,
conversation, project state, tool registry, MCP transport, or background task.

## Framing

The schema identifier is `fx.structured-subscription-inference` and the wire
version is `1`. Standard input must contain exactly one JSON frame followed by
one newline. The total input, including that newline, is limited to 1 MiB.
Standard output contains exactly one JSON frame followed by one newline.

The default private state root is
`~/.fx/structured-subscription-inference-v1`. Tests and local callers may pass
`--state-root <absolute-path>`; its parent must already exist. No state is
written under `.fx/sessions`.

An inference frame has this shape:

```json
{
  "schema_id": "fx.structured-subscription-inference",
  "version": 1,
  "operation": "infer",
  "model": "gpt-5.6-sol",
  "effort": "high",
  "prompt": "Return one object with answer set to subscription-ok.",
  "schema": {
    "type": "object",
    "properties": { "answer": { "type": "string", "const": "subscription-ok" } },
    "required": ["answer"],
    "additionalProperties": false
  },
  "caller_key": "opaque-caller-key",
  "cancelled": false
}
```

The exact frame used by deterministic coverage is
`tests/e2e/fixtures/structured-inference-request-v1.json`. The request digest
excludes `caller_key` and `cancelled`; cancellation is control state, not
request identity. The digest is SHA-256 over the domain
`fx-structured-subscription-request-v1`, followed by 64-bit big-endian
length-prefixed model, effort, prompt, and canonical schema bytes. Canonical
JSON sorts every object key lexicographically. The fixture request digest is
`4b30a49b59bcbd52831b8f28c0739b1f333fbf81686ec7b026728943e467278c`.

An acknowledgement frame names the same opaque key and terminal receipt:

```json
{
  "schema_id": "fx.structured-subscription-inference",
  "version": 1,
  "operation": "ack",
  "caller_key": "opaque-caller-key",
  "receipt_id": "64-lowercase-hex-characters"
}
```

## Provider request

The boundary resolves only the ordinary Fx-profile Codex subscription
credential, including the existing bounded native OAuth refresh. It then
fetches the authenticated native Codex catalog and requires byte-exact model
and effort labels. `effort_index` is the selected effort's zero-based position
in the provider-ordered catalog array.

Only after that selection does the boundary submit one Responses request. It
contains one user message, `StructuredResponseFormat`, `tool_choice` set to
`none`, an empty `ToolSelection`, `session_id` set to null, and `retry_count`
set to 1. No tool is advertised or dispatched, and no session identity header
is emitted. The returned text is parsed locally and validated against the
caller's strict object schema before success is persisted.

The accepted local schema subset is intentionally closed and bounded. Object
schemas must declare every property as required and set
`additionalProperties` to false. The validator supports nested objects,
arrays, primitive types, enum, const, local `$defs` and `$ref`, `allOf`,
`anyOf`, `oneOf`, and basic size and number bounds. Unsupported keywords fail
closed. Type-specific keywords require their matching explicit `type`.
Numbers are retained and compared as exact JSON decimal lexemes, including
integers beyond IEEE-754's exact range. Structural traversal and schema
evaluation each have fixed local budgets, so repeated references and
combinators cannot grow evaluation work without bound.

Captured provider output is limited to 960 KiB, leaving a fixed reserve in the
1 MiB terminal-frame budget for receipt and provenance fields. Provider
response identifiers are limited to 4096 bytes. Ledger records allow the
worst-case JSON escaping of a complete terminal frame; if terminal assembly
still exceeds its bound, Fx durably stores a small terminal failure instead.

## Receipts and recovery

The caller key is SHA-256 hashed for its ledger filename and is never stored in
clear text. A per-key advisory lock serializes admission. Durable phases are
`started`, `provider_admitted`, and `terminal`.

- A matching terminal request replays the exact stored terminal bytes.
- Reusing a key with a different request digest is rejected before auth or
  network I/O.
- A recovered `started` request is safe to continue.
- A recovered `provider_admitted` request is terminalized as
  `provider_outcome_unknown` and is never submitted again.
- Acknowledgement is durable and idempotent. Terminal bytes remain retained so
  request replay remains exact.

Cancellation before provider admission is persisted and prevents the provider
request. After admission, cancellation is best effort. A provider terminal
outcome already read from the transport remains authoritative, even if the
cancellation flag changes before that terminal event is reduced.

Terminal statuses are `succeeded`, `refused`, `cancelled`, `provider_failed`,
and `schema_failed`. Every terminal has an idempotent receipt. Success contains
the canonical schema-validated object. Other statuses contain a bounded stage,
code, and retryable flag.

## Provenance and secrets

Terminal provenance records the credential source, the existing non-secret
credential-authority SHA-256 identity, Codex catalog protocol and client
version, exact model and effort, ordered effort index, catalog-selection
digest, Responses protocol, and provider response ID when available.

Credential bytes, refresh tokens, authorization headers, account IDs, prompts,
and raw provider failure bodies are never persisted in the ledger or returned
as provenance. The credential identity is derived from the stable account
authority through the existing credential-authority contract, not from secret
token bytes.
