# libfx

`libfx` embeds fx agents and interactive terminals in JavaScript
applications. It supports Node.js hosts and browser environments with
JavaScript Promise Integration (JSPI).

## Installation

```sh
npm install libfx
```

Requirements:

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

```js
import { createFxAgent } from "libfx";

const agent = await createFxAgent({
  env: {
    AI_GATEWAY_API_KEY: process.env.AI_GATEWAY_API_KEY,
  },
  onEvent(event) {
    console.log(event.type);
  },
  async onPermission(request) {
    // Return one of request.options[*].optionId to approve it.
    // Returning null or undefined cancels the request.
    return null;
  },
});

const session = await agent.createSession();
const turn = session.prompt("Explain the files in this project.");

for await (const update of turn) {
  console.log(update);
}

console.log("Stopped:", await turn.stopReason);

await session.close();
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

`env.AI_GATEWAY_API_KEY` remains shorthand for Gateway authorization. An
explicit Gateway entry and the environment value may both be present only
when they are identical.

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

```js
const turn = session.prompt([
  { type: "text", text: "Summarize this file." },
  {
    type: "resource",
    resource: {
      uri: "file:///workspace/README.md",
      text: readmeContents,
    },
  },
]);
```

Image prompt blocks are not currently supported.

### Agent lifecycle

The object returned by `createFxAgent()` provides:

| Member | Description |
| --- | --- |
| `createSession()` | Creates a new active session |
| `openSession(id)` | Loads a stored session |
| `listSessions()` | Lists stored sessions |
| `close()` | Closes the active session and shuts down cleanly |
| `abort()` | Immediately aborts the runtime |
| `exited` | Promise that resolves with the process exit code |

A session provides:

| Member | Description |
| --- | --- |
| `prompt(input, options?)` | Starts an async iterable turn |
| `setModel(model)` | Changes the active model |
| `setMode(mode)` | Changes the active mode |
| `setConfig(config)` | Applies multiple configuration values |
| `close()` | Closes the active session |
| `remove()` | Removes the stored session |
| `history` | Previously loaded session updates |
| `configOptions` | Current configurable values |

Each session allows one active prompt at a time. Cancel a turn directly or
with an `AbortSignal`:

```js
const controller = new AbortController();
const turn = session.prompt("Wait for more instructions.", {
  signal: controller.signal,
});

controller.abort();
console.log(await turn.stopReason); // "cancelled"
```

## Browser agent

Browser hosts always use WebAssembly.

```js
import {
  createFxAgent,
  supportsJspi,
} from "libfx/browser";

if (!supportsJspi()) {
  throw new Error("This browser does not support WebAssembly JSPI.");
}

const agent = await createFxAgent({
  auth: { provider: "gateway", apiKey: "<short-lived credential>" },
});

const session = await agent.createSession();
const turn = session.prompt("Describe this workspace.");

for await (const update of turn) {
  console.log(update);
}
```

The browser entry point resolves `fx-core.wasm` and `fx-term.wasm` relative to
the installed package. Pass `wasm` explicitly to provide a URL, `Response`,
`ArrayBuffer`, typed array, or precompiled `WebAssembly.Module`.

Do not embed a long-lived API key in public browser code. Use a short-lived
credential or an authenticated server-side proxy.

Browser and direct WebAssembly agents support Gateway authorization only and
reject Codex authorization before instantiating WebAssembly.

## Interactive terminal

Install xterm.js in the host application:

```sh
npm install @xterm/xterm @xterm/addon-fit
```

Create the terminal and connect it to fx:

```js
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import {
  createFxTerminal,
  supportsJspi,
  xtermAdapter,
} from "libfx/browser";

if (!supportsJspi()) {
  throw new Error("This browser does not support WebAssembly JSPI.");
}

const terminal = new Terminal({
  cursorBlink: true,
  scrollback: 10_000,
});

const fit = new FitAddon();
terminal.loadAddon(fit);
terminal.open(document.querySelector("#terminal"));
fit.fit();

const runtime = await createFxTerminal({
  terminal: xtermAdapter(terminal),
  env: {
    AI_GATEWAY_API_KEY: "<short-lived credential>",
  },
});

await runtime.interactive;

window.addEventListener("resize", () => {
  fit.fit();
  runtime.resize();
});
```

The terminal runtime provides:

| Member | Description |
| --- | --- |
| `interactive` | Resolves after the terminal is ready for input |
| `exited` | Resolves with the terminal exit code |
| `write(data)` | Writes input directly to fx |
| `resize()` | Notifies fx of terminal geometry changes |
| `abort()` | Stops the terminal and releases subscriptions |

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
