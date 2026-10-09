# Libfx provider authorization is credential-led

Native libfx accepts one tagged provider authorization or an ordered list, with
the first entry selecting the initial provider and later switching limited to
that list. Codex sessions come only from an explicit optimistic host store or
an explicit `fxProfileSession()` opt-in, because an ordinary library home must
never grant ambient ChatGPT credential access. Browser and direct WebAssembly
libfx remain Gateway-only, and native libfx carries Gateway and Codex without
Grok.

The first accepted Codex credential pins the runtime to that ChatGPT account.
Every later store load validates the account before OAuth refresh or write-back.
Store timeouts fail the native operation immediately, but an abort-ignoring
host promise retains only its operation-owned copy until settlement. The timed
out runtime closes so a never-settling promise cannot strand a later request.
The ordinary libfx `home` also owns profile usage state; ambient `HOME` is not
consulted when an explicit library home is present.

The configured-provider launch surface introduced upstream does not widen a
libfx host's authorization list. Native ACP keeps named configured providers,
while libfx advertises and admits only its explicitly supplied Gateway/Codex
provider tags. Credential preparation stages new storage until existing session
borrowers stop. A process-wide source-only recent-verification stamp is never
sufficient for Codex: independent libfx stores and account pins must still be
validated on the request path.

The upstream durable-session facade does not replace this contract. It defers
authorization until a turn, re-creates engines across deliveries, and supplies
ambient Gateway credentials. Re-creating an engine would also reset the
selected-account pin. Keep the eagerly authorized single-conversation Agent;
`createFxEngine()` names that same factory. Its explicit journal persistence,
checkpoint recovery, steering, and raw attachment transport can be retained
without exposing sub-sessions or selecting background workers and stores.
Provider authorization remains owned by the live Agent and is never recovered
from conversation persistence. The package declarations and supported SDK
documentation follow this surface.

A single-session wrapper around the durable facade could hide sub-sessions
and await initial authorization. That alone would not keep the selected-account
pin or configuration across replacement engines. Retaining queue delivery,
worker takeover, and redeployment would require a new authorization-lifetime
contract outside the native runtime, including where the account pin lives and
how a replacement worker receives it. Holding one engine instead would remove
those durability guarantees. Neither change is part of this carry's contract.

The supported Agent therefore does not select local or Vercel storage, expose
queue wake handlers, or automatically resume work after process loss. Hosts
can still supply explicit engine persistence, restore checkpoints, and resume
interrupted turns. The optional upstream durability modules remain separate;
they do not select credentials or storage for the supported Agent.
