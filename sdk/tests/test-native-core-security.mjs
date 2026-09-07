#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createRequire } from "node:module";
import { mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addonPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const addon = require(addonPath);

function fdCount() {
  try { return readdirSync("/dev/fd").length; } catch { return null; }
}

const beforeFds = fdCount();
for (let index = 0; index < 1000; index += 1) {
  assert.throws(() => addon.createCore({
    apiKey: "k".repeat(4096),
    model: 42,
    home: process.cwd(),
    workspaceRoot: process.cwd(),
  }));
}
const afterFds = fdCount();
if (beforeFds !== null && afterFds !== null) assert.ok(afterFds - beforeFds < 4, `fd leak: ${beforeFds} -> ${afterFds}`);

const runtimeLimitProbe = Array.from({ length: 64 }, () => addon.createCore({
  apiKey: "runtime-limit-key",
  home: process.cwd(),
  workspaceRoot: process.cwd(),
}));
assert.throws(
  () => addon.createCore({ apiKey: "runtime-limit-key", home: process.cwd(), workspaceRoot: process.cwd() }),
  (error) => error.code === "LIBFX_NATIVE_LIMIT",
);
for (const handle of runtimeLimitProbe) addon.closeCore(handle);
for (const handle of runtimeLimitProbe) addon.destroyCore(handle);

const testRoot = mkdtempSync(join(tmpdir(), "libfx-native-security-"));
const core = addon.createCore({ apiKey: "security-test-key", home: testRoot, workspaceRoot: testRoot });
let nextId = 1;
function send(method, params) {
  const id = nextId++;
  addon.writeCore(core, Buffer.from(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`));
  const deadline = Date.now() + 5000;
  let buffered = "";
  while (Date.now() < deadline) {
    buffered += addon.drainCore(core).toString("utf8");
    const lines = buffered.split("\n");
    buffered = lines.pop();
    for (const line of lines) {
      if (!line) continue;
      const message = JSON.parse(line);
      if (message.id === id) return message;
    }
  }
  throw new Error(`timed out waiting for ${method}`);
}

try {
  assert.ok(send("initialize", { protocolVersion: 1, clientCapabilities: {} }).result);
  const created = send("session/new", { cwd: testRoot, mcpServers: [] });
  assert.ok(created.result?.sessionId);
  const response = send("session/new", {
    cwd: testRoot,
    mcpServers: [{ name: "blocked", command: "/bin/sh", args: ["-c", "exit 0"], env: [] }],
  });
  assert.equal(response.error?.code, -32602);
  assert.match(response.error?.message ?? "", /MCP servers are unavailable/);

  for (const method of ["session/load", "session/resume"]) {
    const restored = send(method, {
      sessionId: created.result.sessionId,
      cwd: testRoot,
      mcpServers: [{ name: `blocked-${method}`, command: "/usr/bin/true", args: [], env: [] }],
    });
    assert.equal(restored.error?.code, -32602);
    assert.match(restored.error?.message ?? "", /MCP servers are unavailable/);
  }
} finally {
  addon.closeCore(core);
  addon.destroyCore(core);
  rmSync(testRoot, { recursive: true, force: true });
}
console.log("native core security passed: malformed creation is stable and ACP MCP is blocked on new and restore");
