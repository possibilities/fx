import libfx = require("libfx");
import nodeEntry = require("libfx/node");

export async function run(): Promise<void> {
  const agent: libfx.FxAgent = await libfx.createFxAgent({
    auth: { provider: "gateway", apiKey: "key" },
  });
  const result: libfx.FxEngineTurnResult = await agent.prompt("Explain this project.").result;
  console.log(result.stopReason);
  await agent.setConfig({ model: "another-model" });
  const profile: nodeEntry.FxProfileSession = libfx.fxProfileSession({ home: "/home/host" });
  void profile;
  const engine = await nodeEntry.createFxEngine({ apiKey: "key", persistence: libfx.createMemoryPersistence() });
  for (let open = engine.resume(); open; open = engine.resume()) await open.result;
  const info = await libfx.getBackendInfo({ backend: "native" });
  console.log(info.backend, libfx.libfxApiVersion, await libfx.listModels({ apiKey: "key" }));
  await engine.close();
  await agent.close();
  // @ts-expect-error no public sub-session API
  agent.session(null);
}
