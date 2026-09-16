import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";

const TIMEOUT = 20_000;
const FIXTURE_DIGEST =
  "4b30a49b59bcbd52831b8f28c0739b1f333fbf81686ec7b026728943e467278c";
const fixture = JSON.parse(
  readFileSync(
    join(import.meta.dirname, "fixtures", "structured-inference-request-v1.json"),
    "utf8",
  ),
) as Record<string, unknown>;

const cleanupRoots: string[] = [];

afterEach(() => {
  for (const root of cleanupRoots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function accessToken(accountId: string): string {
  const payload = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: accountId },
  })).toString("base64url");
  return `header.${payload}.fixture-signature`;
}

function createRoot() {
  const root = realpathSync(
    mkdtempSync(join(tmpdir(), "fx-structured-inference-")),
  );
  cleanupRoots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stateRoot = join(root, "receipt-state");
  mkdirSync(home, { mode: 0o700 });
  mkdirSync(workspace, { mode: 0o700 });
  const fxDir = join(home, ".fx");
  mkdirSync(fxDir, { mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const token = accessToken("acct_structured_e2e");
  const authPath = join(fxDir, "chatgpt-auth.json");
  writeFileSync(authPath, JSON.stringify({
    version: 1,
    access_token: token,
    refresh_token: "fixture-refresh-token",
    expires_at_ms: Date.now() + 60 * 60 * 1000,
    account_id: "acct_structured_e2e",
  }) + "\n", { mode: 0o600 });
  chmodSync(authPath, 0o600);
  return { root, home, workspace, stateRoot, token };
}

type RecordedRequest = {
  method: string;
  path: string;
  search: string;
  authorization: string | null;
  accountId: string | null;
  sessionId: string | null;
  clientRequestId: string | null;
  body: string;
};

function completedSse(content: string, id: string): string {
  return `data: ${JSON.stringify({
    type: "response.output_text.delta",
    delta: content,
  })}\n\n` + `data: ${JSON.stringify({
    type: "response.completed",
    response: {
      id,
      status: "completed",
      usage: { input_tokens: 4, output_tokens: 2 },
    },
  })}\n\n`;
}

function startCodexFixture() {
  const requests: RecordedRequest[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const body = request.method === "POST" ? await request.text() : "";
      requests.push({
        method: request.method,
        path: url.pathname,
        search: url.search,
        authorization: request.headers.get("authorization"),
        accountId: request.headers.get("chatgpt-account-id"),
        sessionId: request.headers.get("session-id"),
        clientRequestId: request.headers.get("x-client-request-id"),
        body,
      });
      if (url.pathname === "/models") {
        return Response.json({ models: [
          {
            slug: "gpt-5.6-sol",
            visibility: "list",
            supported_in_api: true,
            supported_reasoning_levels: [
              { effort: "low" },
              { effort: "high" },
            ],
            additional_speed_tiers: [],
            input_modalities: ["text"],
            context_window: 272000,
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
          {
            slug: "gpt-5.4-mini",
            visibility: "list",
            supported_in_api: true,
            supported_reasoning_levels: [{ effort: "low" }],
            additional_speed_tiers: [],
            input_modalities: ["text"],
            context_window: 128000,
          },
        ] });
      }
      if (url.pathname !== "/responses") {
        return new Response("not found", { status: 404 });
      }
      if (body.includes("PROVIDER_FAILURE")) {
        return Response.json(
          { error: { message: "bounded fixture failure" } },
          { status: 503 },
        );
      }
      if (body.includes("REFUSE")) {
        const refusal = `data: ${JSON.stringify({
          type: "response.refusal.delta",
          delta: "fixture refusal",
        })}\n\n` + `data: ${JSON.stringify({
          type: "response.completed",
          response: { id: "resp_refusal", status: "completed" },
        })}\n\n`;
        return new Response(refusal, {
          headers: { "content-type": "text/event-stream" },
        });
      }
      const output = body.includes("SCHEMA_FAILURE")
        ? '{"answer":7}'
        : '{"answer":"subscription-ok"}';
      return new Response(completedSse(output, "resp_structured_e2e"), {
        headers: { "content-type": "text/event-stream" },
      });
    },
  });
  return {
    requests,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    stop() {
      server.stop(true);
    },
  };
}

function environment(
  root: ReturnType<typeof createRoot>,
  codex: ReturnType<typeof startCodexFixture>,
) {
  return {
    HOME: root.home,
    FX_AUTO_UPGRADE: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_E2E_OPENAI_CODEX_MODELS_URL: codex.modelsUrl,
    FX_E2E_OPENAI_CODEX_RESPONSES_URL: codex.responsesUrl,
    AI_GATEWAY_API_KEY: undefined,
    VERCEL_OIDC_TOKEN: undefined,
  };
}

function inputFrame(value: Record<string, unknown>): string {
  return JSON.stringify(value) + "\n";
}

async function invoke(
  root: ReturnType<typeof createRoot>,
  codex: ReturnType<typeof startCodexFixture>,
  frame: Record<string, unknown>,
) {
  return runFx(
    ["structured-inference", "--state-root", root.stateRoot],
    {
      cwd: root.workspace,
      env: environment(root, codex),
      stdin: inputFrame(frame),
      timeoutMs: TIMEOUT,
    },
  );
}

describe("structured subscription inference", () => {
  test("catalog precedes one tool-free Responses request and terminal replay and acknowledgement are idempotent", async () => {
    const root = createRoot();
    const codex = startCodexFixture();
    try {
      const first = await invoke(root, codex, fixture);
      expect(first.code).toBe(0);
      expect(first.stderr).toBe("");
      const terminal = JSON.parse(first.stdout) as Record<string, any>;
      expect(terminal.schema_id).toBe("fx.structured-subscription-inference");
      expect(terminal.version).toBe(1);
      expect(terminal.status).toBe("succeeded");
      expect(terminal.request_digest).toBe(FIXTURE_DIGEST);
      expect(terminal.output).toEqual({ answer: "subscription-ok" });
      expect(terminal.receipt.id).toMatch(/^[0-9a-f]{64}$/);
      expect(terminal.provenance).toMatchObject({
        credential_source: "chatgpt_subscription",
        catalog_provider: "codex",
        catalog_protocol: "chatgpt-codex-models",
        catalog_client_version: "0.153.0",
        model: "gpt-5.6-sol",
        effort: "high",
        effort_index: 1,
        provider: "codex",
        provider_protocol: "openai-codex-responses-sse-v1",
        provider_response_id: "resp_structured_e2e",
      });
      expect(terminal.provenance.credential_identity_sha256).toMatch(
        /^[0-9a-f]{64}$/,
      );
      expect(terminal.provenance.catalog_selection_digest).toMatch(
        /^[0-9a-f]{64}$/,
      );

      expect(codex.requests.map(({ method, path }) => `${method} ${path}`)).toEqual([
        "GET /models",
        "POST /responses",
      ]);
      const catalogRequest = codex.requests[0]!;
      expect(catalogRequest.search).toBe("?client_version=0.153.0");
      expect(catalogRequest.authorization).toBe(`Bearer ${root.token}`);
      expect(catalogRequest.accountId).toBe("acct_structured_e2e");
      const providerRequest = codex.requests[1]!;
      expect(providerRequest.authorization).toBe(`Bearer ${root.token}`);
      expect(providerRequest.accountId).toBe("acct_structured_e2e");
      expect(providerRequest.sessionId).toBeNull();
      expect(providerRequest.clientRequestId).toBeNull();
      const body = JSON.parse(providerRequest.body) as Record<string, any>;
      expect(body.model).toBe("gpt-5.6-sol");
      expect(body.input).toEqual([{
        role: "user",
        content: [{
          type: "input_text",
          text: "Return one object with answer set to subscription-ok.",
        }],
      }]);
      expect(body.tools).toBeUndefined();
      expect(body.tool_choice).toBe("none");
      expect(body.reasoning.effort).toBe("high");
      expect(body.text.format).toEqual({
        type: "json_schema",
        name: "fx_structured_subscription_inference_v1",
        description: "Return one value matching the caller's strict object schema.",
        schema: fixture.schema,
        strict: true,
      });

      const requestCount = codex.requests.length;
      const replay = await invoke(root, codex, fixture);
      expect(replay.code).toBe(0);
      expect(replay.stderr).toBe("");
      expect(replay.stdout).toBe(first.stdout);
      expect(codex.requests).toHaveLength(requestCount);

      const conflict = await invoke(root, codex, {
        ...fixture,
        prompt: "conflicting prompt",
      });
      expect(conflict.code).toBe(2);
      expect(JSON.parse(conflict.stdout).code).toBe(
        "StructuredInferenceCallerKeyConflict",
      );
      expect(codex.requests).toHaveLength(requestCount);

      const ack = {
        schema_id: fixture.schema_id,
        version: fixture.version,
        operation: "ack",
        caller_key: fixture.caller_key,
        receipt_id: terminal.receipt.id,
      };
      const firstAck = await invoke(root, codex, ack);
      const secondAck = await invoke(root, codex, ack);
      expect(firstAck.code).toBe(0);
      expect(secondAck.code).toBe(0);
      expect(secondAck.stdout).toBe(firstAck.stdout);
      expect(JSON.parse(firstAck.stdout)).toMatchObject({
        operation: "ack",
        receipt_id: terminal.receipt.id,
        acknowledged: true,
      });
      expect(codex.requests).toHaveLength(requestCount);
      expect(existsSync(root.stateRoot)).toBe(true);
      expect(statSync(root.stateRoot).mode & 0o777).toBe(0o700);
      expect(existsSync(join(root.home, ".fx", "sessions"))).toBe(false);
    } finally {
      codex.stop();
    }
  }, TIMEOUT);

  test("refusal schema failure and provider failure become durable terminal receipts", async () => {
    const root = createRoot();
    const codex = startCodexFixture();
    try {
      const cases = [
        { marker: "REFUSE", expected: "refused" },
        { marker: "SCHEMA_FAILURE", expected: "schema_failed" },
        { marker: "PROVIDER_FAILURE", expected: "provider_failed" },
      ];
      for (const [index, value] of cases.entries()) {
        const frame = {
          ...fixture,
          caller_key: `terminal-${index}`,
          prompt: value.marker,
        };
        const first = await invoke(root, codex, frame);
        expect(first.code).toBe(0);
        expect(first.stderr).toBe("");
        const terminal = JSON.parse(first.stdout);
        expect(terminal.status).toBe(value.expected);
        expect(terminal.receipt.id).toMatch(/^[0-9a-f]{64}$/);
        const count = codex.requests.length;
        const replay = await invoke(root, codex, frame);
        expect(replay.stdout).toBe(first.stdout);
        expect(codex.requests).toHaveLength(count);
      }
      expect(codex.requests.filter(({ path }) => path === "/responses")).toHaveLength(3);
      expect(existsSync(join(root.home, ".fx", "sessions"))).toBe(false);
    } finally {
      codex.stop();
    }
  }, TIMEOUT);

  test("pre-admission cancellation is durable and performs no auth catalog or provider request", async () => {
    const root = createRoot();
    const codex = startCodexFixture();
    try {
      const cancelledFrame = {
        ...fixture,
        caller_key: "cancelled-key",
        cancelled: true,
      };
      const first = await invoke(root, codex, cancelledFrame);
      expect(first.code).toBe(0);
      expect(first.stderr).toBe("");
      expect(JSON.parse(first.stdout).status).toBe("cancelled");
      expect(codex.requests).toHaveLength(0);

      const replay = await invoke(root, codex, {
        ...cancelledFrame,
        cancelled: false,
      });
      expect(replay.stdout).toBe(first.stdout);
      expect(codex.requests).toHaveLength(0);
      expect(existsSync(join(root.home, ".fx", "sessions"))).toBe(false);
    } finally {
      codex.stop();
    }
  }, TIMEOUT);
});
