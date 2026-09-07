import { access, readFile } from "node:fs/promises";
import { closeSync } from "node:fs";
import { createRequire } from "node:module";
import { Socket } from "node:net";
import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { CoreOutput } from "./core-output.js";
import { loadModule, withModuleFailure } from "./wasm-module.js";
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

const nodeRequire = createRequire(import.meta.url);
const defaultCoreWasm = new URL("./fx-core.wasm", import.meta.url);
const defaultTermWasm = new URL("./fx-term.wasm", import.meta.url);
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
const backendReasonCodes = {
  unsupportedPlatform: "LIBFX_UNSUPPORTED_PLATFORM",
  missingArtifact: "LIBFX_NATIVE_ARTIFACT_MISSING",
  nativeLoad: "LIBFX_NATIVE_LOAD_FAILED",
  nativeApi: "LIBFX_NATIVE_API_MISMATCH",
  missingSurface: "LIBFX_NATIVE_SURFACE_MISSING",
  disabledNative: "LIBFX_NATIVE_DISABLED",
  jspiUnavailable: "LIBFX_JSPI_UNAVAILABLE",
  wasmLoad: "LIBFX_WASM_LOAD_FAILED",
};

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
      // Bundlers trace the asset URL; Node must load the native file at runtime.
      return Reflect.apply(nodeRequire, undefined, [fileURLToPath(candidate)]);
    }
    const imported = await import(candidate.href);
    return imported.default ?? imported;
  }
  if (typeof candidate === "object") return candidate.default ?? candidate;
  if (typeof candidate !== "string") {
    throw new TypeError("nativeAddon must be a module, path, URL, false, or undefined");
  }
  if (candidate.endsWith(".node")) {
    return Reflect.apply(nodeRequire, undefined, [isAbsolute(candidate) ? candidate : resolve(candidate)]);
  }
  const imported = await import(candidate.startsWith("file:") ? candidate : pathToFileURL(candidate).href);
  return imported.default ?? imported;
}

function defaultNativeCandidate() {
  // Local path bindings let deployment tracers retain these assets in the generated CommonJS entry.
  if (process.platform === "linux" && process.arch === "x64") {
    const path = fileURLToPath(new URL("./libfx.linux-x64.node", import.meta.url));
    return path;
  }
  if (process.platform === "linux" && process.arch === "arm64") {
    const path = fileURLToPath(new URL("./libfx.linux-arm64.node", import.meta.url));
    return path;
  }
  if (process.platform === "darwin" && process.arch === "x64") {
    const path = fileURLToPath(new URL("./libfx.darwin-x64.node", import.meta.url));
    return path;
  }
  if (process.platform === "darwin" && process.arch === "arm64") {
    const path = fileURLToPath(new URL("./libfx.darwin-arm64.node", import.meta.url));
    return path;
  }
  return null;
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

function missingArtifact(error) {
  return error?.code === "ENOENT" || error?.code === "MODULE_NOT_FOUND" || error?.code === "ERR_MODULE_NOT_FOUND";
}

function nativeCandidateFilePath(candidate) {
  if (candidate instanceof URL) return candidate.protocol === "file:" ? fileURLToPath(candidate) : null;
  if (typeof candidate !== "string") return null;
  if (candidate.startsWith("file:")) return fileURLToPath(new URL(candidate));
  return URL.canParse(candidate) ? null : resolve(candidate);
}

async function nativeArtifactMissing(candidate) {
  try {
    const path = nativeCandidateFilePath(candidate);
    if (path === null) return false;
    await access(path);
    return false;
  } catch (error) {
    return missingArtifact(error);
  }
}

function validationFailure(error) {
  return error?.message?.startsWith("native addon API version ") ? "api" : "surface";
}

async function loadAndValidateNativeCandidate(candidate, artifactMissing = false) {
  let backend;
  try {
    backend = await loadNativeCandidate(candidate);
  } catch (error) {
    return { backend: null, error, failure: artifactMissing ? "missing" : "load" };
  }
  try {
    return { backend: validateNativeBackend(backend), error: null, failure: null };
  } catch (error) {
    return { backend: null, error, failure: validationFailure(error) };
  }
}

async function discoverNativeBackend() {
  const candidate = defaultNativeCandidate();
  if (!candidate) {
    return { backend: null, error: null, failure: "unsupported" };
  }
  try {
    await access(candidate);
  } catch (error) {
    if (missingArtifact(error)) {
      return { backend: null, error: null, probeError: error, failure: "missing" };
    }
    return { backend: null, error, failure: "load" };
  }
  return loadAndValidateNativeCandidate(candidate);
}

async function resolveNativeBackend(nativeAddon) {
  if (nativeAddon === false) return { backend: null, error: null, failure: "disabled" };
  if (nativeAddon !== undefined) {
    return loadAndValidateNativeCandidate(nativeAddon, await nativeArtifactMissing(nativeAddon));
  }
  nativeBackendPromise ??= discoverNativeBackend();
  return nativeBackendPromise;
}

function wasmInput(input) {
  const path = wasmFilePath(input);
  if (path === null) {
    if (input instanceof URL) return input.href;
    return input;
  }
  const cached = wasmFilePromises.get(path);
  if (cached) return cached;
  const pendingRead = readFile(path);
  let pending;
  pending = withModuleFailure(pendingRead, () => {
    if (wasmFilePromises.get(path) === pending) wasmFilePromises.delete(path);
  });
  wasmFilePromises.set(path, pending);
  pendingRead.catch(() => {
    if (wasmFilePromises.get(path) === pending) wasmFilePromises.delete(path);
  });
  return pending;
}

function wasmFilePath(input) {
  if (input instanceof URL && input.protocol === "file:") return fileURLToPath(input);
  if (typeof input === "string" && !URL.canParse(input)) return resolve(input);
  return null;
}

function reason(code, message, error) {
  const causeCode = error?.code;
  return {
    code,
    message,
    ...(typeof causeCode === "string" || typeof causeCode === "number" ? { causeCode } : {}),
  };
}

function nativeFailureReason(result) {
  const detailError = result.probeError ?? result.error;
  switch (result.failure) {
    case "unsupported":
      return reason(
        backendReasonCodes.unsupportedPlatform,
        `native addon is not available for ${process.platform}-${process.arch}`,
      );
    case "missing":
      return reason(
        backendReasonCodes.missingArtifact,
        `native addon artifact was not found${detailError?.message ? `: ${detailError.message}` : ""}`,
        detailError,
      );
    case "load":
      return reason(
        backendReasonCodes.nativeLoad,
        `native addon failed to load${result.error?.message ? `: ${result.error.message}` : ""}`,
        result.error,
      );
    case "api":
      return reason(backendReasonCodes.nativeApi, result.error.message, result.error);
    case "surface":
      return reason(backendReasonCodes.missingSurface, result.error.message, result.error);
    case "disabled":
      return reason(backendReasonCodes.disabledNative, "native addon loading is disabled");
    default:
      return reason(backendReasonCodes.nativeLoad, "native addon is unavailable", result.error);
  }
}

function validateBackendInfoOptions(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("getBackendInfo() options must be an object");
  }
  const { nativeAddon, backend = "auto", surface = "agent", ...options } = value;
  for (const key of Object.keys(options)) {
    if (key !== "wasm") {
      throw new TypeError(`getBackendInfo() does not accept ${key}`);
    }
  }
  if (!new Set(["agent", "terminal"]).has(surface)) {
    throw new TypeError('surface must be "agent" or "terminal"');
  }
  if (!new Set(["auto", "native", "wasm"]).has(backend)) {
    throw new TypeError('backend must be "auto", "native", or "wasm"');
  }
  if (nativeAddon !== undefined && nativeAddon !== false &&
    typeof nativeAddon !== "string" && !(nativeAddon instanceof URL) &&
    (typeof nativeAddon !== "object" || nativeAddon === null)) {
    throw new TypeError("nativeAddon must be a module, path, URL, false, or undefined");
  }
  const validWasm = options.wasm === undefined || typeof options.wasm === "string" || options.wasm instanceof URL ||
    options.wasm instanceof Promise || options.wasm instanceof WebAssembly.Module || options.wasm instanceof Response ||
    options.wasm instanceof ArrayBuffer || ArrayBuffer.isView(options.wasm);
  if (Object.hasOwn(options, "wasm") && !validWasm) {
    throw new TypeError("wasm must be a URL, Response, ArrayBuffer, typed array, or WebAssembly.Module");
  }
  return { ...options, surface, backend, nativeAddon };
}

export async function getBackendInfo(value = {}) {
  const { surface, backend, nativeAddon, wasm } = validateBackendInfoOptions(value);
  const attempts = [];
  if (backend !== "wasm") {
    const native = await resolveNativeBackend(nativeAddon);
    const nativeMethod = surface === "agent" ? "createCore" : "createFxTerminal";
    if (typeof native.backend?.[nativeMethod] === "function") {
      attempts.push({ backend: "native", available: true, reason: null });
      return { surface, backend: "native", attempts };
    }
    const failureReason = native.backend
      ? reason(backendReasonCodes.missingSurface, `native addon does not provide ${nativeMethod}()`)
      : nativeFailureReason(native);
    attempts.push({ backend: "native", available: false, reason: failureReason });
    if (backend === "native") return { surface, backend: "unavailable", attempts };
  }

  if (!supportsJspi()) {
    attempts.push({
      backend: "wasm-jspi",
      available: false,
      reason: reason(
        backendReasonCodes.jspiUnavailable,
        "WebAssembly backend requires JavaScript Promise Integration (JSPI)",
      ),
    });
    return { surface, backend: "unavailable", attempts };
  }
  const defaultWasm = surface === "agent" ? defaultCoreWasm : defaultTermWasm;
  const wasmSource = wasm ?? defaultWasm;
  try {
    await loadModule(await wasmInput(wasmSource));
    attempts.push({ backend: "wasm-jspi", available: true, reason: null });
    return { surface, backend: "wasm-jspi", attempts };
  } catch (error) {
    attempts.push({
      backend: "wasm-jspi",
      available: false,
      reason: reason(
        backendReasonCodes.wasmLoad,
        `WebAssembly asset failed to load or compile: ${error?.message ?? String(error)}`,
        error,
      ),
    });
    return { surface, backend: "unavailable", attempts };
  }
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
      if (codexSessionState !== state) return;
      codexSessionState = null;
      // Mirror the fetch pump: a request queued while this operation was in
      // flight is picked up on the next tick without waiting for a wake byte.
      queueMicrotask(drainReady);
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
  const wasmSource = effectiveOptions.wasm ?? defaultWasm;
  return wasmFactory({ ...effectiveOptions, wasm: await wasmInput(wasmSource) });
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
