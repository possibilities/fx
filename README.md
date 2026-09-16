```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://fx.sh/setup.sh | bash
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

fx is a coding agent CLI written in Zig: a 6.17 MiB native binary that is open source (Apache-2.0), model-agnostic, and embeddable as a harness in larger systems. Its interface stays closer to a Unix shell than an IDE in the terminal.

## Install

```bash
curl -fsSL https://fx.sh/setup.sh | bash
```

## Get started

Sign in with one of:

- `fx login`: Vercel AI Gateway
- `fx login codex`: ChatGPT subscription (OpenAI Codex OAuth)
- `fx login grok`: Grok subscription (xAI OAuth)
- `fx setup`: AI Gateway API key

Then start the interactive shell from a project:

```bash
cd your_project
fx
```

Or make a one-shot request:

```bash
fx ask "explain the changes in this repository"
```

Inside the shell, run `/help` to browse interactive commands.

Press `Ctrl+G` to edit the current prompt with `VISUAL`, falling back to `EDITOR`, even while a response is streaming; drafts containing pasted blocks, images, or skills are left unchanged. When an automatic upgrade is ready, press `Ctrl+T` to reload it.

### Automatic tool review

In auto mode, a valid structured safety decision remains usable when the reviewer adds commentary. If the response has no valid decision, fx retries the review once within its original 30-second deadline. A safety caution is never retried for approval. If review still fails, the action stays unexecuted and the agent can continue with other tools.

### Long conversations

fx automatically compacts context at 80% of the selected model's usable input capacity. Run `/compact` to compact earlier. In saved sessions, older assistant work is summarized while original user text stays unchanged and chronological when it fits. If necessary, older user messages are summarized too, without a capacity question.

Recent complete tool exchanges stay in context within a budget; older available results remain accessible through stored handles. Compaction uses the model's normal input/output limits and settings, validates the finished context, and switches only after the checkpoint is committed. Failed or cancelled compaction keeps the previous committed context. A saved session can resume from that checkpoint and later saved work.

## Custom model connections

The native CLI can use a user-configured OpenAI Chat Completions endpoint, including local servers and gateways such as Ollama and OpenRouter. Add named connections to `~/.fx/settings.json`; keep existing unrelated settings. For example:

```json
{
  "provider": "local",
  "providers": {
    "local": {
      "protocol": "openai-chat-completions",
      "base_url": "http://localhost:11434/v1",
      "auth": { "type": "none" }
    },
    "openrouter": {
      "protocol": "openai-chat-completions",
      "base_url": "https://openrouter.ai/api/v1",
      "auth": { "type": "bearer", "env": "OPENROUTER_API_KEY" }
    }
  },
  "models": {
    "local": "qwen2.5:7b",
    "openrouter": "openai/gpt-4.1"
  }
}
```

Use a model actually available on your server. `base_url` includes the API prefix, such as `/v1`; fx adds `/chat/completions`. Remote endpoints require HTTPS. Loopback HTTP is supported for local servers. Anonymous connections send no Authorization header; bearer connections read only their named environment variable, not a Gateway or subscription credential.

```bash
fx provider local
fx ask "explain this repository"
FX_PROVIDER=openrouter FX_MODEL=openai/gpt-4.1 fx ask "review this change"
fx status --json
```

`fx provider` saves a preference. `FX_PROVIDER` and `FX_MODEL` affect the invocation without rewriting settings. User-owned workspace overrides can select a connection; committed project `.fx.json` cannot define or select model endpoints. The interactive sign-in picker remains for built-in providers. Configured connections are selected through the file or CLI and work in the interactive shell, `fx ask`, and native ACP.

An explicit model does not require catalog discovery. `fx models` lists model IDs supplied in the connection's optional `model_metadata` object. Its per-model fields are `context_window`, `max_output_tokens`, `supports_tool_use`, and `supports_vision`. Set token limits to the server's actual configuration; without a known context window, automatic compaction cannot determine its threshold. Native image input is not yet implemented by this adapter, even if the backend supports it.

Text, reasoning, and function-tool streaming are supported through the Chat Completions endpoint. fx preserves `reasoning`, `reasoning_content`, and ordered `reasoning_details` across tool calls and saved-session continuation on the same connection and model. Signed and encrypted reasoning details stay opaque; they are not forwarded when the connection or model changes. Provider-specific reasoning controls and the Responses API are not part of this adapter.

Streams must include a finish reason followed by `[DONE]`; partial tool arguments never execute. Cumulative token-usage updates replace earlier observations rather than being added together. The default `tool_choice_mode` is `omit` for servers with partial OpenAI compatibility; set it to `send` only when the server supports that field. Tool controls are omitted when no tools are advertised, and required tool outcomes are still validated locally. The selected model and server must support function tools for coding-agent tasks.

Automatic permission review uses the selected model on the same connection. An optional `reviewer_model` in that connection can select another model there. A model that cannot produce a valid review decision leaves the action unapproved; fx never silently uses a cloud reviewer or changes permission mode. Gateway-only search, credits and vision fallback are unavailable on custom connections. Token usage is reported when provided; unknown cost is not treated as zero.

Saved custom sessions retain the connection name and a non-secret endpoint/authentication fingerprint. Changing or removing that connection prevents an implicit resume against a different destination. Existing history remains readable. Built-in sessions retain their existing provider representation; custom sessions require a build that supports configured connections. Invalid profile configuration fails model startup rather than falling back to Gateway. An unsafe profile directory still permits interactive inspection and local recovery, but model requests stay disabled until you repair the profile and restart fx.

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md) and [ACP documentation](https://fx.sh/docs/using-fx/acp).

The SDK is published to npm as [libfx](https://www.npmjs.com/package/libfx). For runnable Node.js, browser, Next.js, and Nuxt applications, see the [libfx examples](examples/README.md).

## Extend fx

- [Skills](https://fx.sh/docs/capabilities/skills): reusable instructions the agent loads when invoked
- [MCP](https://fx.sh/docs/capabilities/mcp): connect external tools and servers
- [Subagents](https://fx.sh/docs/capabilities/subagents): delegate independent work

## Documentation

Read the [fx documentation](https://fx.sh/docs) for sessions, models, permissions, configuration, and the full CLI and slash command references.

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/vercel-labs/fx.git
cd fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

A [bounded long-turn memory benchmark](docs/long-turn-memory.md) exercises saved turns against a local model fixture.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).

## Fork launch controls



On the first submitted prompt, fx starts a small naming request alongside the
main agent and installs the result as the session's native name without
delaying the turn. The Codex route defaults to `gpt-5.4-mini` at low effort;
other providers are skipped unless configured. Naming settings are profile
settings in `~/.fx/settings.json` and are ignored in project `.fx.json` files:

```json
{
  "session_naming": {
    "codex": {
      "model": "gpt-5.4-mini",
      "effort": "low"
    },
    "timeout_ms": 60000
  }
}
```

Set `codex` to `null` to disable its compiled default. Configure `gateway` or
`grok` with the same `model` and optional `effort` fields to opt those providers
in. Before naming, fx removes a leading slash command and its `--flag` tokens,
expands readable `@path` mentions up to 32 KiB each, and then limits the model
input to 1600 bytes. Generated names are limited to 64 bytes. `/rename` always
wins over an in-flight generated result.

- [ADE event feed](docs/ade-event-feed.md): observe hosted TUI agent lifecycle

Customize the system prompt for one model-launching invocation with global
file options placed before the command:

```bash
fx --system-prompt-file ./base-prompt.md ask "review this change"
fx --append-system-prompt-file ./team-rules.md --append-system-prompt-file ./task-rules.md
```

`--system-prompt-file` replaces the effective base prompt and may be supplied
once. `--append-system-prompt-file` preserves that base and adds files in CLI
order, separated by blank lines. The options also apply to interactive and
resumed sessions, ACP, `pr`, and `issue`. Custom prompt files must be regular
UTF-8 files without NUL bytes and may contain at most 256 KiB combined. File
errors stop the launch. For `fx ask`, these options cannot be combined with
the inline `--system` option.

Use `--permissions-file <path>` before an interactive launch, resume command, or `acp` command to replace profile, workspace, and project permission rules for that process. The file uses the same permission-rule JSON shape as `settings.json`; saved-session exact grants still apply, but cannot override a deny from the launch policy:

```json
{
  "bash": {
    "git *": "allow",
    "git push *": "deny"
  },
  "edit": "deny"
}
```



For a repository-neutral interactive TUI or ACP process, launch Fx with the
global `--no-project-instructions` option. Fx omits `AGENTS.md`, `CLAUDE.md`,
and compatible scoped instruction prose for that process while retaining
runtime context such as the working directory, date, Git state, tool guidance,
and permission guidance.



Load additional skill roots for one invocation with repeatable `--skills-dir`
flags. Each root contains one directory per skill and is scanned before
automatically discovered roots:

```bash
fx --skills-dir ./team-skills --skills-dir /opt/shared-skills ask "Review this change"
```

Invocation skill roots are not saved, and skill installation continues to use
`~/.fx/skills`.

Interactive TUI and ACP launches can disable Fx-native tools with the global
`--no-native-tools` option, or select an ordered allowlist with repeatable
`--tool <name>`. The `terminal:exec` selection exposes only one-shot terminal
commands, without interactive terminal-session actions. ACP can independently
reject client-supplied MCP servers with `fx acp --no-acp-mcp`.

Run `fx --state-dir <path>` for an interactive session, or
`fx --state-dir <path> acp` for ACP, when the agent needs an isolated Fx
profile. The directory must already exist; Fx keeps its settings,
authorization, profile instructions, profile-global skills, MCP state,
memories, usage, prompt history, and sessions beneath `<path>/.fx` while
terminal tools and MCP processes retain the normal `HOME` environment.

An isolated launch can borrow one already-valid saved credential without
copying it into that state root. Set `FX_AUTH_READ_ONLY_HOME` to the canonical
home of another Fx profile and select the process provider with
`FX_PROVIDER=gateway|codex|grok`. `FX_MODEL` supplies the process model when
the isolated profile has no model for that provider. The borrowed profile is
read only: Fx does not refresh, replace, or delete its credential, and every
setting, session, history, skill, MCP entry, and authentication action remains
owned by `--state-dir`. Fx rejects this authorization override when no
`--state-dir` is selected.

`--state-dir` sets three things at once: where the agent's shape comes from,
which account it uses, and where its history is written. Each is also selectable
on its own, so one common history can hold work from several agents and
accounts:

```bash
fx --shape ~/shapes/reviewer                  # prompt, skills, MCP from that root
fx --identity ~/fx-work                       # borrow that profile's credential
fx --history-dir ~/fx-history                 # own sessions, history, and usage
fx --mcp-config ~/shapes/reviewer/servers.json
```

`--shape <dir>` reads `<dir>/.fx/SYSTEM.md` or `<dir>/.fx/SYSTEM_APPEND.md`,
adds `<dir>/.fx/skills` as a skill root, and uses `<dir>/.fx/mcp.json` when it
exists. It moves no credentials and no sessions, and its conventional prompt
wins over `--state-dir`'s. `--mcp-config <file>` selects that configuration
directly; MCP credentials stay with the profile home either way.

`--identity <dir>` borrows one already-valid credential from that profile under
the same read-only contract as `FX_AUTH_READ_ONLY_HOME`: Fx does not refresh,
replace, or delete it, and a credential due for refresh is declined rather than
rewritten. Unlike the environment form, which still requires `--state-dir`, the
flag stands on its own; naming both is refused.

`--history-dir <dir>` owns sessions, prompt history, and usage. Without it,
history stays with the profile home, so `--state-dir` isolates all three exactly
as before.

Every session records the shape and account that created it, and `fx sessions`
names them:

```
 - review the parser
   id=fnGq6VphbKjL | 1 turn | reviewer @ codex:6f4a132b990e | updated 2026-09-04 15:17:53 UTC
```

The stored label is for reading; a content digest stored beside it decides
whether two sessions are the same shape. `fx sessions --json` reports both as
`shape` and `shape_identity`, alongside `credential_source` and the full
non-secret `credential_identity` digest. Text listings and the resume picker
show a 12-character account digest beside the source, distinguishing accounts
using the same provider. ACP `session/list` exposes this provenance in its
additive `_meta.fx.provenance` object as `shape`, `shapeIdentity`,
`credentialSource`, and `credentialIdentity`. Older sessions without recorded
provenance remain readable. A turn that may already have reached the provider
refuses to resume under a different shape or a different account.

An explicit state directory can also carry one conventional system prompt for
interactive, resumed, and ACP sessions and their in-process children.
`<path>/.fx/SYSTEM.md` replaces Fx's built-in prompt, while
`<path>/.fx/SYSTEM_APPEND.md` appends to it. The names are case-sensitive, and
a launch fails if both files exist. `--system-prompt-file` bypasses this state
discovery; repeatable `--append-system-prompt-file` values are added afterward.
The same regular-file, UTF-8, NUL-free, and combined 256 KiB limits apply.
`--no-project-instructions` does not suppress the selected state prompt, and Fx
does not discover these files from the default home without `--state-dir`.
