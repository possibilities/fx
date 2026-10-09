// `libfx` and `libfx/node` on Node.js, for `require` (node.cjs). The ESM entry,
// node.d.ts, re-exports this file: node.cjs is built from node.js.
import type {
  FxAgent,
  FxAgentOptions,
  FxBackendInfo,
  FxBackendInfoOptions,
  FxEngine,
  FxEngineOptions,
  FxGatewayAuthorization,
  FxNodeBackendOptions,
  FxTerminal,
  FxTerminalOptions,
} from "./libfx.cjs";

export {
  createMemoryPersistence,
  encodeXtermKeyEvent,
  FxFencedError,
  FxJournalVersionError,
  fxSdkApiVersion,
  listModels,
  supportsJspi,
  xtermAdapter,
} from "./libfx.cjs";

export type {
  Durability,
  FxAccepted,
  FxAgent,
  FxAgentEvent,
  FxAgentOptions,
  FxBackendAttempt,
  FxBackendChoice,
  FxBackendInfo,
  FxBackendInfoOptions,
  FxBackendReason,
  FxBackendReasonCode,
  FxBytes,
  FxCheckpointMeta,
  FxEffort,
  FxEngine,
  FxEngineEvent,
  FxEngineOptions,
  FxEnginePromptOptions,
  FxEngineStorage,
  FxEngineTurn,
  FxEngineTurnResult,
  FxErrorSummary,
  FxFetch,
  FxFollowUp,
  FxHostTool,
  FxIdleResult,
  FxImageBlock,
  FxJsonSchema,
  FxKeyedTool,
  FxKeyEventLike,
  FxListModelsOptions,
  FxModelCatalogEntry,
  FxModelChoice,
  FxModelOptions,
  FxNodeBackendOptions,
  FxNodeWasmSource,
  FxOnAmbiguous,
  FxPromptBlock,
  FxPromptInput,
  FxPromptOptions,
  FxProviderTool,
  FxResizedImage,
  FxResourceBlock,
  FxResumeOptions,
  FxResumeTurn,
  FxSession,
  FxSessionEvent,
  FxSessionImageBlock,
  FxSessionOptions,
  FxSessionPromptInput,
  FxSessionTurnEvent,
  FxSharedOptions,
  FxSteer,
  FxSteeringInput,
  FxStopReason,
  FxStreamLine,
  FxTerminal,
  FxTerminalAdapter,
  FxTerminalEvent,
  FxTerminalOptions,
  FxTextBlock,
  FxTool,
  FxToolContext,
  FxToolImage,
  FxToolResult,
  FxTools,
  FxTurn,
  FxTurnEvent,
  FxTurnResult,
  FxTurnView,
  FxUsage,
  FxWasmModule,
  FxWorkspace,
  FxWorkspaceExecResult,
  FxXtermLike,
  JournalRecord,
  JsonObject,
  JsonValue,
  MemoryOptions,
  MemoryPersistence,
  Persistence,
  PersistenceLoadResult,
} from "./libfx.cjs";

/** Options for `createFxAgent()` on Node.js. */
export type FxNodeAgentOptions = FxNodeEngineOptions;

/** Options for `createFxEngine()` on Node.js. */
declare const profileSessionBrand: unique symbol;

export interface FxProfileSession {
  readonly [profileSessionBrand]: true;
  readonly home: string;
}

export interface FxCodexSessionStore {
  load(options: { signal: AbortSignal }): Promise<{ bytes: Uint8Array; revision: string } | null>;
  commit(bytes: Uint8Array, expectedRevision: string | undefined, options: { signal: AbortSignal }): Promise<{ revision: string }>;
}

export interface FxCodexAuthorization {
  provider: "codex";
  session: FxProfileSession | FxCodexSessionStore;
}

export type FxProviderAuthorization = FxGatewayAuthorization | FxCodexAuthorization;

type FxNativeCredentials =
  | { apiKey: string; auth?: FxProviderAuthorization | readonly FxProviderAuthorization[] }
  | { apiKey?: string; auth: FxProviderAuthorization | readonly FxProviderAuthorization[] };

type WithNativeCredentials<Options> = Options extends unknown
  ? Omit<Options, "apiKey" | "auth"> & FxNativeCredentials
  : never;

export type FxNodeEngineOptions = WithNativeCredentials<FxEngineOptions> & FxNodeBackendOptions;

export declare function fxProfileSession(options?: { home?: string }): FxProfileSession;

/** Options for `createFxTerminal()` on Node.js. */
export type FxNodeTerminalOptions = FxTerminalOptions & FxNodeBackendOptions;

export declare function createFxAgent(options: FxNodeAgentOptions): Promise<FxAgent>;

/**
 * The kernel under `createFxAgent()`: one conversation, held in the memory of
 * the process that runs it. `apiKey` is required, and it resolves once its
 * backend has loaded.
 */
export declare function createFxEngine(options: FxNodeEngineOptions): Promise<FxEngine>;

/** The interactive terminal harness. */
export declare function createFxTerminal(options: FxNodeTerminalOptions): Promise<FxTerminal>;

/** Inspects backend availability without creating an agent or terminal. */
export declare function getBackendInfo(options?: FxBackendInfoOptions): Promise<FxBackendInfo>;

/** The version of the libfx agent API. */
export declare const libfxApiVersion: 3;
