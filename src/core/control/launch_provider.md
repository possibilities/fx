# Private launch provider

`fx.private-launch-provider` schema version 1 is the native adapter between an
external Fx process owner and Fx's durable `fx.launch-admission-final` schema
version 1 authority. Schema version 2 preserves every version-1 operation and
adds one read-only exact-resume status decision. The provider is private,
local, role neutral, and independently versioned. Neither private version
changes the frozen public fixture or authenticated Work-control schema version
1.

The provider never starts, signals, waits for, or reaps the interactive Fx
process. Fmx's Companion remains the sole process and PTY owner. The provider
only accepts or reopens one launch, returns the authorized argument list and
five-variable child correlation delta, applies pre-start cancellation, reads
retained receipts, records an externally proven terminal outcome, and applies
an exact final acknowledgement.

## Invocation and transport

Start the same Fx executable with the exact hidden argument
`--internal-launch-provider` and the all-or-none environment tuple:

* `FX_INTERNAL_LAUNCH_PROVIDER_DIRECTORY`: a new absolute endpoint directory
  whose parent already exists; the directory itself must not exist
* `FX_INTERNAL_LAUNCH_PROVIDER_INSTANCE_ID`: an opaque identifier of at most
  256 bytes
* `FX_INTERNAL_LAUNCH_PROVIDER_TOKEN`: a random bearer token from 32 through
  4,096 bytes

Fx atomically creates the directory as a real mode-0700 directory owned by the
effective user and retains its descriptor. It binds `provider.sock` within it
as mode 0600, then verifies the directory and socket owner plus device/inode
identity through both the retained descriptor and the requested path before
dispatch. Directory substitution or socket replacement fails closed. Fx
accepts one peer for at most five seconds, exchanges one request and one
response, removes its anchored socket and directory when still reachable by
the original parent descriptor, and exits. A read or write may take at most
two seconds and either frame may contain at most 1,048,576 payload bytes. Each
frame is a four-byte big-endian length followed by UTF-8 JSON. The caller uses
a fresh endpoint directory for a retry after helper loss; durable operation
recovery comes from Fx's existing launch ledger, not endpoint files.

Every request has these fields, with `N` equal to supported version 1 or 2:

```json
{"schema_id":"fx.private-launch-provider","schema_version":N,"instance_id":"opaque","token":"secret","request_id":"opaque","operation":"inspect"}
```

Unknown fields, duplicate keys at any private-envelope depth, wrong field
counts, unsupported versions, malformed values, wrong instance identity, and
wrong authentication fail. Private field order need not be canonical.
Successful responses echo `instance_id` and `request_id`, set `ok` to true,
and carry `result`. Errors set `ok` to false and carry `error.code`. A
public-contract message in a private field is its exact canonical public JSON
encoded as a JSON string; the public codec validates it without translation.
Version-1 requests receive version-1 responses byte for byte as before.

## Operations

`prepare` adds `launch_request`, an exact canonical
`fx.launch-admission-final` `launch_request`. It durably accepts or replays the
launch and returns `result.launch_receipt`, also as canonical public JSON.

`build` adds `state_root`, `admission_key`, `launch_digest`, `launch_id`,
`mode`, `launch_controls`, and `remaining_launch_controls_digest`. `launch_controls`
is the exact canonical JSON string
`{"remaining_global_args":["ordered","arguments"]}`. `mode` is
`initial` only when the caller's durable transaction proves no Companion
effect exists; `recover_after_definitive_end` requires exact external proof
that the prior Companion process ended. The arguments digest is lowercase
SHA-256 of the exact UTF-8 `launch_controls` bytes and must equal the digest
committed by the launch request. Fx parses that string as one strict object,
rejects noncanonical or additional fields, an object larger than 131,072 bytes,
more than 128 arguments, empty entries, entries larger than 1,024 UTF-8 bytes,
NUL, ASCII controls through U+001F, and DEL U+007F. The only value-free flags
are `--no-additional-dirs`, `--no-native-tools`, `--no-default-skills`, and
`--no-project-instructions`. The only value options
are `--system-prompt-file`, `--append-system-prompt-file`, `--skills-dir`,
`--context-limit`, `--add-dir`, `--tool`, and `--permissions-file`, in separate
or nonempty `--option=value` form. A separate value may not begin with `-`.
The process-only permission authority is the one additional value option:
`--permission-mode auto` or `--permission-mode=auto`. It may appear once and
accepts only the exact lowercase value `auto`; the provider rejects every
other value before returning an invocation.
All other flags and positional entries are rejected, including provider-owned
state, name, model, effort, and every resume selector. The result contains:

* `arguments`: arguments after the Fx executable, including native state,
  naming, and exact-resume controls
* `cwd`: the exact launch directory
* `environment`: `FX_INTERNAL_LAUNCH_STATE_ROOT`,
  `FX_INTERNAL_LAUNCH_ADMISSION_KEY`, `FX_INTERNAL_LAUNCH_DIGEST`,
  `FX_INTERNAL_LAUNCH_ID`, and `FX_INTERNAL_LAUNCH_CONVERSATION_ID`, plus
  `FX_MODEL` and `FX_EFFORT` when those frozen request fields are present
* `mode`: the accepted caller proof class

Before merging the returned delta with its normal child environment, fmx
removes `FX_MODEL` and `FX_EFFORT`. Fx returns either key only when the durable
launch request froze that field, so omission authoritatively removes an
inherited override instead of changing the immutable launch. Fmx then gives
the plan to Companion. Provider endpoint credentials are never part of the
returned environment.

`inspect` adds the state root and correlation triple. It returns canonical
public `launch_receipt`, optional `decision`, optional `final_receipt`, and
optional `final_acknowledgement_id`. It never creates a launch.

`resume_status` is available only with private schema version 2. It adds the
state root and correlation triple and requires the retained public launch to
name an exact resume target. Fx opens that exact Conversation through its
read-only durable Session store. Only `SessionNotFound` produces the semantic
`unavailable` result; malformed, unreadable, mismatched, fresh, or otherwise
indeterminate state remains an error and is never translated into permanent
absence. The strict result is:

```json
{"resume_status":{"admission_key":"...","authority":"fx.private-launch-provider/resume-status-v2","conversation_id":"...","decision_digest":"...","decision_id":"resume-status-...","launch_digest":"...","launch_id":"...","semantic_decision":"exact_resume_available|exact_resume_unavailable","state_root":"...","status":"available|unavailable"}}
```

The semantic decision and status must be the matching pair. The decision id is
`resume-status-` followed by lowercase SHA-256 of the canonical UTF-8 JSON
object containing, in canonical key order, `admission_key`, `authority`,
`conversation_id`, `launch_digest`, `launch_id`, `semantic_decision`,
`state_root`, and `status`. The decision digest is lowercase SHA-256 of the
same canonical object with `decision_id` inserted after `conversation_id`;
`decision_digest` itself is excluded. This makes the proof independently
verifiable and stable across helper retries without treating a diagnostic
error name as contract authority.

Fmx requests status before a Companion effect for an exact-resume managed
launch. `available` permits the ordinary build and start path but does not
promise that a later process effect succeeds. `unavailable`, together with
fmx's durable proof that the process did not start, is the only provider result
that can support a permanent exact-resume outcome. A human recovery action
rechecks the status; an old unavailable decision does not authorize fresh work
after the Conversation becomes available.

`cancel` adds `state_root` and `cancel_request`, an exact canonical public
`admission_cancel_request`. It returns the inspection result after the one
durable decision wins. It cannot interrupt admitted work.

`record_final` adds the state root, correlation triple, strict public timestamp
as `observed_at`, and one `outcome`: `{"kind":"exited","code":N}`,
`{"kind":"signalled","signal":N}`, or
`{"kind":"exec_failed","message":"bounded text"}`. Fmx calls it only with
Companion's authoritative exact process outcome. Same-outcome retry returns
the retained receipt; a conflicting outcome fails.

`acknowledge_final` adds `state_root` and `acknowledgement`, an exact canonical
public `final_receipt_acknowledgement`. Exact replay is idempotent and a
conflicting acknowledgement fails.

## Recovery invariants

Helper or fmx loss does not imply process end, cancellation, or another spawn.
Fmx first reconciles the one exact Companion identity. A live process is
rejoined. An uncertain process stays pending. Only definitive end proof permits
`record_final` and, when the immutable transaction still requires a process,
`build` with recovery mode. Fx's selected-state-root ledger remains the only
authority for the launch, decision, active Conversation, final receipt, and
acknowledgement.
