#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, fxProfileSession } from "../node.js";

const accountId = "acct_libfx_codex";
const otherAccountId = "acct_libfx_codex_other";
const initialRefreshToken = "LIBFX_INITIAL_REFRESH_SECRET";
const rotatedRefreshToken = "LIBFX_ROTATED_REFRESH_SECRET";
const gatewayApiKey = "LIBFX_GATEWAY_SECRET";
const chatgptToken = (marker, tokenAccountId = accountId) => {
  const payload = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: tokenAccountId },
    marker,
  })).toString("base64url");
  return `header.${payload}.signature`;
};
const initialAccessToken = chatgptToken("initial-secret");
const refreshedAccessToken = chatgptToken("refreshed-secret");

const requests = [];
let tokenCalls = 0;
let codexCalls = 0;
let gatewayCalls = 0;
let failModels = false;
let rejectNextCodex = false;
let stallGatewayModels = false;
let oversizedGatewayModels = false;
let gatewayModelCalls = 0;
const readBody = (request) => new Promise((resolveBody, rejectBody) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => resolveBody(body));
  request.on("error", rejectBody);
});
const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, "http://127.0.0.1");
    const body = request.method === "POST" ? await readBody(request) : "";
    requests.push({
      method: request.method,
      path: url.pathname,
      authorization: request.headers.authorization ?? null,
      accountId: request.headers["chatgpt-account-id"] ?? null,
      body,
    });
    if (url.pathname === "/chatgpt/token") {
      tokenCalls += 1;
      assert.ok(
        body.includes(initialRefreshToken) || body.includes(rotatedRefreshToken),
        "OAuth refresh used an unexpected token",
      );
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({
        access_token: refreshedAccessToken,
        refresh_token: rotatedRefreshToken,
        expires_in: 3600,
      }));
      return;
    }
    if (url.pathname === "/chatgpt/models") {
      if (failModels) {
        response.writeHead(503, { "content-type": "application/json" });
        response.end('{"error":"catalog unavailable"}');
        return;
      }
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ models: [
        {
          slug: "gpt-5.6-sol",
          visibility: "list",
          supported_in_api: true,
          supported_reasoning_levels: [{ effort: "high" }],
          additional_speed_tiers: ["fast"],
          input_modalities: ["text"],
          context_window: 272000,
        },
        {
          slug: "gpt-5.4-mini",
          visibility: "list",
          supported_in_api: true,
          supported_reasoning_levels: [{ effort: "low" }],
          additional_speed_tiers: [],
          input_modalities: ["text"],
          context_window: 128000,
        },
        {
          slug: "gpt-5.6-luna",
          visibility: "list",
          supported_in_api: true,
          supported_reasoning_levels: [{ effort: "medium" }],
          additional_speed_tiers: [],
          input_modalities: ["text"],
          context_window: 272000,
        },
      ] }));
      return;
    }
    if (url.pathname === "/gateway/models") {
      gatewayModelCalls += 1;
      if (stallGatewayModels) return;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({
        data: oversizedGatewayModels
          ? Array.from({ length: 10_001 }, (_, index) => ({ id: `native/model-${index}` }))
          : [{
              id: "native/gateway-model",
              type: "language",
              tags: ["tool-use"],
            }],
      }));
      return;
    }
    if (url.pathname === "/chatgpt/responses") {
      if (rejectNextCodex) {
        rejectNextCodex = false;
        response.writeHead(401, { "content-type": "application/json" });
        response.end('{"error":"refresh required"}');
        return;
      }
      codexCalls += 1;
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: `codex ${codexCalls}` })}\n\n` +
        'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
      );
      return;
    }
    if (url.pathname === "/gateway/chat") {
      gatewayCalls += 1;
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(
        `data: ${JSON.stringify({ type: "text-delta", delta: `gateway ${gatewayCalls}` })}\n\n` +
        'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}\n\n' +
        "data: [DONE]\n\n",
      );
      return;
    }
    response.writeHead(404).end();
  } catch (error) {
    response.writeHead(500, { "content-type": "text/plain" });
    response.end(String(error?.stack ?? error));
  }
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();
const baseUrl = `http://127.0.0.1:${port}`;

const envOverrides = {
  FX_E2E_CODEX_SESSION_TIMEOUT_MS: "40",
  FX_E2E_CHATGPT_ISSUER_URL: baseUrl,
  FX_E2E_CHATGPT_TOKEN_URL: `${baseUrl}/chatgpt/token`,
  FX_E2E_OPENAI_CODEX_MODELS_URL: `${baseUrl}/chatgpt/models`,
  FX_E2E_OPENAI_CODEX_RESPONSES_URL: `${baseUrl}/chatgpt/responses`,
  FX_E2E_GATEWAY_MODELS_URL: `${baseUrl}/gateway/models`,
  FX_E2E_GATEWAY_CATALOG_TIMEOUT_MS: "40",
};
const originalEnv = Object.fromEntries(
  Object.keys(envOverrides).map((key) => [key, process.env[key]]),
);
Object.assign(process.env, envOverrides);

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const root = mkdtempSync(join(tmpdir(), "libfx-native-codex-"));
const workspace = join(root, "workspace");
const ambientHome = join(root, "ambient-home");
mkdirSync(workspace);
mkdirSync(ambientHome);
const originalHome = process.env.HOME;
process.env.HOME = ambientHome;

const sessionBytes = (
  accessToken,
  refreshToken,
  expiresAtMs = Date.now() + 3_600_000,
  sessionAccountId = accountId,
) => Buffer.from(
  `${JSON.stringify({
    version: 1,
    access_token: accessToken,
    refresh_token: refreshToken,
    expires_at_ms: expiresAtMs,
    account_id: sessionAccountId,
  })}\n`,
);
const waitFor = async (predicate, timeoutMs = 1_000) => {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("timed out waiting for native libfx state");
    await new Promise((resolveWait) => setTimeout(resolveWait, 5));
  }
};
const settleWithin = (promise, timeoutMs) => Promise.race([
  promise,
  new Promise((_, reject) => setTimeout(() => reject(new Error("native libfx operation did not settle")), timeoutMs)),
]);
const collectTurn = async (session, prompt) => {
  const turn = session.prompt(prompt);
  let text = "";
  for await (const update of turn) {
    if (update.type === "text_delta") text += update.delta;
  }
  assert.equal((await turn.result).stopReason, "end_turn");
  return text.trimEnd();
};

let currentBytes = sessionBytes(initialAccessToken, initialRefreshToken, 0);
let currentRevision = "revision-1";
let loadCalls = 0;
let commitCalls = 0;
const store = {
  async load({ signal } = {}) {
    loadCalls += 1;
    assert.ok(signal instanceof AbortSignal);
    assert.equal(signal.aborted, false);
    return { bytes: Buffer.from(currentBytes), revision: currentRevision };
  },
  async commit(bytes, expectedRevision, { signal } = {}) {
    commitCalls += 1;
    assert.ok(signal instanceof AbortSignal);
    assert.equal(signal.aborted, false);
    assert.equal(expectedRevision, currentRevision);
    currentBytes = Buffer.from(bytes);
    currentRevision = `revision-${commitCalls + 1}`;
    return { revision: currentRevision };
  },
};

const events = [];
let agent;
try {
  agent = await createFxAgent({
    nativeAddon: addon,
    backend: "native",
    auth: [
      { provider: "codex", session: store },
      { provider: "gateway", apiKey: gatewayApiKey },
    ],
    home: root,
    workspaceRoot: workspace,
    gatewayChatUrl: `${baseUrl}/gateway/chat`,
    onEvent(event) { events.push(event); },
  });
  const providerConfig = agent.configOptions.find((option) => option.id === "provider");
  assert.deepEqual(providerConfig.options.map((option) => option.value), ["gateway", "codex"]);
  assert.equal(await collectTurn(agent, "use Codex"), "codex 1");
  await agent.setConfig({ provider: "gateway" });
  assert.equal(await collectTurn(agent, "use Gateway"), "gateway 1");
  const accountABytes = Buffer.from(currentBytes);
  currentBytes = sessionBytes(
    chatgptToken("other-account", otherAccountId),
    "LIBFX_OTHER_ACCOUNT_REFRESH_SECRET",
    0,
    otherAccountId,
  );
  currentRevision = "external-account-b";
  const tokenCallsBeforeAccountSwap = tokenCalls;
  const commitCallsBeforeAccountSwap = commitCalls;
  await assert.rejects(
    agent.setConfig({ provider: "codex" }),
    /Codex account changed/,
  );
  assert.equal(tokenCalls, tokenCallsBeforeAccountSwap, "an account swap must fail before OAuth refresh");
  assert.equal(commitCalls, commitCallsBeforeAccountSwap, "an account swap must fail before store write-back");
  currentBytes = accountABytes;
  currentRevision = "external-account-a";
  await agent.setConfig({ provider: "codex" });
  assert.equal(await collectTurn(agent, "use Codex again"), "codex 2");
  await assert.rejects(
    agent.setConfig({ provider: "grok" }),
    /Provider was not supplied by this host/,
  );
  assert.equal(await agent.close(), undefined);
  agent = null;

  assert.ok(loadCalls >= 2, "Codex initialization and switching must read the supplied store");
  assert.equal(commitCalls, 1, "the expired session must refresh and write back exactly once");
  const persisted = JSON.parse(currentBytes.toString("utf8"));
  assert.equal(persisted.access_token, refreshedAccessToken);
  assert.equal(persisted.refresh_token, rotatedRefreshToken);
  assert.equal(persisted.account_id, accountId);
  assert.ok(persisted.expires_at_ms > Date.now());
  assert.equal(tokenCalls, 1);
  assert.equal(existsSync(join(root, ".fx", "chatgpt-auth.json")), false);
  assert.equal(
    existsSync(join(ambientHome, ".fx", "usage.jsonl")),
    false,
    "an explicit libfx home must isolate profile usage from ambient HOME",
  );
  assert.equal(
    existsSync(join(root, ".fx", "usage.jsonl")),
    true,
    "the Gateway turn must publish usage under the explicit libfx home",
  );
  const codexRequests = requests.filter((request) =>
    request.path === "/chatgpt/models" || request.path === "/chatgpt/responses");
  assert.ok(codexRequests.length >= 4);
  for (const request of codexRequests) {
    assert.equal(request.authorization, `Bearer ${refreshedAccessToken}`);
    assert.equal(request.accountId, accountId);
  }
  const gatewayRequests = requests.filter((request) =>
    request.path === "/gateway/models" || request.path === "/gateway/chat");
  assert.ok(gatewayRequests.length >= 2);
  for (const request of gatewayRequests) {
    assert.equal(request.authorization, `Bearer ${gatewayApiKey}`);
    assert.notEqual(request.authorization, `Bearer ${initialAccessToken}`);
    assert.notEqual(request.authorization, `Bearer ${refreshedAccessToken}`);
  }
  const eventText = JSON.stringify(events);
  for (const secret of [initialRefreshToken, rotatedRefreshToken, gatewayApiKey]) {
    assert.equal(eventText.includes(secret), false, `event stream exposed ${secret}`);
  }

  const switchAgentOptions = {
    nativeAddon: addon,
    backend: "native",
    auth: [
      { provider: "codex", session: store },
      { provider: "gateway", apiKey: gatewayApiKey },
    ],
    home: root,
    workspaceRoot: workspace,
    gatewayChatUrl: `${baseUrl}/gateway/chat`,
  };

  let deadlineAgent = await createFxAgent(switchAgentOptions);
  stallGatewayModels = true;
  let startedAt = Date.now();
  await assert.rejects(
    deadlineAgent.setConfig({ provider: "gateway" }),
    /Failed to load provider model catalog/,
  );
  assert.ok(Date.now() - startedAt < 500, "a stalled Gateway catalog must honor its bounded deadline");
  await deadlineAgent.close();
  deadlineAgent = null;

  stallGatewayModels = false;
  oversizedGatewayModels = true;
  let oversizedAgent = await createFxAgent(switchAgentOptions);
  await assert.rejects(
    oversizedAgent.setConfig({ provider: "gateway" }),
    /Failed to load provider model catalog/,
  );
  await oversizedAgent.close();
  oversizedAgent = null;

  oversizedGatewayModels = false;
  process.env.FX_E2E_GATEWAY_CATALOG_TIMEOUT_MS = "5000";
  let closingAgent = await createFxAgent(switchAgentOptions);
  stallGatewayModels = true;
  const gatewayModelBaseline = gatewayModelCalls;
  const stalledSwitch = closingAgent.setConfig({ provider: "gateway" });
  void stalledSwitch.catch(() => {});
  await waitFor(() => gatewayModelCalls > gatewayModelBaseline);
  startedAt = Date.now();
  const [switchOutcome, closeOutcome] = await settleWithin(
    Promise.allSettled([stalledSwitch, closingAgent.close()]),
    500,
  );
  assert.equal(switchOutcome.status, "rejected");
  assert.equal(closeOutcome.status, "fulfilled");
  assert.ok(Date.now() - startedAt < 500, "close must abort a stalled Gateway catalog fetch");
  closingAgent = null;
  stallGatewayModels = false;
  process.env.FX_E2E_GATEWAY_CATALOG_TIMEOUT_MS = "40";

  const profileHome = join(root, "profile-home");
  mkdirSync(join(profileHome, ".fx"), { recursive: true, mode: 0o700 });
  writeFileSync(
    join(profileHome, ".fx", "chatgpt-auth.json"),
    sessionBytes(refreshedAccessToken, rotatedRefreshToken),
    { mode: 0o600 },
  );
  const profileAgent = await createFxAgent({
    nativeAddon: addon,
    backend: "native",
    auth: { provider: "codex", session: fxProfileSession({ home: profileHome }) },
    home: profileHome,
    workspaceRoot: workspace,
  });
  assert.equal(await collectTurn(profileAgent, "use the explicit profile"), "codex 3");
  assert.equal(await profileAgent.close(), undefined);
  assert.equal(tokenCalls, 1, "an unexpired profile session must not refresh");

  const malformedSecret = "LIBFX_MALFORMED_STORE_SECRET";
  let malformedLoads = 0;
  let malformedError;
  await assert.rejects(
    createFxAgent({
      nativeAddon: addon,
      backend: "native",
      auth: {
        provider: "codex",
        session: {
          async load() {
            malformedLoads += 1;
            throw new Error(malformedSecret);
          },
          async commit() { return { revision: "unreachable" }; },
        },
      },
      home: profileHome,
      workspaceRoot: workspace,
    }),
    (error) => {
      malformedError = error;
      return true;
    },
  );
  assert.equal(malformedLoads, 1, "custom Codex auth must not fall back to the ambient profile");
  assert.equal(String(malformedError).includes(malformedSecret), false);

  const conflictBytes = sessionBytes(initialAccessToken, initialRefreshToken, 0);
  let conflictCommits = 0;
  const conflictTokenBaseline = tokenCalls;
  await assert.rejects(
    createFxAgent({
      nativeAddon: addon,
      backend: "native",
      auth: {
        provider: "codex",
        session: {
          async load() {
            return { bytes: Buffer.from(conflictBytes), revision: "conflict-revision" };
          },
          async commit() {
            conflictCommits += 1;
            const error = new Error("optimistic revision changed");
            error.code = "FX_CODEX_SESSION_REVISION_CONFLICT";
            throw error;
          },
        },
      },
      home: root,
      workspaceRoot: workspace,
    }),
  );
  assert.equal(tokenCalls, conflictTokenBaseline + 1, "a conflict follows exactly one OAuth refresh");
  assert.equal(conflictCommits, 1, "a revision conflict must not retry the commit");

  let lateCommitSettled = false;
  let lateCommitSignal;
  let lateCommittedBytes;
  let activeStoreOperations = 0;
  let maxActiveStoreOperations = 0;
  let resolveLateCommit;
  const lateCommitDone = new Promise((resolveLate) => { resolveLateCommit = resolveLate; });
  const timeoutStore = {
    async load() {
      activeStoreOperations += 1;
      maxActiveStoreOperations = Math.max(maxActiveStoreOperations, activeStoreOperations);
      try {
        return {
          bytes: sessionBytes(refreshedAccessToken, rotatedRefreshToken),
          revision: "late-revision-1",
        };
      } finally {
        activeStoreOperations -= 1;
      }
    },
    async commit(bytes, expectedRevision, { signal }) {
      activeStoreOperations += 1;
      maxActiveStoreOperations = Math.max(maxActiveStoreOperations, activeStoreOperations);
      lateCommitSignal = signal;
      assert.equal(expectedRevision, "late-revision-1");
      setTimeout(() => {
        lateCommittedBytes = Buffer.from(bytes);
        lateCommitSettled = true;
        activeStoreOperations -= 1;
        resolveLateCommit();
      }, 400);
      await lateCommitDone;
      return { revision: "late-revision-2" };
    },
  };
  const timeoutAgent = await createFxAgent({
    nativeAddon: addon,
    backend: "native",
    auth: { provider: "codex", session: timeoutStore },
    home: root,
    workspaceRoot: workspace,
  });
  rejectNextCodex = true;
  const timeoutStartedAt = Date.now();
  const timeoutTurn = timeoutAgent.prompt("force a live credential refresh");
  const timeoutTurnDone = (async () => {
    for await (const _ of timeoutTurn) {}
    return timeoutTurn.result;
  })();
  void timeoutTurnDone.catch(() => {});
  await assert.rejects(timeoutTurnDone);
  assert.ok(Date.now() - timeoutStartedAt < 250, "ignored AbortSignal must not delay adapter failure");
  assert.equal(lateCommitSignal?.aborted, true);
  assert.equal(lateCommitSettled, false, "the adapter must fail before the ignored operation settles");
  await lateCommitDone;
  const latePersisted = JSON.parse(lateCommittedBytes.toString("utf8"));
  assert.equal(latePersisted.access_token, refreshedAccessToken);
  assert.equal(latePersisted.refresh_token, rotatedRefreshToken);
  lateCommittedBytes.fill(0);
  assert.equal(maxActiveStoreOperations, 1, "a late store completion must stay quarantined from newer operations");

  failModels = true;
  let catalogError;
  await assert.rejects(
    createFxAgent({
      nativeAddon: addon,
      backend: "native",
      auth: { provider: "codex", session: store },
      home: root,
      workspaceRoot: workspace,
    }),
    (error) => {
      catalogError = error;
      return true;
    },
  );
  assert.match(String(catalogError), /Failed to load Codex model catalog/);
  for (const secret of [initialRefreshToken, rotatedRefreshToken, malformedSecret, gatewayApiKey]) {
    assert.equal(String(catalogError).includes(secret), false);
  }

  console.log("native Codex core passed: stores, refresh CAS, timeout poisoning, home isolation, catalog, streaming, switching, and profile opt-in");
} finally {
  if (agent) await agent.close().catch(() => {});
  for (const [key, value] of Object.entries(originalEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  if (originalHome === undefined) delete process.env.HOME;
  else process.env.HOME = originalHome;
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
  rmSync(root, { recursive: true, force: true });
}
