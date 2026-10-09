import {
  createFxAgent,
  createMemoryPersistence,
  fxProfileSession,
  type FxAgent,
  type FxCodexSessionStore,
  type FxEngineTurnResult,
} from "libfx";

const store: FxCodexSessionStore = {
  async load({ signal }) {
    if (signal.aborted) return null;
    return { bytes: new Uint8Array(), revision: "revision-1" };
  },
  async commit(bytes, expectedRevision, { signal }) {
    if (signal.aborted) throw signal.reason;
    void bytes;
    void expectedRevision;
    return { revision: "revision-2" };
  },
};

export async function providerAuthorization(): Promise<void> {
  const agent: FxAgent = await createFxAgent({
    backend: "native",
    auth: [
      { provider: "codex", session: store },
      { provider: "gateway", apiKey: "gateway-key" },
    ],
    model: { id: "gpt-5.6-sol", effort: "high" },
    persistence: createMemoryPersistence(),
  });
  const result: FxEngineTurnResult = await agent.prompt("Hello").result;
  console.log(result.stopReason, result.usage);
  for (const option of agent.configOptions) console.log(option.id, option.currentValue);
  await agent.setConfig({ provider: "gateway" });
  const checkpoint: Uint8Array = await agent.checkpoint();
  await agent.close();
  const restored = await createFxAgent({
    auth: { provider: "codex", session: fxProfileSession({ home: "/explicit-home" }) },
    checkpoint,
  });
  await restored.close();
  await createFxAgent({ apiKey: "gateway-key" });
  await createFxAgent({ auth: { provider: "gateway", apiKey: "gateway-key" } });

  // @ts-expect-error no public sub-session API
  agent.session();
  // @ts-expect-error no ambient credential fallback
  createFxAgent({});
  // @ts-expect-error Codex requires an explicit store or profile opt-in
  createFxAgent({ auth: { provider: "codex" } });
  // @ts-expect-error Gateway cannot receive a Codex store
  createFxAgent({ auth: { provider: "gateway", apiKey: "key", session: store } });
  // @ts-expect-error Grok is unavailable on libfx
  createFxAgent({ auth: { provider: "grok", session: store } });
  // @ts-expect-error a store commit returns an optimistic revision
  const invalidStore: FxCodexSessionStore = { load: store.load, commit: async () => {} };
  void invalidStore;
  // @ts-expect-error model options cannot be mixed with top-level effort
  createFxAgent({ apiKey: "key", model: { id: "model" }, effort: "high" });
  // @ts-expect-error durability does not restore public sub-sessions
  createFxAgent({ apiKey: "key", durability: {} });
}
