#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = fileURLToPath(new URL("../..", import.meta.url));
const temp = await mkdtemp(join(tmpdir(), "libfx-import-closure-"));
const mirror = join(temp, "source");
const packageDir = join(temp, "package");
const demoDir = join(temp, "demo");
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const run = (script, output) => {
  const result = spawnSync(process.execPath, [join(mirror, "sdk/scripts", script), output], {
    encoding: "utf8",
  });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
};

try {
  await cp(join(root, "sdk"), join(mirror, "sdk"), {
    recursive: true,
    filter: (path) => !path.split("/").some((part) => part === "node_modules" || part === "dist"),
  });
  await cp(join(root, "LICENSE"), join(mirror, "LICENSE"));
  await mkdir(join(mirror, "zig-out/bin"), { recursive: true });
  await mkdir(join(mirror, "zig-out/lib"), { recursive: true });
  // Opaque packaging fixtures: this test imports JavaScript, never loads a
  // native addon or instantiates Wasm. Runtime qualification is separate.
  for (const name of ["fx-core.wasm", "fx-term.wasm"]) {
    await writeFile(join(mirror, "zig-out/bin", name), "import-only fixture");
  }
  await writeFile(join(mirror, "zig-out/lib/libfx.node"), "import-only fixture");
  run("package-libfx.mjs", packageDir);
  const esm = await import(pathToFileURL(join(packageDir, "node.js")).href);
  const cjs = createRequire(import.meta.url)(join(packageDir, "node.cjs"));
  assert.deepEqual(Object.keys(esm).sort(), Object.keys(cjs).sort());
  assert.equal(typeof esm.fxProfileSession, "function");
  for (const entry of ["browser.js", "fx-sdk.js"]) {
    const loaded = await import(pathToFileURL(join(packageDir, entry)).href);
    assert.equal(typeof loaded.createFxAgent, "function");
  }
  assert.equal(await readFile(join(packageDir, "internal.js"), "utf8"), await readFile(join(root, "sdk/internal.js"), "utf8"));

  run("package-term-demo.mjs", demoDir);
  await writeFile(join(demoDir, "package.json"), '{"type":"module"}\n');
  const manifest = JSON.parse(await readFile(join(demoDir, "manifest.json"), "utf8"));
  const internal = await readFile(join(demoDir, manifest.internal.file));
  assert.equal(digest(internal), manifest.internal.sha256);
  assert.equal(internal.length, manifest.internal.bytes);
  const sdk = await readFile(join(demoDir, manifest.sdk.file), "utf8");
  assert.ok(sdk.includes(`from "./${manifest.internal.file}";`));
  assert.ok(!sdk.includes('from "./internal.js";'));
  const headers = JSON.parse(await readFile(join(demoDir, "vercel.json"), "utf8")).headers;
  assert.deepEqual(headers.find(({ source }) => source === `/${manifest.internal.file}`)?.headers,
    [{ key: "Cache-Control", value: "public, max-age=31536000, immutable" }]);
  const browser = await import(pathToFileURL(join(demoDir, manifest.browser.file)).href);
  assert.equal(typeof browser.createFxTerminal, "function");
  console.log("package imports passed: relocated ESM, CommonJS, browser, Wasm entry, and hashed demo");
} finally {
  await rm(temp, { recursive: true, force: true });
}
