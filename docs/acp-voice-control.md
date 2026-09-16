# ACP voice control

`fx acp` serves a small extension so a realtime voice agent can drive one
session by speech. The extension is opt-out free: it is always served, and a
client discovers it from `initialize` rather than by probing.

Three things the bare protocol does not give a voice frontend motivate it.
A person talking interrupts and redirects mid-sentence, so text must reach the
model inside the turn that is already running. A person asks "what is it
doing?", so the queue and the subagents must be inspectable. And a person must
hear that the agent is blocked the moment it blocks, so lifecycle has to be
pushed rather than polled.

## Discovery

`initialize` answers with the extension advertisement and the process
identity:

```json
{
  "protocolVersion": 1,
  "agentCapabilities": {
    "loadSession": true,
    "promptCapabilities": { "image": true, "audio": false, "embeddedContext": true },
    "mcpCapabilities": { "http": true, "sse": true },
    "sessionCapabilities": { "list": {}, "resume": {}, "close": {} },
    "_fx": { "steer": true, "snapshot": true, "lifecycle": 1, "question": true }
  },
  "agentInfo": { "name": "fx", "title": "fx", "version": "0.0.7" },
  "_fx": {
    "build_revision": "…",
    "version": "0.0.7",
    "auth": "…",
    "model_source": "…",
    "connected_providers": ["…"],
    "permission_mode": "auto",
    "model": "…",
    "effort": "auto",
    "workspace": "/…"
  },
  "authMethods": []
}
```

`agentCapabilities._fx.lifecycle` is the envelope revision, not a boolean, so
a later envelope is recognized without another handshake. The same identity
object is served on demand by `_fx/status`, which takes no parameters.

## Steering

`_fx/session/steer` takes `{ sessionId, text }` and answers
`{ turnId, disposition, snapshot }`.

* With a turn active the text is admitted into that turn. `disposition` is
  `steering` and `turnId` names the **active** turn, because that is the turn
  the person is redirecting. The model sees the text inside that turn rather
  than after it, pending tool calls are not cancelled, and the client's
  outstanding `session/prompt` still ends that turn with its own `stopReason`.
* With the session idle the text starts a turn. `disposition` is `queued` and
  `turnId` names the new turn.

The method never answers "Session is busy", and it is served whether or not a
prompt is in flight. Steering text is user-authored and is never reinterpreted
as a subagent message: the parent decides what to do with it.

Admission is the native FIFO the interactive shell uses. Steering targets the
active turn when it can and demotes in place to ordinary queued work when that
turn wins the race, exactly as the interactive path does.

## Snapshot

`_fx/session/snapshot` takes `{ sessionId }` and answers the authoritative
work snapshot plus the session's children:

```json
{
  "active_turn_id": "41",
  "queue_paused": false,
  "queue": [
    {
      "turn_id": "42",
      "kind": "steering",
      "text": "…",
      "has_images": false,
      "has_skill_bindings": false,
      "has_review_draft": false
    }
  ],
  "children": [
    { "id": "…", "name": "reviewer", "kind": "persistent", "phase": "awaiting_approval" }
  ]
}
```

Turn identities are decimal strings, matching the work-control socket. `kind`
is `queued` or `steering`; a child's `kind` is `one_off` or `persistent` and
its `phase` is `idle`, `running`, `awaiting_approval`, `interrupted`, or
`finished`. A one-off child has no agent name, so `name` is its session id.

## Lifecycle

Every lifecycle record is one `session/update` notification whose
`sessionUpdate` kind is `_fx/lifecycle`:

```json
{
  "sessionUpdate": "_fx/lifecycle",
  "event": "turn_ended",
  "sequence": 7,
  "turn_id": "41",
  "agent_role": "main",
  "agent_name": null,
  "agent_state": "idle",
  "attention_kind": null,
  "outcome": "completed",
  "provider_disposition": "completed"
}
```

`sequence` is monotonic per session and restarts at one for each session, so
`fx_started` is always sequence 1. `agent_state` is `idle`, `working`, or
`blocked` and `attention_kind` is `permission`, `question`, `route_recovery`,
or null; a non-null attention kind pairs only with `blocked`. Both come from
the same reducer the ADE event feed publishes, keyed independently per agent,
so any later record repairs a consumer that missed one.

The events are:

* `fx_started` and `stop` open and close a session's feed.
* `turn_started` and `turn_ended` bracket every main-agent and subagent turn.
  `turn_ended` adds `outcome` (`completed`, `interrupted`, `failed`, or
  `paused`) and `provider_disposition`.
* `attention_raised` and `attention_cleared` bracket a decision the agent is
  waiting on.
* `question_raised` adds `question_id`, `text`, `options`, and the complete
  `questions` batch.
* `child_changed` adds `child` with `id`, `name`, `kind`, and `phase`, and is
  published for every child phase transition.

`fx_started` opens a session's feed with that session's first record rather
than when the session is created, so a session that does nothing publishes
nothing and a client that is not watching sees no extra traffic. `stop`
closes a feed that opened.

Native `agent_message_chunk`, `tool_call`, and `tool_call_update` continue to
stream. `agent_message_chunk` gains one field, `turn_id`, so a client
accumulates a turn's assistant text by turn rather than by prompt boundary,
which a turn that admitted steering no longer matches:

```json
{
  "sessionUpdate": "agent_message_chunk",
  "messageId": "…",
  "turn_id": "41",
  "content": { "type": "text", "text": "…" }
}
```

The field is absent when no turn is active.

## Attention

When the main agent blocks on a permission, `fx acp` issues
`session/request_permission` to the client as usual and publishes
`attention_raised` beside it; the client's answer resumes the turn and
`attention_cleared` follows.

Upstream lets a child's approval reach a person only through its parent, so
this extension routes it the same way. When a child enters
`awaiting_approval`, `fx acp` publishes `child_changed` for the child and
`attention_raised { attention_kind: "permission", agent_name }` for the
**parent**, because the parent is what the person is talking to. It then
issues `session/request_permission` on the parent session carrying
`_fx: { agent_role: "subagent", agent_name, child_id }` so a voice agent can
say which child is asking. Answering that request clears both.

A question has no native ACP request, so the client answers it with
`_fx/session/question { sessionId, questionId, answer }`, or `answers` for a
batch of more than one question. The turn resumes on the answer. Cancelling
the session releases an outstanding question exactly as it releases a pending
permission.
