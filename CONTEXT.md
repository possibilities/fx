# CONTEXT

The project's language. Terms here are the canonical spelling for code, flags,
commit messages, and documentation.

## Shape

What an agent instance *is*: the resolved system prompt, skill roots, MCP
configuration, native-tool selection, and permission policy that together decide
how it behaves. A shape is selected with `--shape <dir>`, which reads that
root's `.fx/SYSTEM.md` (or `SYSTEM_APPEND.md`), `.fx/skills`, and `.fx/mcp.json`
and nothing else. Shape says nothing about who pays for a request.

_Avoid_: profile, persona, agent definition, config.

## Identity

Who a request is billed to: a provider plus the credential and account behind
it. Selected with `--identity <dir>`, which borrows another profile's already
valid credential read-only, or inherited from the ambient profile. Identity says
nothing about how the agent behaves.

_Avoid_: account (alone), auth, credential (when the account is meant), login.

## History root

The directory owning a launch's sessions, prompt history, and usage, selected
with `--history-dir <dir>`. When none is selected the profile home owns history,
so `--state-dir` still isolates shape, identity, and history together.

_Avoid_: session dir, store, profile.

## Profile root

A whole `<home>/.fx` directory: settings, credentials, sessions, history, usage,
skills, and MCP state. `--state-dir` relocates one, which sets all three axes at
once. A profile root is the bundle, never one axis of it.

_Avoid_: state dir (in prose), home, workspace.

## Provenance

The record of the shape and identity that produced a piece of history, stored
beside it: on a session at creation, and on each usage generation. Provenance is
written once and never rewritten, so it says what created a history rather than
what is reading it now.

_Avoid_: metadata, attribution, tags.

## Shape authority

The digest of a resolved shape declaration, derived by
`core/auth/shape_authority.zig`. It is the authority for whether two records are
the same shape; the human label stored beside it is for reading, never for
comparing. Named after `credential_authority`, its identity-axis sibling.

_Avoid_: shape hash, shape id (when the digest is meant), fingerprint.
