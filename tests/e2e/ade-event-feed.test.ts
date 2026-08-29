import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const INSTANCE_ID = "ade-e2e-instance";

type AgentRole = "main" | "subagent";
type AgentState = "idle" | "working" | "blocked";
type AttentionKind = "permission" | "question" | "route_recovery";

type AdeRecord = {
  schema_version: number;
  sequence: number;
  event: string;
  instance_id: string;
  context: {
    agent_role: AgentRole;
    workspace_root: string;
    session_id: string | null;
    parent_session_id: string | null;
    subagent_id: number | null;
    turn_id: number | null;
    agent_state: AgentState;
    attention_kind: AttentionKind | null;
  };
  payload: Record<string, unknown>;
};

class AdeReceiver {
  readonly records: AdeRecord[] = [];
  readonly errors: string[] = [];
  private listener: ReturnType<typeof Bun.listen> | null = null;
  private readonly pending = new WeakMap<object, Buffer>();

  constructor(readonly path: string) {}

  start(): void {
    this.listener = Bun.listen({
      unix: this.path,
      socket: {
        data: (socket, data) => this.acceptData(socket as object, data),
        close: (socket) => this.acceptClose(socket as object),
        error: (socket, error) => {
          this.errors.push(String(error));
          this.acceptClose(socket as object);
        },
      },
    });
  }

  close(): void {
    this.listener?.stop(true);
    this.listener = null;
    rmSync(this.path, { force: true });
  }

  async waitFor(
    predicate: (record: AdeRecord) => boolean,
    timeoutMs = TIMEOUT,
  ): Promise<AdeRecord> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const record = this.records.find(predicate);
      if (record) return record;
      await Bun.sleep(25);
    }
    throw new Error(
      `timed out waiting for ADE event; records=${JSON.stringify(this.records)}`,
    );
  }

  private acceptData(socket: object, data: Uint8Array): void {
    const previous = this.pending.get(socket) ?? Buffer.alloc(0);
    const bytes = Buffer.concat([previous, Buffer.from(data)]);
    let offset = 0;
    for (;;) {
      const newline = bytes.indexOf(0x0a, offset);
      if (newline < 0) break;
      this.acceptLine(bytes.subarray(offset, newline).toString("utf8"));
      offset = newline + 1;
    }
    this.pending.set(socket, bytes.subarray(offset));
  }

  private acceptClose(socket: object): void {
    const trailing = this.pending.get(socket);
    this.pending.delete(socket);
    if (trailing && trailing.length > 0) {
      this.errors.push(`connection closed before newline: ${trailing.toString("utf8")}`);
    }
  }

  private acceptLine(line: string): void {
    try {
      this.records.push(JSON.parse(line) as AdeRecord);
    } catch (error) {
      this.errors.push(`invalid JSON ${JSON.stringify(line)}: ${String(error)}`);
    }
  }
}

let root: string | null = null;
let session: TmuxSession | null = null;
let receiver: AdeReceiver | null = null;
let gateway: ReturnType<typeof startDynamicFakeGateway> | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  gateway?.stop();
  gateway = null;
  receiver?.close();
  receiver = null;
  if (root) rmSync(root, { recursive: true, force: true });
  root = null;
});

function eventIndex(
  records: AdeRecord[],
  event: string,
  role: AgentRole,
  after = -1,
): number {
  return records.findIndex(
    (record, index) =>
      index > after &&
      record.event === event &&
      record.context.agent_role === role,
  );
}

function latestPrompt(body: string): string {
  const request = JSON.parse(body) as { prompt?: unknown[] };
  return JSON.stringify(request.prompt?.at(-1) ?? "");
}

describe.skipIf(!tmuxAvailable())("ADE event feed", () => {
  test(
    "publishes ordered main, attention, subagent, and shutdown lifecycle records",
    async () => {
      const tempRoot = existsSync("/private/tmp") ? "/private/tmp" : tmpdir();
      root = realpathSync(mkdtempSync(join(tempRoot, "fx-ade-feed-e2e-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const socketPath = join(root, "ade.sock");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {} }),
      );
      writeFileSync(stderrPath, "");

      receiver = new AdeReceiver(socketPath);
      receiver.start();

      const childPrompt = "ADE_CHILD_PROMPT: run a terminal command";
      const childFinished = Promise.withResolvers<void>();
      gateway = startDynamicFakeGateway(async (body) => {
        const latest = latestPrompt(body);
        if (latest.includes('"toolCallId":"ade_question_1"')) {
          return fakeGatewayFinalText("ADE_QUESTION_DONE");
        }
        if (latest.includes('"toolCallId":"ade_child_terminal_1"')) {
          childFinished.resolve();
          return fakeGatewayFinalText("ADE_CHILD_DONE");
        }
        if (latest.includes('"toolCallId":"ade_parent_create_1"')) {
          await childFinished.promise;
          return fakeGatewayFinalText("ADE_PARENT_DONE");
        }
        if (latest.includes(childPrompt)) {
          return fakeGatewayToolCall("ade_child_terminal_1", "terminal", {
            action: "exec",
            command: "printf ADE_CHILD_TOOL > ade-child.txt",
            timeout_ms: 600_000,
          });
        }
        if (latest.includes("ADE_QUESTION_REQUEST")) {
          return fakeGatewayToolCall("ade_question_1", "ask_user_question", {
            questions: [{
              header: "ADE feed",
              question: "Which ADE event path should continue?",
              options: [
                { label: "Main", description: "Continue the main-agent fixture." },
                { label: "Child", description: "Continue the child-agent fixture." },
              ],
            }],
          });
        }
        if (latest.includes("ADE_SUBAGENT_REQUEST")) {
          return fakeGatewayToolCall("ade_parent_create_1", "subagent", {
            command: {
              create: {
                name: "ade-child",
                mode: "persistent",
                prompt: childPrompt,
                permission_mode: "ask",
              },
            },
          });
        }
        return new Response("unexpected ADE fixture request", { status: 500 });
      }, {
        classifierDecision: "caution",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });

      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        env: {
          HOME: realpathSync(home),
          AI_GATEWAY_API_KEY: "ade-event-feed-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          FX_ADE_SOCKET_PATH: socketPath,
          FX_ADE_INSTANCE_ID: INSTANCE_ID,
          NO_COLOR: "1",
        },
        width: 100,
        height: 28,
        stderrPath,
      });
      await session.waitForComposer(TIMEOUT);
      await receiver.waitFor((record) => record.event === "FxStarted");

      await session.sendText("ADE_QUESTION_REQUEST");
      await session.waitForText("Which ADE event path should continue?", TIMEOUT);
      await receiver.waitFor(
        (record) =>
          record.event === "AttentionRequired" &&
          record.context.agent_role === "main" &&
          record.payload.kind === "question",
      );
      await session.sendKeys("1");
      const questionResolution = await receiver.waitFor(
        (record) =>
          record.event === "AttentionResolved" &&
          record.context.agent_role === "main" &&
          record.payload.kind === "question",
      );
      expect(questionResolution.context.agent_state).toBe("working");
      expect(questionResolution.context.attention_kind).toBeNull();
      expect(questionResolution.context.turn_id).toBeGreaterThan(0);
      await session.waitForText("ADE_QUESTION_DONE", TIMEOUT);
      await session.waitForComposer(TIMEOUT);

      await session.sendText("ADE_SUBAGENT_REQUEST");
      await session.waitForText("Subagent ade-child needs permission", TIMEOUT);
      const childAttention = await receiver.waitFor(
        (record) =>
          record.event === "AttentionRequired" &&
          record.context.agent_role === "subagent" &&
          record.payload.kind === "permission",
      );
      expect(childAttention.context.session_id).not.toBeNull();
      expect(childAttention.context.parent_session_id).not.toBeNull();
      expect(childAttention.context.turn_id).toBeNull();
      await session.sendKeys("C-x");
      await session.waitForPane(
        (pane) =>
          pane.includes("Agents & processes") &&
          pane.includes("ade-child") &&
          pane.includes("approval"),
        TIMEOUT,
      );
      await session.sendKeys("Enter");
      await session.waitForPane(
        (pane) =>
          pane.includes("Subagent: ade-child") &&
          pane.includes("status: approval") &&
          pane.includes("printf ADE_CHILD_TOOL > ade-child.txt") &&
          pane.includes("❯ 1. Yes"),
        TIMEOUT,
      );
      await session.sendKeys("1");
      const childResolution = await receiver.waitFor(
        (record) =>
          record.event === "AttentionResolved" &&
          record.context.agent_role === "subagent" &&
          record.payload.kind === "permission",
      );
      expect(childResolution.context.session_id).toBe(childAttention.context.session_id);
      expect(childResolution.context.agent_state).toBe("working");
      expect(childResolution.context.attention_kind).toBeNull();
      await session.waitForText("ADE_CHILD_DONE", TIMEOUT);
      await session.sendKeys("C-x");
      await session.waitForText("ADE_PARENT_DONE", TIMEOUT);
      await receiver.waitFor(
        (record) =>
          record.event === "PostTurnEnd" &&
          record.context.agent_role === "subagent",
      );
      await session.waitForComposer(TIMEOUT);

      const originalMainSession = receiver.records.find(
        (record) =>
          record.event === "TurnStarted" &&
          record.context.agent_role === "main",
      )?.context.session_id;
      expect(originalMainSession).not.toBeNull();
      await session.sendText("/new");
      const newSession = await receiver.waitFor(
        (record) =>
          record.event === "SessionChanged" &&
          record.payload.previous_session_id === originalMainSession &&
          typeof record.payload.session_id === "string",
      );
      const freshMainSession = newSession.payload.session_id as string;
      expect(freshMainSession).not.toBe(originalMainSession);
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/resume");
      await session.waitForText("Sessions", TIMEOUT);
      await session.sendKeys("Tab");
      await session.waitForText("[All workspaces]", TIMEOUT);
      const resumePane = await session.waitForPane(
        (pane) =>
          pane.includes("Sessions 2") &&
          pane.includes("ADE_QUESTION_REQUEST") &&
          pane.includes("ADE_CHILD_PROMPT: run a terminal command"),
        TIMEOUT,
      );
      expect(resumePane.indexOf("ADE_QUESTION_REQUEST")).toBeLessThan(
        resumePane.indexOf("ADE_CHILD_PROMPT: run a terminal command"),
      );
      // The picker can preserve its prior selection while the all-workspaces
      // page loads. With exactly two rows, Up selects (or stays on) the first,
      // original main session deterministically.
      await session.sendKeys("Up");
      await session.sendKeys("Enter");
      await receiver.waitFor(
        (record) =>
          record.event === "SessionChanged" &&
          record.payload.previous_session_id === freshMainSession &&
          record.payload.session_id === originalMainSession,
      );
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      await receiver.waitFor((record) => record.event === "FxStopped");

      const records = receiver.records;
      expect(receiver.errors).toEqual([]);
      expect(records.length).toBeGreaterThan(12);
      expect(records.map((record) => record.sequence)).toEqual(
        records.map((_, index) => index + 1),
      );
      expect(records.every((record) => record.schema_version === 1)).toBe(true);
      expect(records.every((record) => record.instance_id === INSTANCE_ID)).toBe(true);
      expect(records.every(
        (record) => ["idle", "working", "blocked"].includes(record.context.agent_state),
      )).toBe(true);
      expect(records.every(
        (record) => record.context.agent_state === "blocked"
          ? record.context.attention_kind !== null
          : record.context.attention_kind === null,
      )).toBe(true);
      expect(records[0]?.event).toBe("FxStarted");
      expect(records.at(-1)?.event).toBe("FxStopped");

      const mainStarts = records.filter(
        (record) =>
          record.event === "TurnStarted" &&
          record.context.agent_role === "main",
      );
      const childStarts = records.filter(
        (record) =>
          record.event === "TurnStarted" &&
          record.context.agent_role === "subagent",
      );
      expect(mainStarts).toHaveLength(2);
      expect(childStarts).toHaveLength(1);
      expect(mainStarts.every((record) => record.context.turn_id !== null)).toBe(true);
      expect(childStarts[0]?.context.turn_id).not.toBeNull();

      const firstMainStart = eventIndex(records, "TurnStarted", "main");
      const firstPromptQueued = eventIndex(records, "PromptQueued", "main");
      const questionTool = eventIndex(records, "PreToolUse", "main", firstMainStart);
      const attention = eventIndex(records, "AttentionRequired", "main", questionTool);
      const resolution = eventIndex(records, "AttentionResolved", "main", attention);
      const firstMainEnd = eventIndex(records, "PostTurnEnd", "main", resolution);
      const secondPromptQueued = eventIndex(records, "PromptQueued", "main", firstMainEnd);
      const secondMainStart = eventIndex(records, "TurnStarted", "main", firstMainEnd);
      const subagentTool = eventIndex(records, "PreToolUse", "main", secondMainStart);
      const childStart = eventIndex(records, "TurnStarted", "subagent", subagentTool);
      const childTool = eventIndex(records, "PreToolUse", "subagent", childStart);
      const childAttentionIndex = eventIndex(records, "AttentionRequired", "subagent", childTool);
      const childResolutionIndex = eventIndex(records, "AttentionResolved", "subagent", childAttentionIndex);
      const childStop = eventIndex(records, "Stop", "subagent", childResolutionIndex);
      const childEnd = eventIndex(records, "PostTurnEnd", "subagent", childStop);
      const secondMainStop = eventIndex(records, "Stop", "main", subagentTool);
      const secondMainEnd = eventIndex(records, "PostTurnEnd", "main", secondMainStop);
      for (const [label, index] of Object.entries({
        firstMainStart,
        firstPromptQueued,
        questionTool,
        attention,
        resolution,
        firstMainEnd,
        secondPromptQueued,
        secondMainStart,
        subagentTool,
        childStart,
        childTool,
        childAttentionIndex,
        childResolutionIndex,
        childStop,
        childEnd,
        secondMainStop,
        secondMainEnd,
      })) {
        if (index < 0) {
          throw new Error(
            `missing ordered ${label}; records=${JSON.stringify(records)}`,
          );
        }
      }
      expect(firstPromptQueued).toBeLessThan(firstMainStart);
      expect(secondPromptQueued).toBeLessThan(secondMainStart);
      expect(records[firstMainEnd]?.context.agent_state).toBe("idle");
      expect(records[childEnd]?.context.agent_state).toBe("idle");
      expect(records[secondMainEnd]?.context.agent_state).toBe("idle");

      const mainSession = mainStarts[0]?.context.session_id;
      const childContext = childStarts[0]!.context;
      expect(mainSession).not.toBeNull();
      expect(childContext.session_id).not.toBeNull();
      expect(childContext.session_id).not.toBe(mainSession);
      expect(childContext.parent_session_id).toBe(mainSession);
      expect(childAttention.context.session_id).toBe(childContext.session_id);
      expect(childAttention.context.parent_session_id).toBe(mainSession);
      expect(records.filter(
        (record) =>
          record.event === "AttentionRequired" &&
          record.context.agent_role === "subagent" &&
          record.context.session_id === childContext.session_id &&
          record.payload.kind === "permission",
      )).toHaveLength(1);
      expect(records.some(
        (record) =>
          record.event === "AttentionRequired" &&
          record.context.agent_role === "main" &&
          record.payload.kind === "permission",
      )).toBe(false);
      expect(records.every((record) => record.context.workspace_root === realpathSync(workspace)))
        .toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    60_000,
  );
});

describe("ADE event feed process exclusions", () => {
  test("fx ask ignores ADE feed environment variables", async () => {
    const tempRoot = existsSync("/private/tmp") ? "/private/tmp" : tmpdir();
    root = realpathSync(mkdtempSync(join(tempRoot, "fx-ade-ask-e2e-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const socketPath = join(root, "ade.sock");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {} }),
    );
    receiver = new AdeReceiver(socketPath);
    receiver.start();
    gateway = startDynamicFakeGateway(() => fakeGatewayFinalText("ADE_ASK_DONE"));

    const proc = Bun.spawn([FX_BIN, "ask", "ADE_ASK_EXCLUSION"], {
      cwd: workspace,
      env: {
        ...process.env,
        HOME: home,
        AI_GATEWAY_API_KEY: "ade-ask-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_ADE_SOCKET_PATH: socketPath,
        FX_ADE_INSTANCE_ID: "ask-must-not-publish",
        NO_COLOR: "1",
      },
      stdout: "pipe",
      stderr: "pipe",
    });
    const [exitCode, stdout, stderr] = await Promise.all([
      proc.exited,
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    await Bun.sleep(100);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("ADE_ASK_DONE");
    expect(stderr).toBe("");
    expect(receiver.records).toEqual([]);
    expect(receiver.errors).toEqual([]);
  }, TIMEOUT);
});
