# Launch admission and final receipt boundary

`fx.launch-admission-final` schema version 1 is a role-neutral local contract
for one interactive Fx launch. It is distinct from authenticated Work-control
schema version 1. The contract does not define a socket, command, or standard
input service; an owning adapter chooses the transport and passes ordinary
Work-control queue or steer requests to Fx.

## Encoding

Each message is canonical UTF-8 JSON behind a four-byte big-endian payload
length. The maximum payload is 1,048,576 bytes. Empty, partial, oversized,
noncanonical, duplicate-key, unknown-field, unsupported-schema, and invalid
UTF-8 inputs are rejected.

The golden fixture is
`fixtures/launch_admission_final_v1.jsonl`. It is 4,262 bytes and its SHA-256
digest is
`b807e31bf8f4de4179b91cca4c9f3a9a40d572f98d8e5467242fc70908eb8161`.
The JSONL newlines are fixture delimiters and are not part of an individual
framed payload.

The launch digest covers every immutable launch field except `request_id` and
`launch_digest`. A decision or final-receipt digest covers its canonical
envelope with only `receipt_digest` omitted. Turn identities are positive
decimal `u64` values encoded as JSON strings.

## Durable authority

The selected state root owns the ledger at
`.fx/launch-admission-final/records/`. Record names are the lowercase SHA-256
of the admission key. Directories and records use private permissions, all
mutations take the ledger advisory lock, and records are replaced through a
file-sync, rename, directory-sync boundary.

The first matching launch request stores the immutable launch digest and a
reserved Conversation identity. Reusing its key with the same digest returns
the stored launch and decision. Reusing the key with another digest fails.

Admission and pre-start cancellation take the same lock. The first mutation
stores exactly one of:

* `cancelled_before_start`
* `admitted`, with the actual queued or steering disposition and positive Turn
  identity chosen under the native admission lock

A cancellation decision rejects every later admission. An admitted decision
is never converted to cancellation, and cancellation replay returns the
original admitted decision. An exact retry of admitted initial work returns
the stored Turn and cannot enqueue a second prompt. Later unrelated
Work-control prompts use the ordinary schema version 1 path.

## Conversation and process lifetime

A fresh launch reserves its valid Conversation identity before process
effects. Exact resume uses the requested identity. The child receives that
identity with the opaque admission key, launch id, launch digest, and selected
state root. After fresh creation, exact resume, or a native new-Conversation
transition, Fx durably publishes the active main Conversation back to the
ledger.

If the parent restarts after accepting an originally fresh launch but before
the reserved Conversation becomes durable, recovery issues the same fresh
launch with the retained reservation. Once Fx's existing session authority
validates the active Conversation, recovery uses only exact resume of that
identity. Missing, malformed, or unavailable state never selects a substitute
Conversation.

The native supervisor records only process-level terminal state:
`exited`, `signalled`, or `exec_failed`. The receipt captures the latest active
main Conversation and remains in the ledger with its digest until an exact
acknowledgement is durably recorded. Replaying the same acknowledgement is
idempotent across process restart. These receipts are control-plane state and
must not be appended to the interactive transcript.
