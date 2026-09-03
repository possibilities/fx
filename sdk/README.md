# libfx

`libfx` is the small fx agent kernel for JavaScript hosts. One agent is one
in-memory conversation with three operations: `prompt`, `checkpoint`, and
`close`.

```sh
npm install libfx
```

Node.js uses the native addon when available and falls back to WebAssembly.
Browsers use WebAssembly with JSPI. The default package has no runtime
dependencies and performs no MCP connection, skill scan, process spawn, or
filesystem read when imported.

- Node.js 20 or later
- Chrome or Edge 137 or later for browser WebAssembly
- JSPI when using the WebAssembly backend
- A Vercel AI Gateway credential, or a Codex subscription session with the
  native Node backend

The package includes:

- Native Node addons for Linux and macOS on x64 and arm64
- `fx-core.wasm` for headless agents
- `fx-term.wasm` for interactive terminals
- A dependency-free JavaScript host layer

## Exports

| Import | Environment | Description |
| --- | --- | --- |
| `libfx` | Node.js or browser | Environment-aware default |
| `libfx/node` | Node.js | Native-first Node entry point |
| `libfx/browser` | Browser | WebAssembly browser entry point |
| `libfx/wasm` | Browser or Node.js | Direct WebAssembly host layer |

Public exports:

- `createFxAgent()` creates a headless ACP agent.
- `createFxTerminal()` runs the interactive fx terminal.
- `supportsJspi()` detects WebAssembly JSPI support.
- `xtermAdapter()` connects fx to an xterm.js terminal.
- `encodeXtermKeyEvent()` translates browser keyboard events into terminal input.
- `fxProfileSession()` explicitly opts a native Node agent into the fx profile's
  Codex session.

## Headless agent

The default Node entry point prefers the native addon and falls back to
WebAssembly when necessary.
## Agent

```js
import { createFxAgent } from "libfx";

const agent = await createFxAgent({
  apiKey: process.env.AI_GATEWAY_API_KEY,
  model: "google/gemini-2.5-flash-lite",
});

const turn = agent.prompt("Explain this project.");

for await (const event of turn) {
  if (event.type === "text_delta") process.stdout.write(event.delta);
}

console.log(await turn.result); // { stopReason, usage }
const checkpoint = await agent.checkpoint();
await agent.close();
```

### Provider authorization

`auth` accepts one authorization or an ordered list. The first entry selects
the initial provider, and a session may switch only to another provider named
in that list:

```js
import { createFxAgent, fxProfileSession } from "libfx/node";

const agent = await createFxAgent({
  backend: "native",
  auth: [
    { provider: "codex", session: fxProfileSession() },
    { provider: "gateway", apiKey: process.env.AI_GATEWAY_API_KEY },
  ],
});

const session = await agent.createSession();
await session.setConfig({ provider: "gateway" });
```

A tagged `auth` entry is translated into libfx's own `apiKey` and `model`
options before the agent starts, so `auth` and `apiKey` may both be present
only when they name the same credential.

Codex is native-only. It never reads the fx profile implicitly. Use
`fxProfileSession()` to opt into `~/.fx/chatgpt-auth.json`, or provide a host
store for an application-owned OAuth session:

```js
const codexSessionStore = {
  async load({ signal }) {
    const snapshot = await secrets.read("codex", { signal });
    return snapshot && {
      bytes: snapshot.bytes,
      revision: snapshot.revision,
    };
  },
  async commit(bytes, expectedRevision, { signal }) {
    return secrets.compareAndSwap("codex", {
      bytes,
      expectedRevision,
      signal,
    }); // { revision }
  },
};

const agent = await createFxAgent({
  backend: "native",
  auth: { provider: "codex", session: codexSessionStore },
});
```

Session bytes are opaque and may contain access and refresh tokens. `load()`
returns `null` or `{ bytes: Uint8Array, revision: string }`; `commit()` returns
`{ revision: string }`. A compare-and-swap conflict must throw an error whose
`code` is `FX_CODEX_SESSION_REVISION_CONFLICT`. Operations receive an
`AbortSignal`, time out after 30 seconds, and must not log or retain the bytes.
If a store ignores cancellation, libfx reports the failure promptly, keeps an
operation-owned credential copy only until that promise settles, and closes
the timed-out native runtime so no later request can wedge behind it. Once an
agent has selected a Codex account, a replacement snapshot for a different
account is rejected before refresh or write-back.

A prompt may be a string or an array of text and resource blocks:
`apiKey` is required. `model` is optional and defaults to fx's built-in model.
Agent configuration uses named options; `env` is reserved for
`createFxTerminal()`.

`prompt(input, { signal? })` accepts a string or text/resource blocks. It
returns an async iterable of normalized events:

- `text_delta`
- `reasoning_delta` when supplied by the provider
- `tool_start`
- `tool_end`

Only one prompt may run at a time. `checkpoint()` is idle-only and returns
opaque, bounded, versioned bytes. Restore them only when creating a fresh
agent:

```js
const restored = await createFxAgent({ apiKey, model, checkpoint });
```

The checkpoint contains conversation history and usage only. The host owns
durable storage and must resupply models, credentials, instructions, tools,
MCP clients, and skill records.

## JavaScript tools and instructions

```js
const agent = await createFxAgent({
  apiKey,
  model,
  instructions: "Keep answers concise.",
  tools: [{
    name: "lookup",
    description: "Look up a value.",
    inputSchema: {
      type: "object",
      properties: { key: { type: "string" } },
      required: ["key"],
    },
    async execute(input, { signal }) {
      return database.get(input.key, { signal });
    },
  }],
});
```

The JavaScript host is the authority for tool effects. The same descriptors,
schemas, cancellation, results, and events are used by N-API and WebAssembly.
Instructions are limited to 64 KiB of UTF-8 text, including text assembled by
the MCP and skills adapters.

## MCP

`libfx/mcp` accepts a host-owned MCP client. Transport, authentication,
elicitation, and cleanup remain outside the kernel.

```js
import { createMcpAdapter } from "libfx/mcp";

const mcp = await createMcpAdapter(client, {
  prefix: "github_",
  resources: ["repo://instructions"],
  prompts: ["review"],
});

const agent = await createFxAgent({
  auth: { provider: "gateway", apiKey: "<short-lived credential>" },
  model,
  tools: mcp.tools,
  instructions: mcp.instructions,
});

// ...
await agent.close();
await mcp.close();
```

## Skills

Use `libfx/skills` for already-loaded records or `libfx/skills/node` to load a
`SKILL.md` explicitly in Node or Bun.

```js
import { loadSkillFile } from "libfx/skills/node";
import { createSkillsAdapter } from "libfx/skills";

const record = await loadSkillFile("./skills/review/SKILL.md");
const skills = createSkillsAdapter([record]);
const agent = await createFxAgent({ apiKey, model, ...skills });
```

## Backends

```js
await createFxAgent({ apiKey, backend: "auto" });   // native, then Wasm fallback
await createFxAgent({ apiKey, backend: "native" }); // require N-API
await createFxAgent({ apiKey, backend: "wasm" });   // require Wasm + JSPI
```

Within one JavaScript realm, libfx compiles each stable Wasm source once and
creates a separate WebAssembly instance for every Agent. Agent memory, history,
tools, cancellation, and shutdown remain isolated. Workers and separate
processes maintain their own module caches.

Node.js 20+ is supported. Browser WebAssembly requires a JSPI-capable browser.
Some Node versions require `--experimental-wasm-jspi`.

Browser and direct WebAssembly agents support Gateway authorization only and
reject Codex authorization before instantiating WebAssembly.

## Interactive terminal

`createFxTerminal()` remains a separate terminal harness API. In browsers,
connect it to xterm.js with `xtermAdapter()`:

```js
import { createFxTerminal, xtermAdapter } from "libfx/browser";

const runtime = await createFxTerminal({
  terminal: xtermAdapter(term),
  env: { AI_GATEWAY_API_KEY: "<short-lived credential>" },
});

await runtime.interactive;
```

The terminal runtime exposes `interactive`, `exited`, `write`, `resize`, and
`abort`. Terminal session, config, OAuth, prompt-history, URL, and workspace
stores remain terminal-only host integrations.

## Security

Try the hosted terminal at [fx.sh/try](https://fx.sh/try).

## Backend selection

Node hosts may select a backend explicitly:

```js
const agent = await createFxAgent({
  backend: "native",
});
```

| Backend | Behavior |
| --- | --- |
| `auto` | Prefer a compatible native addon and fall back to WebAssembly |
| `native` | Require the native backend and fail if it cannot load |
| `wasm` | Require WebAssembly and JSPI |

The native loader checks `libfx.node` followed by the platform-specific addon:

```text
libfx.<platform>-<arch>.node
```

Supported packaged targets:

- `linux-x64`
- `linux-arm64`
- `darwin-x64`
- `darwin-arm64`

If no compatible native backend is available and JSPI cannot run, startup
rejects with:

```js
error.code === "LIBFX_JSPI_REQUIRED"
```

On Node versions where JSPI remains behind a flag, start the process with:

```sh
node --experimental-wasm-jspi app.mjs
```

## Host integrations

Hosts may provide adapters for runtime state and external effects:

| Option | Purpose |
| --- | --- |
| `fetch` | Routes Gateway requests through the host |
| `env` | Supplies runtime configuration without changing process globals |
| `onEvent` | Receives runtime, ACP, terminal, and lifecycle events |
| `onPermission` | Resolves agent permission requests |
| `configStore` | Persists accepted configuration values |
| `sessionStore` | Persists agent or terminal sessions |
| `oauthSessionStore` | Persists browser device-login sessions |
| `promptHistoryStore` | Stores terminal prompt history |
| `openUrl` | Opens authentication and verification URLs |
| `workspace` | Provides the constrained browser workspace adapter |

## Security boundaries

`nativeAddon` and `env.FX_GATEWAY_CHAT_URL` are trusted host configuration. Do
not populate them from request, tenant, or other untrusted input.

The native backend sends Gateway credentials only through the host `fetch`
boundary to the canonical Vercel AI Gateway endpoint. Custom Gateway endpoints
are limited to explicit loopback HTTP URLs for local development. With explicit
Codex authorization, the native provider sends the supplied ChatGPT OAuth
credential to OpenAI's canonical ChatGPT Codex and OAuth endpoints. The host
application is trusted with any Codex session it supplies or elects to read
through `fxProfileSession()`.

The WebAssembly runtime intentionally does not provide:

- Native processes
- OS sandboxing
- Native MCP servers
- Subagents or skills
- Automatic upgrades
- Clipboard integration
- Arbitrary WASI filesystem access
- Public web fetch, web search, and general outbound network access

The embedded runtime tells the model not to retry unavailable network work
through shell commands. Use locally installed fx when the full native tool
suite is required.

The optional browser workspace exposes completion-only shell execution through
the typed contract:

```js
{ action: "run", command }
```

The host remains responsible for admitting commands, enforcing limits, and
returning bounded output.

## Local development

From the fx repository root, build the native addon and both WebAssembly
surfaces:

```sh
zig build -Dnapi-surface=core -Doptimize=ReleaseSafe
zig build -Dwasm-surface=core -Doptimize=ReleaseSmall
zig build -Dwasm-surface=term -Doptimize=ReleaseSmall
```

Run the SDK test suites:

```sh
npm ci --prefix sdk/node
npm run --prefix sdk test:node-napi
npm run --prefix sdk test:node-wasm
```

Serve the repository:

```sh
python3 -m http.server 8080
```

After starting the server, open these local URLs:

```text
Core debugger:        http://localhost:8080/sdk/index.html
Interactive terminal: http://localhost:8080/sdk/term-demo.html
```

These are local development pages and are not publicly hosted links.

Maintainer references:

- [SDK contributor guide](https://github.com/vercel-labs/fx/blob/main/sdk/AGENTS.md)
- [Native Node-API design and security model](https://github.com/vercel-labs/fx/blob/main/sdk/NAPI.md)

Treat `nativeAddon` and `gatewayChatUrl` as trusted host
configuration. Do not embed long-lived credentials in public browser code.
Host tool functions, MCP clients, and skill loaders retain their own authority;
libfx validates and sequences them but does not grant operating-system access.
