import {
  createFxEngine as createWasmAgent,
  createFxTerminal as createWasmTerminal,
  createMemoryPersistence,
  FxFencedError,
  FxJournalVersionError,
  encodeXtermKeyEvent,
  fxSdkApiVersion,
  listModels,
  supportsJspi,
  xtermAdapter,
} from "./fx-sdk.js";

export { createMemoryPersistence, encodeXtermKeyEvent, FxFencedError, FxJournalVersionError, fxSdkApiVersion, listModels, supportsJspi, xtermAdapter };
export const libfxApiVersion = 3;

const defaultCoreWasm = new URL("./fx-core.wasm", import.meta.url).href;
const defaultTermWasm = new URL("./fx-term.wasm", import.meta.url).href;

function normalizeBrowserAgentAuth(options) {
  if (options.auth === undefined) return options;
  const entries = Array.isArray(options.auth) ? options.auth : [options.auth];
  if (entries.length !== 1 || !entries[0] || entries[0].provider !== "gateway") {
    const error = new Error("Browser libfx supports only Gateway auth; Codex requires the native Node backend");
    error.code = "LIBFX_CODEX_NATIVE_REQUIRED";
    throw error;
  }
  if (Object.keys(entries[0]).some((key) => key !== "provider" && key !== "apiKey")) {
    throw new TypeError("Gateway auth accepts only provider and apiKey");
  }
  if (typeof entries[0].apiKey !== "string" || !entries[0].apiKey.length) {
    throw new TypeError("Gateway auth requires a non-empty apiKey");
  }
  const configured = options.apiKey;
  if (configured !== undefined && configured !== entries[0].apiKey) {
    throw new TypeError("Gateway auth conflicts with apiKey");
  }
  const { auth: _auth, ...rest } = options;
  return { ...rest, apiKey: entries[0].apiKey };
}

export function createFxEngine(options = {}) {
  const normalized = normalizeBrowserAgentAuth(options);
  return createWasmAgent({ ...normalized, wasm: normalized.wasm ?? defaultCoreWasm });
}

export const createFxAgent = createFxEngine;

export function createFxTerminal(options = {}) {
  return createWasmTerminal({ ...options, wasm: options.wasm ?? defaultTermWasm });
}
