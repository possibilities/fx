import { access, readFile } from "node:fs/promises";
import { closeSync } from "node:fs";
import { createRequire } from "node:module";
import { Socket } from "node:net";
import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { CoreOutput } from "./core-output.js";
import {
  createFxAgent as createWasmAgent,
  createFxTerminal as createWasmTerminal,
  encodeXtermKeyEvent,
  fxSdkApiVersion,
  listModels,
  supportsJspi,
  xtermAdapter,
} from "./fx-sdk.js";
import { authorizeNativeHostOptions } from "./internal.js";

export { encodeXtermKeyEvent, fxSdkApiVersion, listModels, supportsJspi, xtermAdapter };
export const libfxApiVersion = 3;
const nativeCoreApiVersion = 3;

const fetchOperationStale = 0;
const fetchOperationApplied = 1;
const fetchOperationBackpressure = 2;
const sessionOperationStale = 0;
const sessionOperationApplied = 1;
const sessionStatusSuccess = 0;
const sessionStatusMissing = 1;
const sessionStatusConflict = 2;
const sessionStatusFailure = 3;
const defaultCodexSessionTimeoutMs = 30_000;
const profileSessionBrand = Symbol("libfx.profile-session");
const normalizedAuthBrand = Symbol("libfx.normalized-auth");

const require = createRequire(import.meta.url);
const defaultCoreWasm = new URL("./fx-core.wasm", import.meta.url);
const defaultTermWasm = new URL("./fx-term.wasm", import.meta.url);
const defaultNativeCandidates = [
  "./libfx.node",
  `./libfx.${process.platform}-${process.arch}.node`,
];
let nativeBackendPromise;
const wasmFilePromises = new Map();

function codexSessionTimeoutMs() {
  const configured = process.env.FX_E2E_CODEX_SESSION_TIMEOUT_MS;
  if (configured === undefined) return defaultCodexSessionTimeoutMs;
  const value = Number(configured);
  return Number.isSafeInteger(value) && value > 0 && value <= defaultCodexSessionTimeoutMs
    ? value
    : defaultCodexSessionTimeoutMs;
}

export function fxProfileSession(options = {}) {
  if (!options || typeof options !== "object" || Array.isArray(options)) {
    throw new TypeError("fxProfileSession options must be an object");
  }
  const keys = Object.keys(options);
  if (keys.some((key) => key !== "home")) throw new TypeError("fxProfileSession accepts only home");
  const home = options.home ?? homedir();
  if (typeof home !== "string" || !isAbsolute(home)) {
    throw new TypeError("fxProfileSession home must be an absolute path");
  }
  return Object.freeze({ [profileSessionBrand]: true, home });
}

function normalizeAgentAuth(options) {
  const flatApiKey = options.apiKey;
  const explicit = options.auth === undefined
    ? []
    : (Array.isArray(options.auth) ? options.auth : [options.auth]);
  if (options.auth !== undefined && explicit.length === 0) {
    throw new TypeError("auth must contain at least one provider authorization");
  }

  const entries = [];
  const providers = new Set();
  for (const entry of explicit) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      throw new TypeError("each auth entry must be an object");
    }
    if (entry.provider !== "gateway" && entry.provider !== "codex") {
      throw new TypeError('auth provider must be "gateway" or "codex"');
    }
    if (providers.has(entry.provider)) throw new TypeError(`auth contains duplicate ${entry.provider} authorization`);
    providers.add(entry.provider);
    if (entry.provider === "gateway") {
      if (Object.keys(entry).some((key) => key !== "provider" && key !== "apiKey")) {
        throw new TypeError("Gateway auth accepts only provider and apiKey");
      }
      if (typeof entry.apiKey !== "string" || !entry.apiKey.length) {
        throw new TypeError("Gateway auth requires a non-empty apiKey");
      }
      entries.push({ provider: "gateway", apiKey: entry.apiKey });
      continue;
    }
    if (Object.keys(entry).some((key) => key !== "provider" && key !== "session")) {
      throw new TypeError("Codex auth accepts only provider and session");
    }
    const session = entry.session;
    const profile = session?.[profileSessionBrand] === true;
    const store = session && typeof session.load === "function" && typeof session.commit === "function";
    if (profile === store) {
      throw new TypeError("Codex auth requires fxProfileSession() or a session store with load() and commit()");
    }
    entries.push({ provider: "codex", session, profile, store });
  }

  if (!providers.has("gateway") && flatApiKey !== undefined) {
    providers.add("gateway");
    entries.push({ provider: "gateway", apiKey: flatApiKey });
  } else if (providers.has("gateway") && flatApiKey !== undefined) {
    const explicitGateway = entries.find((entry) => entry.provider === "gateway");
    if (explicitGateway.apiKey !== flatApiKey) {
      throw new TypeError("Gateway auth conflicts with apiKey");
    }
  }
  if (entries.length === 0) entries.push({ provider: "gateway", apiKey: flatApiKey });

  const codex = entries.find((entry) => entry.provider === "codex");
  const gateway = entries.find((entry) => entry.provider === "gateway");
  const { auth: _auth, ...rest } = options;
  const normalizedOptions = {
    ...rest,
    ...(gateway?.apiKey === undefined ? {} : { apiKey: gateway.apiKey }),
    [normalizedAuthBrand]: {
      initialProvider: entries[0].provider,
      gateway,
      codex,
    },
  };
  return normalizedOptions;
}

function jspiFallbackError(surface, nativeError) {
  const nativeDetail = nativeError ? ` Native loading failed: ${nativeError.message}.` : " No compatible native addon was found.";
  const error = new Error(
    `libfx could not start the ${surface} backend.${nativeDetail} ` +
    "The WebAssembly fallback requires JavaScript Promise Integration (JSPI). " +
    "Run Node with --experimental-wasm-jspi or install a libfx package containing a compatible native addon.",
  );
  error.code = "LIBFX_JSPI_REQUIRED";
  error.cause = nativeError;
  return error;
}

async function loadNativeCandidate(candidate) {
  if (candidate == null) return null;
  if (candidate instanceof URL) {
    if (candidate.protocol === "file:" && candidate.pathname.endsWith(".node")) {
      return require(fileURLToPath(candidate));
    }
    const imported = await import(candidate.href);
    return imported.default ?? imported;
  }
  if (typeof candidate === "object") return candidate.default ?? candidate;
  if (typeof candidate !== "string") {
    throw new TypeError("nativeAddon must be a module, path, URL, false, or undefined");
  }
  if (candidate.endsWith(".node")) return require(isAbsolute(candidate) ? candidate : resolve(candidate));
  const imported = await import(candidate.startsWith("file:") ? candidate : pathToFileURL(candidate).href);
  return imported.default ?? imported;
}

function validateNativeBackend(backend) {
  if (!backend) return null;
  const hasLowLevelCore = typeof backend.createCore === "function";
  const expectedVersion = hasLowLevelCore ? nativeCoreApiVersion : libfxApiVersion;
  if ((hasLowLevelCore || backend.libfxApiVersion !== undefined) && backend.libfxApiVersion !== expectedVersion) {
    const actualVersion = backend.libfxApiVersion ?? "missing";
    throw new Error(`native addon API version ${actualVersion} is incompatible with expected API version ${expectedVersion}`);
  }
  if (typeof backend.createCore !== "function" && typeof backend.createFxTerminal !== "function") {
    throw new Error("native addon must export createCore() or createFxTerminal()");
  }
  return backend;
}

async function discoverNativeBackend() {
  for (const relativePath of defaultNativeCandidates) {
    const url = new URL(relativePath, import.meta.url);
    try {
      await access(fileURLToPath(url));
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      return { backend: null, error };
    }
    try {
      return { backend: validateNativeBackend(await loadNativeCandidate(url)), error: null };
    } catch (error) {
      return { backend: null, error };
    }
  }
  return { backend: null, error: null };
}

async function resolveNativeBackend(nativeAddon) {
  if (nativeAddon === false) return { backend: null, error: null };
  if (nativeAddon !== undefined) {
    try {
      return { backend: validateNativeBackend(await loadNativeCandidate(nativeAddon)), error: null };
    } catch (error) {
      return { backend: null, error };
    }
  }
  nativeBackendPromise ??= discoverNativeBackend();
  return nativeBackendPromise;
}

function wasmBytes(input) {
  let path;
  if (input instanceof URL && input.protocol === "file:") path = fileURLToPath(input);
  else if (typeof input === "string" && !URL.canParse(input)) path = resolve(input);
  else return input;
  const cached = wasmFilePromises.get(path);
  if (cached) return cached;
  const pending = readFile(path);
  wasmFilePromises.set(path, pending);
  pending.catch(() => {
    if (wasmFilePromises.get(path) === pending) wasmFilePromises.delete(path);
  });
  return pending;
}

function createNativeCoreRuntime(addon, options) {
  const auth = options[normalizedAuthBrand] ?? normalizeAgentAuth(options)[normalizedAuthBrand];
  const { model, gatewayChatUrl } = options;
  const apiKey = auth.gateway?.apiKey ?? options.apiKey;
  const core = addon.createCore({
    ...(apiKey === undefined ? {} : { apiKey }),
    provider: auth.initialProvider,
    allowGateway: Boolean(auth.gateway),
    allowCodex: Boolean(auth.codex),
    ...(auth.codex?.profile ? { codexProfileHome: auth.codex.session.home } : {}),
    codexSessionStore: Boolean(auth.codex?.store),
    home: options.home ?? homedir(),
    workspaceRoot: options.workspaceRoot ?? process.cwd(),
    ...(model === undefined ? {} : { model }),
    ...(gatewayChatUrl === undefined ? {} : { gatewayChatUrl }),
  });
  let readyFd;
  let readySocket;
  try {
    readyFd = addon.takeCoreReadyFd(core);
    readySocket = new Socket({ fd: readyFd, readable: true, writable: false });
  } catch (error) {
    if (readyFd !== undefined) {
      try { closeSync(readyFd); } catch {}
    }
    addon.destroyCore(core);
    throw error;
  }
  const readyClosed = new Promise((resolve) => readySocket.once("close", resolve));
  let exitedResolve;
  let lineHandler = null;
  const output = new CoreOutput((message, size) => lineHandler(message, size));
  let draining = false;
  let outputError;
  let settled = false;
  let fetchState = null;
  let codexSessionState = null;
  const exited = new Promise((resolve) => { exitedResolve = resolve; });
  const abortHostEffects = () => {
    fetchState?.controller.abort();
    codexSessionState?.controller.abort();
    try { addon.abortCoreFetch(core); } catch {}
  };
  const finish = (code, error) => {
    if (settled) return;
    settled = true;
    outputError = error;
    output.close();
    abortHostEffects();
    try { addon.destroyCore(core); } catch {}
    readySocket.destroy();
    void readyClosed.then(() => exitedResolve(code));
  };
  const pumpFetch = async (request) => {
    const controller = new AbortController();
    const state = { handle: request.handle, controller };
    fetchState = state;
    const requestBody = request.body?.length ? Buffer.from(request.body, "base64") : undefined;
    try {
      const response = await (options.fetch ?? globalThis.fetch)(request.url, {
        method: request.method,
        headers: new Headers(JSON.parse(request.headers).map(({ name, value }) => [name, value])),
        body: requestBody,
        signal: controller.signal,
      });
      const started = addon.startCoreFetchResponse(core, state.handle, response.status);
      if (started === fetchOperationStale) return;
      if (started !== fetchOperationApplied) throw new Error(`invalid native fetch start result ${started}`);
      if (response.body) {
        for await (const chunk of response.body) {
          const buffer = Buffer.from(chunk);
          let offset = 0;
          while (offset < buffer.length) {
            const end = Math.min(offset + 64 * 1024, buffer.length);
            const pushed = addon.pushCoreFetchResponse(core, state.handle, buffer.subarray(offset, end));
            if (pushed === fetchOperationApplied) {
              offset = end;
              continue;
            }
            if (pushed === fetchOperationStale) return;
            if (pushed !== fetchOperationBackpressure) throw new Error(`invalid native fetch push result ${pushed}`);
            await new Promise((resolve) => setTimeout(resolve, 2));
          }
        }
      }
      const finished = addon.finishCoreFetch(core, state.handle);
      if (finished !== fetchOperationApplied && finished !== fetchOperationStale) {
        throw new Error(`invalid native fetch finish result ${finished}`);
      }
    } catch (error) {
      if (error?.name !== "AbortError" || !controller.signal.aborted) {
        try {
          if (addon.coreFetchActive(core, state.handle)) addon.failCoreFetch(core, state.handle);
        } catch {}
      }
    } finally {
      requestBody?.fill(0);
      if (fetchState === state) {
        fetchState = null;
        queueMicrotask(drainReady);
      }
    }
  };
  const finishCodexSessionOperation = (request, status, bytes = Buffer.alloc(0), revision = "") => {
    const result = addon.finishCoreCodexSessionOperation(core, request.handle, status, bytes, revision);
    if (result !== sessionOperationApplied && result !== sessionOperationStale) {
      throw new Error(`invalid native Codex session operation result ${result}`);
    }
  };
  const pumpCodexSession = async (request) => {
    const controller = new AbortController();
    const state = { handle: request.handle, controller };
    codexSessionState = state;
    const store = auth.codex?.session;
    let timeout;
    let operation;
    let operationBytes;
    let operationSettled = true;
    let adapterSettled = false;
    let responseBytes;
    const releaseState = () => {
      if (codexSessionState === state) codexSessionState = null;
    };
    const settleOperation = () => {
      operationSettled = true;
      operationBytes?.fill(0);
      if (adapterSettled) releaseState();
    };
    try {
      if (!store || auth.codex?.profile) throw new Error("Codex host session store is unavailable");
      operationSettled = false;
      if (request.kind === "load") {
        operation = Promise.resolve().then(() => store.load({ signal: controller.signal }));
      } else {
        operationBytes = Buffer.from(request.bytes);
        operation = Promise.resolve().then(() => store.commit(
          operationBytes,
          request.expectedRevision ?? undefined,
          { signal: controller.signal },
        ));
      }
      operation.then(
        settleOperation,
        settleOperation,
      );
      const aborted = new Promise((_, reject) => {
        controller.signal.addEventListener("abort", () => {
          reject(controller.signal.reason ?? new DOMException("Codex session store operation aborted", "AbortError"));
        }, { once: true });
      });
      timeout = setTimeout(() => {
        const error = new Error("Codex session store operation timed out");
        error.code = "LIBFX_CODEX_SESSION_TIMEOUT";
        controller.abort(error);
      }, codexSessionTimeoutMs());
      const result = await Promise.race([
        operation,
        aborted,
      ]);
      if (request.kind === "load") {
        if (result == null) {
          finishCodexSessionOperation(request, sessionStatusMissing);
        } else {
          responseBytes = result.bytes instanceof Uint8Array ? Buffer.from(result.bytes) : null;
          if (!responseBytes || typeof result.revision !== "string") {
            throw new TypeError("Codex session load() must return { bytes: Uint8Array, revision: string } or null");
          }
          finishCodexSessionOperation(request, sessionStatusSuccess, responseBytes, result.revision);
        }
      } else {
        if (typeof result?.revision !== "string") {
          throw new TypeError("Codex session commit() must return { revision: string }");
        }
        finishCodexSessionOperation(request, sessionStatusSuccess, Buffer.alloc(0), result.revision);
      }
    } catch (error) {
      const timedOut = error?.code === "LIBFX_CODEX_SESSION_TIMEOUT";
      try {
        finishCodexSessionOperation(
          request,
          error?.code === "FX_CODEX_SESSION_REVISION_CONFLICT" ? sessionStatusConflict : sessionStatusFailure,
        );
      } catch {}
      // A host operation that ignores timeout may never settle. Close this
      // runtime after failing the matching native operation so no later Codex
      // request can become stranded behind a permanently quarantined pump.
      if (timedOut) finish(1);
    } finally {
      if (timeout) clearTimeout(timeout);
      request.bytes?.fill(0);
      responseBytes?.fill(0);
      adapterSettled = true;
      // Abort is advisory for a host store. Keep the pump quarantined until an
      // operation that ignored its signal actually settles, so its late side
      // effect cannot overlap a newer load or optimistic commit.
      if (!operation) operationBytes?.fill(0);
      if (!operation || operationSettled) releaseState();
    }
  };
  function drainReady() {
    if (settled) return;
    try {
      if (fetchState) {
        if (!fetchState.controller.signal.aborted && !addon.coreFetchActive(core, fetchState.handle)) {
          fetchState.controller.abort();
        }
      } else {
        const fetchRequest = addon.takeCoreFetch(core);
        if (fetchRequest) {
          let request;
          try {
            request = JSON.parse(fetchRequest.toString("utf8"));
          } finally {
            fetchRequest.fill(0);
          }
          void pumpFetch(request);
        }
      }
      if (!codexSessionState) {
        const sessionRequest = addon.takeCoreCodexSessionOperation(core);
        if (sessionRequest) void pumpCodexSession(sessionRequest);
      }
      if (addon.coreExitCode(core) !== 0) {
        finish(1, new Error("native output delivery failed"));
        return;
      }
      void drainOutput();
    } catch (error) {
      finish(1, error);
    }
  }
  async function drainOutput() {
    if (draining || settled) return;
    draining = true;
    try {
      while (!settled) {
        const chunk = addon.drainCore(core);
        if (!chunk.length) break;
        const pending = output.write(chunk);
        if (pending) await pending;
      }
      if (!settled && addon.coreExited(core)) {
        output.finish();
        finish(addon.coreExitCode(core));
      }
    } catch (error) {
      finish(1, error);
    } finally {
      draining = false;
    }
  }

  readySocket.on("data", drainReady);
  readySocket.on("end", () => { drainReady(); if (!settled) finish(1); });
  readySocket.on("error", () => finish(1));
  readySocket.on("close", () => { if (!settled) finish(1); });
  // Some runtimes defer descriptor adoption until connect().
  if (readySocket.pending) {
    try { readySocket.connect({ fd: readyFd }); } catch (error) { finish(1); throw error; }
  }

  return {
    exited,
    get error() { return outputError; },
    write(data) { addon.writeCore(core, Buffer.from(data)); },
    closeStdin() { addon.closeCore(core); },
    abortHostEffects,
    abort(error) {
      if (error) finish(1, error);
      else { abortHostEffects(); addon.closeCore(core); }
    },
    setLineHandler(handler) { lineHandler = handler; },
  };
}

function createNativeAgent(addon, options) {
  const nativeOptions = {
    ...options,
    runtimeFactory(runtimeOptions) {
      return createNativeCoreRuntime(addon, runtimeOptions);
    },
  };
  if (options[normalizedAuthBrand]?.codex) authorizeNativeHostOptions(nativeOptions);
  return createWasmAgent(nativeOptions);
}

async function createWithFallback(surface, nativeMethod, wasmFactory, defaultWasm, options) {
  const { nativeAddon, backend = "auto", ...runtimeOptions } = options ?? {};
  const effectiveOptions = surface === "agent" ? normalizeAgentAuth(runtimeOptions) : runtimeOptions;
  if (!new Set(["auto", "native", "wasm"]).has(backend)) {
    throw new TypeError('backend must be "auto", "native", or "wasm"');
  }

  let nativeError;
  const requiresNativeCodex = surface === "agent" && Boolean(effectiveOptions[normalizedAuthBrand]?.codex);
  if (backend === "wasm" && requiresNativeCodex) {
    const error = new Error("Codex auth requires the native Node backend");
    error.code = "LIBFX_CODEX_NATIVE_REQUIRED";
    throw error;
  }
  let nativeAttempted = false;
  if (backend !== "wasm") {
    const native = await resolveNativeBackend(nativeAddon);
    nativeError = native.error;
    if (typeof native.backend?.[nativeMethod] === "function") {
      nativeAttempted = true;
      try {
        if (surface === "agent") {
          return await createNativeAgent(native.backend, effectiveOptions);
        }
        return await native.backend[nativeMethod](effectiveOptions);
      } catch (error) {
        nativeError = error;
        if (backend === "native") throw error;
      }
    }
    if (backend === "native") {
      const error = nativeError ?? new Error(`native addon does not provide ${nativeMethod}()`);
      error.code ??= "LIBFX_NATIVE_UNAVAILABLE";
      throw error;
    }
  }

  if (requiresNativeCodex) {
    const error = nativeError ?? new Error("No compatible native addon was found");
    error.code ??= "LIBFX_CODEX_NATIVE_REQUIRED";
    throw error;
  }
  if (!supportsJspi()) {
    if (nativeAttempted) throw nativeError;
    throw jspiFallbackError(surface, nativeError);
  }
  return wasmFactory({
    ...effectiveOptions,
    wasm: await wasmBytes(effectiveOptions.wasm ?? defaultWasm),
  });
}

export async function createFxAgent(options = {}) {
  if (options != null && Object.hasOwn(Object(options), "env")) {
    throw new TypeError("createFxAgent() does not accept env; pass apiKey and model directly");
  }
  return createWithFallback(
    "agent",
    "createCore",
    createWasmAgent,
    defaultCoreWasm,
    options,
  );
}

export function createFxTerminal(options = {}) {
  return createWithFallback("terminal", "createFxTerminal", createWasmTerminal, defaultTermWasm, options);
}
