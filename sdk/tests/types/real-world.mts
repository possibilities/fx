// Workflow's real World types fit `world()`. Checked only when the Worlds
// libfx bundles are installed (`npm ci --prefix sdk/durable`).
import type { World as WorkflowWorld } from "@workflow/world";
import { createWorld as createLocalWorld } from "@workflow/world-local";
import { createWorld as createVercelWorld } from "@workflow/world-vercel";
import { world, type World } from "libfx/durable-world";

declare const any: WorkflowWorld;
export const structural: World = any;

export async function run(): Promise<void> {
  const sessions = createLocalWorld({ dataDir: ".fx/sessions" });
  await sessions.start?.();
  world(sessions);
  await sessions.close?.();

  world(() => createVercelWorld(), { name: "vercel", queueDurable: true });
  world(async () => createLocalWorld(), { livenessKnown: true, alive: () => null });
}
