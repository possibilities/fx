# ADE event feed

Fx can publish the lifecycle of an interactive TUI and its in-process agents
to the agent development environment (ADE) that launched it. The interface is
versioned as schema `1`.

The feed is observational. A receiver cannot change a tool call, continue a
turn, answer a question, or grant a permission through this socket.

## Bind an Fx instance

The ADE assigns an instance identity before launching Fx. It can bind the
event socket, the recoverable Git-root checkpoint, or both:

```text
FX_ADE_SOCKET_PATH=/tmp/example-ade.sock
FX_ADE_INSTANCE_ID=instance-17
FX_ADE_CHECKPOINT_PATH=/tmp/example-ade-instance-17-git-roots.json
```

`FX_ADE_SOCKET_PATH` may be shared by every Fx TUI the ADE owns.
`FX_ADE_INSTANCE_ID` is an opaque identity assigned by the ADE and must be
unique among the instances using that socket. Fx returns it unchanged on every
record, allowing the receiver to associate an accepted connection with the
terminal, sidebar row, and focus state it already owns.

`FX_ADE_INSTANCE_ID` must be non-empty for either interface.
`FX_ADE_SOCKET_PATH` enables event delivery when it is also non-empty.
`FX_ADE_CHECKPOINT_PATH` independently enables Git-root checkpoints when it is
non-empty, so a missing or unavailable socket does not prevent checkpoint
updates. These interfaces are installed only by the interactive TUI. `fx ask`
and `fx acp` do not publish to them. Schema 1 requires a native POSIX host and
is disabled on Windows.

## Edited Git worktree checkpoint

Fx keeps the process-lifetime, first-discovery-ordered set of canonical Git
worktree checkout roots associated with one interactive process. When
`FX_ADE_CHECKPOINT_PATH` is set, Fx atomically replaces that consumer-owned
path with a mode-0600 JSON file whenever the set changes:

```json
{
  "schema": 1,
  "instance_id": "instance-17",
  "revision": 3,
  "git_roots": [
    "/workspace/project",
    "/workspace/linked-worktree"
  ]
}
```

Field types are fixed: `schema` is the integer `1`, `instance_id` is the
unchanged ADE string, `revision` is an unsigned integer, and `git_roots` is an
array of canonical absolute strings. `revision` begins at `0` and advances by
one only when Fx commits a newly deduplicated root. The array retains
first-discovery order. A non-Git launch writes an empty revision-0 checkpoint.

The checkpoint is output only. Fx does not restore or trust previous contents;
it replaces malformed, stale, or identity-mismatched state. Replacement uses a
mode-0600 temporary file in the destination directory followed by an atomic
rename. Serialization, creation, permission, and replacement failures are
best-effort and never fail tool execution. Root discovery and checkpoint I/O
run on a separate worker from tool execution.

The set is seeded from the launch directory's enclosing worktree, when one
exists, and remains intact across `/new`, `/resume`, session changes, and event
delivery failures. Both a `.git` directory and a linked-worktree `.git` file
identify the checkout root; Fx reports the linked checkout, not its common Git
directory.

## Transport

Fx opens one short-lived Unix-socket connection for each event, writes one
newline-terminated JSON object, and closes the connection. The receiver must
not reply. Lifecycle threads serialize records into a bounded FIFO; one sender
thread owns all socket I/O for the process. Records from one Fx process are
assigned `sequence` values under the queue lock. Different Fx processes may
write concurrently. The receiver should apply records from an instance in
ascending sequence order. Main-agent and subagent work can overlap, so
sequence describes observation order rather than a parent-before-child
completion guarantee.

Delivery is best-effort:

- Connect and write failures are ignored by the agent and recorded only in Fx
  debug traces.
- Each delivery has one 250 ms total deadline covering both connection and all
  writes. A non-accepting or non-reading receiver therefore cannot block a
  lifecycle thread or hold shutdown open indefinitely.
- The queue accepts at most 128 records and 8 MiB of serialized data. A single
  record is rejected when its worst-case serialized size exceeds 2 MiB. Fx
  drops a record when either limit would be exceeded.
- Fx does not retry or replay records. `sequence` advances before serialization
  and queue admission, so a gap means an attempted record was dropped or not
  delivered.
- Lifecycle processing never performs socket I/O or waits for the receiver to
  apply an event.

During orderly shutdown Fx discards records still waiting in the queue,
attempts `FxStopped` after any delivery already in progress, and joins the
bounded sender. This prioritizes a timely final lifecycle marker over draining
stale telemetry.

The receiver should read through the newline before closing its accepted
connection. It should ignore unknown event names within a supported schema and
reject schema versions it does not understand.

## Envelope

Every line has the same envelope:

```json
{
  "schema_version": 1,
  "sequence": 7,
  "event": "TurnStarted",
  "instance_id": "instance-17",
  "context": {
    "agent_role": "main",
    "workspace_root": "/workspace/project",
    "session_id": "01J...",
    "parent_session_id": null,
    "subagent_id": null,
    "turn_id": 42
  },
  "payload": {}
}
```

`sequence` begins at `1` for each Fx process and increases for every attempted
record. Nullable identifiers are JSON `null`.

`agent_role` is `main` or `subagent`. A main record carries the TUI's active
session in `session_id` and has no parent. A subagent record carries the child
session in `session_id` and the owning main session in `parent_session_id`.
`subagent_id` is an optional Fx-local numeric identity; consumers must use the
session IDs for durable identity. Main and child records always retain the same
ADE-assigned `instance_id`.

## Events

### `FxStarted`

The first attempted event. It says that the TUI has initialized its lifecycle
observer and includes its current main session and workspace in `context`.
The ADE remains authoritative for process and terminal readiness. The payload
is empty.

### `GitRootDiscovered`

Emitted once for each newly deduplicated Git worktree root. `FxStarted` remains
the first attempted event; launch-directory discovery follows it. When a
checkpoint is enabled, Fx attempts to replace the checkpoint with the new
revision before enqueueing this event:

```json
{
  "git_root": "/workspace/linked-worktree",
  "revision": 3,
  "reason": "subagent_file_mutation"
}
```

`git_root` is the canonical absolute checkout root. `revision` is the unsigned
root-set revision committed in the checkpoint. The complete schema-1 reason
vocabulary is:

- `launch_directory`
- `file_mutation`
- `terminal_write`
- `subagent_file_mutation`
- `subagent_terminal_write`

The event uses the ordinary ADE envelope. `context.agent_role` and its session
fields identify whether the successful operation came from the main agent or a
subagent. Root state belongs to the parent Fx instance and is not reset by
session changes. Existing schema-1 consumers must ignore this unknown additive
event if they do not use edited-root discovery.

Built-in file tracking covers successful write/create, edit, delete, rename,
and copy calls. Write/edit no-ops, denied calls, and failed calls add nothing.
Rename observes the pre-resolved source followed by the destination because
both repositories can be mutated; copy observes only its destination because
its source is read-only.

Terminal tracking uses the command's declared, resolved working directory only
when Fx's existing command-effect classifier returns `filesystem_write` and
the command succeeds. Read-only, failed, dynamic-shell, and other classifier
results add nothing. Fx does not inspect hidden shell directory changes: for
example, a command declared in repository A that internally changes to
repository B does not provide reliable evidence for B.

### `SessionChanged`

Emitted as soon as Fx installs a different active main session, before session
stores, subagent rebinding, or recovered-child startup can emit against it:

```json
{
  "previous_session_id": "01J...OLD",
  "session_id": "01J...NEW"
}
```

Either identity can be `null`. The new identity is also present in `context`.
Idle `/new` and `/resume` transitions therefore publish without waiting for a
prompt.

### `SessionMetadataChanged`

Emitted after Fx durably installs native metadata for the active main session:

```json
{ "title": "Prompt submit session naming" }
```

The title is the same value used by `/rename`, `display.json`, the resume
index, the status line, and the terminal tab. A fresh session can first publish
a prompt-derived fallback and then replace it with a generated title. Resuming
or switching sessions publishes that session's existing title after the
corresponding `SessionChanged` record. Repeated identical titles are suppressed
within one active session.

This is a raw metadata fact rather than a lifecycle transition. Receivers may
use it immediately for their own presentation, but Fx remains the persistence
authority. After a sequence gap, a receiver that needs the current value can
read `~/.fx/sessions/<session_id>/display.json`.

### `PromptQueued`

Emitted for a main-agent prompt after queue admission and before the worker is
woken. It is the earliest reliable indication that the interactive TUI has
accepted work. Its payload is empty. Subagents have their own lifecycle but do
not publish this TUI admission event.

### `TurnStarted`

Emitted after Fx assigns the accepted turn its stable `turn_id` and before
agent execution. It follows `PromptQueued` for an ordinary main-agent prompt,
but can be materially later while preflight work runs. The payload is empty.
Main and subagent turns are both published.

### `PreToolUse`

Emitted before local tool permission and execution:

```json
{
  "step_index": 3,
  "call_id": "call_123",
  "tool_name": "terminal",
  "arguments": { "action": "exec", "command": "git status" }
}
```

This event is passive. Its arguments are exactly the structured arguments at
that lifecycle point; insignificant JSON whitespace is compacted so one event
remains one physical line. The receiver cannot rewrite or block them.

### `Stop`

Emitted when Fx has a terminal assistant candidate before turn finalization:

```json
{
  "step_index": 5,
  "assistant_text": "The change is complete.",
  "provider_disposition": "completed",
  "can_continue": true
}
```

The receiver cannot request continuation. More than one `Stop` may occur for a
turn if another Fx hook requests a continuation.

### `PostTurnEnd`

Emitted after a terminal turn outcome is accepted:

```json
{
  "outcome": "completed",
  "provider_disposition": "completed"
}
```

`outcome` is `completed`, `interrupted`, `failed`, or `paused`.
`provider_disposition` can be `null`.

### `AttentionRequired`

Emitted after a user decision becomes active:

```json
{ "kind": "permission" }
```

`kind` is `permission`, `question`, or `route_recovery`. Main and subagent
attention are not folded together; `context` identifies the waiting agent.
When a surfaced child permission has no child turn identity at the TUI
projection boundary, its `turn_id` is `null`; its child `session_id` and parent
main-session identity remain authoritative.

### `FxStopped`

The last attempted event during an orderly shutdown. Fx sends it after the
worker and subagent runtimes have stopped, so no later lifecycle record can be
produced by that process. The payload is empty. A crash or forced termination
can prevent this event; the ADE remains authoritative for process exit.

## Deriving ADE state

An ADE can reproduce the state previously available through Fx's Herdr
integration without speaking the Herdr protocol:

| Feed event | ADE projection |
| --- | --- |
| `FxStarted` | Bind the instance's main session and seed its lifecycle state as idle |
| `GitRootDiscovered` | Add the canonical root at the stated root-set revision, or recover the ordered set from the checkpoint |
| `SessionChanged` | Replace the instance's main session identity |
| `SessionMetadataChanged` | Replace the instance's displayed native session title |
| `PromptQueued` | Mark the main agent working as soon as Fx accepts its prompt |
| `TurnStarted` | Confirm execution for the identified main agent or mark a subagent working |
| `AttentionRequired` | Mark that agent blocked and retain `kind` |
| `PostTurnEnd` | Mark that agent idle; the ADE may project unseen idle as done |
| `FxStopped` or process exit | Remove or detach the instance according to ADE policy |

The ADE owns layout, focus, seen/unseen state, labels, and process supervision.
Fx deliberately does not duplicate those presentation facts in the feed.

## Sensitive payloads

The socket receives workspace paths, native session titles, tool names,
complete tool arguments, and assistant text. Titles can summarize sensitive
prompt text, and the other values can contain secrets directly. The launching
ADE is responsible for protecting the socket, authenticating its local
clients, and applying any persistence, redaction, or forwarding policy.
The checkpoint also exposes canonical workspace paths; its parent directory
must be private even though Fx creates each replacement with mode 0600.

The ADE feed and the Herdr integration are independent. Setting `FX_ADE_*`
does not enable, disable, or alter `HERDR_*` behavior, and both integrations
may operate in the same Fx process.
