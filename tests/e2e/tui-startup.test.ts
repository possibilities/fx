import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
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
import { FX_BIN, HAS_API_KEY } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  hasEmptyComposer,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP = !tmuxAvailable() || !HAS_API_KEY;
const SKIP_TMUX = !tmuxAvailable();
const TIMEOUT = 30_000;

let session: TmuxSession | null = null;

function nestedText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(nestedText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [nestedText(value.text), nestedText(value.value), nestedText(value.content)].join("");
  }
  return "";
}

function gatewayPromptText(body: string): string {
  const request = JSON.parse(body) as { prompt: Array<{ content: unknown }> };
  return request.prompt.map((message) => nestedText(message.content)).join("\n");
}

const MCP_STDIO_FIXTURE = join(
  import.meta.dirname,
  "fixtures",
  "mcp-modern-stdio.mjs",
);
function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

function writeStateSession(
  home: string,
  workspaceRoot: string,
  sessionId: string,
  updatedAtMs: number,
): void {
  const sessionDir = join(home, ".fx", "sessions", sessionId);
  mkdirSync(sessionDir, { recursive: true, mode: 0o700 });
  chmodSync(join(home, ".fx"), 0o700);
  chmodSync(join(home, ".fx", "sessions"), 0o700);
  chmodSync(sessionDir, 0o700);
  writeFileSync(
    join(sessionDir, "session.json"),
    JSON.stringify({
      schema_version: 2,
      id: sessionId,
      created_at_ms: 1,
      updated_at_ms: updatedAtMs,
      workspace_root: workspaceRoot,
      conversation_language: "en",
      history_len: 0,
      history: [],
      total_input_tokens: 0,
      total_output_tokens: 0,
    }) + "\n",
    { mode: 0o600 },
  );
}

async function waitForPath(path: string, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) return;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for ${path}`);
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitForProcessExit(pid: number, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!processAlive(pid)) return;
    await Bun.sleep(25);
  }
  throw new Error(`process ${pid} did not exit`);
}
afterEach(async () => {
  if (session) { await session.kill(); session = null; }
});

describe.skipIf(SKIP)("tui: startup and exit", () => {
  test(
    "fx launches and shows prompt",
    async () => {
      session = await TmuxSession.create();
      const pane = await session.waitForComposer(10_000);
      expect(hasEmptyComposer(pane)).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "/help opens the command catalog",
    async () => {
      session = await TmuxSession.create();
      await session.waitForComposer(10_000);
      await session.sendText("/help");
      const pane = await session.waitForText("Commands 36", 5_000);
      expect(pane).toContain("[All]");
      expect(pane).toContain("Tab Category");
      expect(pane).toContain("Enter Open");
      expect(pane).toContain("Run /help for commands");
    },
    TIMEOUT,
  );

  test(
    "/quit exits cleanly",
    async () => {
      session = await TmuxSession.create();
      await session.waitForComposer(10_000);
      await session.sendText("/quit");
      const exited = await session.waitForSessionEnd(5_000);
      expect(exited).toBe(true);
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP_TMUX)("tui: fresh-session commands", () => {
  test(
    "global native tool suppression sends the TUI model an empty native catalog",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-no-native-tools-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home);
      mkdirSync(workspace);
      writeFileSync(stderrPath, "");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("TUI_NATIVE_TOOLS_DISABLED"),
      ]);

      try {
        session = await TmuxSession.create({
          cmd: `${FX_BIN} --no-native-tools`,
          cwd: workspace,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "fake-tui-native-tool-gate-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
          },
          stderrPath,
        });

        await session.waitForComposer(10_000);
        await session.sendText("Answer without native tools.");
        await session.waitForText("TUI_NATIVE_TOOLS_DISABLED", 10_000);
        expect(gateway.requests).toHaveLength(1);
        expect((JSON.parse(gateway.requests[0]!.body) as { tools?: unknown[] }).tools)
          .toEqual([]);
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        await session.kill();
        session = null;
      } finally {
        gateway.stop();
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "global native tool selection sends the TUI model only the ordered allowlist",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-native-tool-selection-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home);
      mkdirSync(workspace);
      writeFileSync(stderrPath, "");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("TUI_NATIVE_TOOLS_SELECTED"),
      ]);

      try {
        session = await TmuxSession.create({
          cmd: `${FX_BIN} --tool terminal:exec --tool read_file`,
          cwd: workspace,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "fake-tui-native-tool-selection-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
          },
          stderrPath,
        });

        await session.waitForComposer(10_000);
        await session.sendText("Answer with the selected native tools.");
        await session.waitForText("TUI_NATIVE_TOOLS_SELECTED", 10_000);
        expect(gateway.requests).toHaveLength(1);
        const request = JSON.parse(gateway.requests[0]!.body) as {
          tools: Array<{ name: string }>;
        };
        expect(request.tools.map((tool) => tool.name)).toEqual([
          "terminal",
          "read_file",
        ]);
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        await session.kill();
        session = null;
      } finally {
        gateway.stop();
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "exclusive invocation skill roots reach TUI in flag order without defaults",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-exclusive-skill-roots-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const firstRoot = join(root, "first-skills");
      const secondRoot = join(root, "second-skills");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx", "skills", "managed-default"), {
        recursive: true,
      });
      mkdirSync(join(workspace, "skills", "workspace-default"), {
        recursive: true,
      });
      mkdirSync(join(firstRoot, "first-invocation"), { recursive: true });
      mkdirSync(join(secondRoot, "second-invocation"), { recursive: true });
      writeFileSync(
        join(home, ".fx", "skills", "managed-default", "SKILL.md"),
        "---\nname: managed-default\ndescription: must not load\n---\n",
      );
      writeFileSync(
        join(workspace, "skills", "workspace-default", "SKILL.md"),
        "---\nname: workspace-default\ndescription: must not load\n---\n",
      );
      writeFileSync(
        join(firstRoot, "first-invocation", "SKILL.md"),
        "---\nname: first-invocation\ndescription: first selected root\n---\n",
      );
      writeFileSync(
        join(secondRoot, "second-invocation", "SKILL.md"),
        "---\nname: second-invocation\ndescription: second selected root\n---\n",
      );
      writeFileSync(stderrPath, "");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("TUI_EXCLUSIVE_SKILL_ROOTS_COMPLETE"),
      ]);

      try {
        session = await TmuxSession.create({
          cmd: `${FX_BIN} --no-default-skills --skills-dir ${firstRoot} --skills-dir=${secondRoot}`,
          cwd: workspace,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "fake-tui-exclusive-skills-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
          },
          stderrPath,
        });

        await session.waitForComposer(10_000);
        await session.sendText("List available skills.");
        await session.waitForText("TUI_EXCLUSIVE_SKILL_ROOTS_COMPLETE", 10_000);
        expect(gateway.requests).toHaveLength(1);
        const body = gateway.requests[0]!.body;
        expect(body).toContain("first-invocation");
        expect(body).toContain("second-invocation");
        expect(body.indexOf("first-invocation")).toBeLessThan(
          body.indexOf("second-invocation"),
        );
        expect(body).not.toContain("managed-default");
        expect(body).not.toContain("workspace-default");
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        await session.kill();
        session = null;
      } finally {
        gateway.stop();
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "global project instruction suppression keeps TUI runtime context",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-no-project-instructions-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const globalRule = "TUI_GLOBAL_RULE_MUST_BE_ABSENT";
      const projectRule = "TUI_PROJECT_RULE_MUST_BE_ABSENT";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace);
      writeFileSync(join(home, ".fx", "AGENTS.md"), `${globalRule}\n`);
      writeFileSync(join(workspace, "AGENTS.md"), `${projectRule}\n`);
      writeFileSync(stderrPath, "");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("TUI_PROJECT_INSTRUCTIONS_DISABLED"),
      ]);

      try {
        session = await TmuxSession.create({
          cmd: `${FX_BIN} --no-project-instructions`,
          cwd: workspace,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "fake-tui-project-instruction-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
          },
          stderrPath,
        });

        await session.waitForComposer(10_000);
        await session.sendText("Answer using current runtime facts.");
        await session.waitForText("TUI_PROJECT_INSTRUCTIONS_DISABLED", 10_000);
        expect(gateway.requests).toHaveLength(1);
        const promptText = gatewayPromptText(gateway.requests[0]!.body);
        expect(promptText).not.toContain(globalRule);
        expect(promptText).not.toContain(projectRule);
        expect(promptText).toContain(`workspace_root: ${realpathSync(workspace)}`);
        expect(promptText).toContain("Runtime context: permission mode is auto.");
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        await session.kill();
        session = null;
      } finally {
        gateway.stop();
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "launch permission policy replaces ambient rules and survives allowlist reloads",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-tui-permissions-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const policyPath = join(root, "launch-permissions.json");
      const settingsPath = join(home, ".fx", "settings.json");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        settingsPath,
        JSON.stringify({ permission: { bash: { "ambient *": "allow" } } }),
      );
      writeFileSync(
        policyPath,
        JSON.stringify({ bash: { "launch *": "allow" }, edit: "deny" }),
      );
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cmd: `${shellQuote(FX_BIN)} --permissions-file ${shellQuote(policyPath)}`,
          cwd: workspace,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
          },
          stderrPath,
          width: 120,
          height: 40,
        });

        await session.waitForComposer(10_000);
        await session.sendText("/permissions");
        const initial = await session.waitForText("launch *", 5_000);
        expect(initial).not.toContain("ambient *");

        await session.sendText('/allowlist user add command "mutated *"');
        await session.waitForText("added command", 5_000);
        await session.sendText("/clear");
        await session.waitForPane(
          (pane) => !pane.includes("added command") && hasEmptyComposer(pane),
          5_000,
        );
        await session.sendText("/permissions");
        const latestPermissions = await session.waitForPane(
          (pane) =>
            pane.includes("launch *") &&
            pane.includes("saved-session permission rules: none"),
          5_000,
        );
        expect(latestPermissions).toContain("launch *");
        expect(latestPermissions).toContain("deny edit -> *");
        expect(latestPermissions).not.toContain("ambient *");
        expect(latestPermissions).not.toContain("mutated *");

        const persisted = JSON.parse(readFileSync(settingsPath, "utf8"));
        expect(persisted.permission.bash["mutated *"]).toBe("allow");
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        session = null;
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "statusline hides the workspace identity by default",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-statusline-default-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace-default-hidden");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home, { recursive: true });
      mkdirSync(join(workspace, ".git"), { recursive: true });
      writeFileSync(join(workspace, ".git", "HEAD"), "ref: refs/heads/default-hidden-branch\n");
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
          },
          stderrPath,
          width: 100,
          height: 30,
        });

        const pane = await session.waitForComposer(10_000);
        expect(pane).not.toContain("workspace-default-hidden");
        expect(pane).not.toContain("default-hidden-branch");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "/help keeps command descriptions close after a wide-to-narrow resize",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-help-columns-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home, { recursive: true });
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
          },
          stderrPath,
          width: 160,
          height: 40,
        });

        await session.waitForComposer(10_000);
        await session.sendText("/help");
        const wide = await session.waitForPane(
          (pane) => pane.includes("/help") && pane.includes("show available slash commands"),
          5_000,
        );
        const wideHelp = wide.split("\n").find(
          (line) => line.includes("/help") && line.includes("show available slash commands"),
        );
        expect(wideHelp).toBeDefined();
        const wideDescriptionColumn = wideHelp!.indexOf("show available slash commands");
        expect(wideDescriptionColumn).toBe(18);

        await session.resizeWindow(60, 40);
        const narrow = await session.waitForPane(
          (pane) => pane.split("\n").some(
            (line) => line.includes("/help") && line.includes("show available"),
          ),
          5_000,
        );
        const narrowHelp = narrow.split("\n").find(
          (line) => line.includes("/help") && line.includes("show available"),
        );
        expect(narrowHelp).toBeDefined();
        expect(narrowHelp!.indexOf("show available")).toBe(wideDescriptionColumn);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "statusline refreshes the working directory and Git branch",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-statusline-")));
      const home = join(root, "home");
      const repository = join(root, "repository");
      const workspace = join(repository, "packages", "status-root");
      const headPath = join(repository, ".git", "HEAD");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(join(repository, ".git"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(headPath, "ref: refs/heads/initial-branch\n");
      writeFileSync(
        join(home, ".fx", "settings.json"),
        `${JSON.stringify({ statusLine: { workspace: true }, fast_mode: false })}\n`,
      );
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
          },
          stderrPath,
          width: 100,
          height: 30,
        });

        await session.waitForPane(
          (pane) => pane.includes("status-root") && pane.includes("initial-branch"),
          10_000,
        );

        writeFileSync(headPath, "ref: refs/heads/refreshed-branch\n");
        await session.resizeWindow(101, 30);
        await session.waitForPane(
          (pane) => pane.includes("status-root") && pane.includes("refreshed-branch"),
          5_000,
        );

        writeFileSync(headPath, "0123456789abcdef0123456789abcdef01234567\n");
        await session.resizeWindow(100, 30);
        await session.waitForText("detached:0123456789ab", 5_000);

        await session.resizeWindow(50, 30);
        const narrow = await session.waitForPane(
          (pane) => pane.includes("s-root") && pane.includes("detached:"),
          5_000,
        );
        expect(narrow).not.toContain("initial-branch");
        expect(session.isAlive()).toBe(true);

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "restore the launch header without retaining prior output",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-fresh-session-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home, { recursive: true });
      writeFileSync(stderrPath, "");

      const version = execFileSync(FX_BIN, ["--version"], { encoding: "utf8" }).trim();
      const banner = `𝒇x v${version} · Run /help for commands`;

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
          },
          stderrPath,
          width: 120,
          height: 40,
        });

        const initial = await session.waitForText(banner, 10_000);
        expect(initial.split(banner)).toHaveLength(2);

        for (const command of ["/clear", "/reset", "/new"]) {
          await session.sendText("/status");
          await session.waitForText("model=", 5_000);
          await session.sendText(command);
          const pane = await session.waitForPane(
            (value) =>
              value.includes(banner) &&
              !value.includes("model=") &&
              hasEmptyComposer(value),
            5_000,
          );
          expect(pane.split(banner)).toHaveLength(2);
          expect(session.isAlive()).toBe(true);
        }

        await session.sendText("/clear");
        const repeated = await session.waitForPane(
          (value) => value.includes(banner) && hasEmptyComposer(value),
          5_000,
        );
        expect(repeated.split(banner)).toHaveLength(2);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP_TMUX)("tui: process effort override", () => {
  test(
    "FX_EFFORT wins at startup and on resume without being saved",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-effort-override-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const model = "provider/effort-override-model";
      const overrideMarker = "EFFORT_OVERRIDE_REPLY";
      const resumeMarker = "EFFORT_RESUME_REPLY";
      mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(stderrPath, "");
      const settingsPath = join(home, ".fx", "settings.json");
      const settings = `${JSON.stringify({ model, effort: "low" })}\n`;
      writeFileSync(settingsPath, settings, { mode: 0o600 });
      const gateway = startFakeGateway(
        [fakeGatewayFinalText(overrideMarker), fakeGatewayFinalText(resumeMarker)],
        {
          models: [{
            id: model,
            type: "language",
            tags: ["reasoning", "tool-use"],
            context_window: 750_000,
            max_tokens: 64_000,
            reasoning_options: [{ type: "effort", values: ["low", "high"] }],
          }],
        },
      );
      const env = {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-effort-override-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_AUTO_UPGRADE: "0",
        FX_EFFORT: undefined,
        NO_COLOR: "1",
      };

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          env: { ...env, FX_EFFORT: "high" },
          stderrPath,
          width: 100,
          height: 30,
        });
        const startup = await session.waitForComposer(10_000);
        expect(startup).toContain("· high");
        expect(startup).not.toContain("· low");
        await session.sendText("Reply with the override marker.");
        await session.waitForText(overrideMarker, TIMEOUT);
        expect(gateway.requests).toHaveLength(1);
        expect(JSON.parse(gateway.requests[0]!.body)).toMatchObject({ reasoning: "high" });
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        await session.kill();
        session = null;
        expect(readFileSync(settingsPath, "utf8")).toBe(settings);

        session = await TmuxSession.create({
          cmd: `${FX_BIN} --resume-last`,
          cwd: workspace,
          env,
          stderrPath,
          width: 100,
          height: 30,
        });
        const resumed = await session.waitForComposer(10_000);
        expect(resumed).toContain("· low");
        expect(resumed).not.toContain("· high");
        await session.sendText("Reply with the resume marker.");
        await session.waitForText(resumeMarker, TIMEOUT);
        expect(gateway.requests).toHaveLength(2);
        expect(JSON.parse(gateway.requests[1]!.body)).toMatchObject({ reasoning: "low" });
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );
});

describe.skipIf(SKIP_TMUX)("tui: selected state root", () => {
  test(
    "selected profile data drives TUI while terminal and MCP children retain HOME",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-tui-state-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stateHome = join(root, "state");
      const stderrPath = join(root, "stderr.log");
      const mcpPidPath = join(root, "mcp.pid");
      const mcpEnvironmentPath = join(root, "mcp-environment.json");
      const ambientMcpMarker = join(root, "ambient-mcp-launched");
      mkdirSync(join(home, ".fx", "skills", "ambient-state-skill"), {
        recursive: true,
      });
      mkdirSync(join(stateHome, ".fx", "skills", "isolated-state-skill"), {
        recursive: true,
      });
      mkdirSync(join(home, ".codex", "skills", "ambient-profile-skill"), {
        recursive: true,
      });
      mkdirSync(join(stateHome, ".codex", "skills", "selected-profile-skill"), {
        recursive: true,
      });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(stderrPath, "");
      writeFileSync(
        join(stateHome, ".fx", "settings.json"),
        JSON.stringify({ model: FAKE_GATEWAY_MODEL }) + "\n",
      );
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ model: "ambient/model-must-not-load" }) + "\n",
      );
      writeFileSync(join(stateHome, ".fx", "api-key"), "selected-state-key\n", {
        mode: 0o600,
      });
      writeFileSync(join(home, ".fx", "api-key"), "ambient-key\n", {
        mode: 0o600,
      });
      writeFileSync(join(stateHome, ".fx", "AGENTS.md"), "SELECTED_PROFILE_INSTRUCTIONS\n");
      writeFileSync(join(home, ".fx", "AGENTS.md"), "AMBIENT_PROFILE_INSTRUCTIONS\n");
      writeFileSync(
        join(stateHome, ".fx", "SYSTEM_APPEND.md"),
        "SELECTED_STATE_SYSTEM_APPEND\n",
      );
      writeFileSync(
        join(home, ".fx", "SYSTEM_APPEND.md"),
        "AMBIENT_STATE_SYSTEM_APPEND\n",
      );
      writeFileSync(
        join(stateHome, ".fx", "skills", "isolated-state-skill", "SKILL.md"),
        "---\nname: isolated-state-skill\ndescription: selected state skill\n---\n\nSELECTED_STATE_SKILL_BODY\n",
      );
      writeFileSync(
        join(home, ".fx", "skills", "ambient-state-skill", "SKILL.md"),
        "---\nname: ambient-state-skill\ndescription: ambient state skill\n---\n\nAMBIENT_STATE_SKILL_BODY\n",
      );
      writeFileSync(
        join(stateHome, ".codex", "skills", "selected-profile-skill", "SKILL.md"),
        "---\nname: selected-profile-skill\ndescription: selected profile skill\n---\n\nSELECTED_PROFILE_SKILL_BODY\n",
      );
      writeFileSync(
        join(home, ".codex", "skills", "ambient-profile-skill", "SKILL.md"),
        "---\nname: ambient-profile-skill\ndescription: ambient profile skill\n---\n\nAMBIENT_PROFILE_SKILL_BODY\n",
      );
      writeFileSync(
        join(stateHome, ".fx", "mcp.json"),
        JSON.stringify({
          mcp: {
            selected: {
              type: "local",
              command: [process.execPath, MCP_STDIO_FIXTURE],
              enabled: true,
              environment: {
                FX_MCP_PID_PATH: mcpPidPath,
                FX_MCP_ENV_CAPTURE: mcpEnvironmentPath,
              },
            },
          },
        }),
      );
      writeFileSync(
        join(home, ".fx", "mcp.json"),
        JSON.stringify({
          mcp: {
            ambient: {
              type: "local",
              command: [
                "/bin/sh",
                "-c",
                `printf ambient > ${shellQuote(ambientMcpMarker)}`,
              ],
              enabled: true,
            },
          },
        }),
      );

      const gateway = startFakeGateway([
        fakeGatewayToolCall("state_skill", "skill", {
          name: "isolated-state-skill",
        }),
        fakeGatewayToolCall("state_home", "terminal", {
          action: "exec",
          command: "printf '%s' \"$HOME\"",
          timeout_ms: 5_000,
        }),
        fakeGatewayFinalText("TUI isolated state complete"),
      ]);
      let mcpPid: number | null = null;
      try {
        session = await TmuxSession.create({
          cmd: `${shellQuote(FX_BIN)} --state-dir ${shellQuote(stateHome)}`,
          cwd: workspace,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "",
            VERCEL_OIDC_TOKEN: "",
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: undefined,
            FX_PERMISSION_MODE: "yolo",
            FX_AUTO_UPGRADE: "0",
          },
          stderrPath,
          width: 120,
          height: 40,
        });
        await session.waitForComposer(10_000);
        await waitForPath(mcpEnvironmentPath);
        await waitForPath(mcpPidPath);
        mcpPid = Number(readFileSync(mcpPidPath, "utf8").trim());

        await session.sendText(
          "$selected-profile-skill $isolated-state-skill inspect isolated state.",
        );
        await session.waitForText("TUI isolated state complete", 15_000);

        expect(gateway.requests).toHaveLength(3);
        expect(gateway.requests[0]!.headers.get("ai-language-model-id")).toBe(
          FAKE_GATEWAY_MODEL,
        );
        expect(gateway.requests[0]!.headers.get("authorization")).toBe(
          "Bearer selected-state-key",
        );
        expect(gateway.requests[0]!.body).toContain("SELECTED_PROFILE_SKILL_BODY");
        expect(gateway.requests[0]!.body).toContain("isolated-state-skill");
        expect(gateway.requests[0]!.body).toContain("SELECTED_PROFILE_INSTRUCTIONS");
        expect(gateway.requests[0]!.body).toContain("SELECTED_STATE_SYSTEM_APPEND");
        expect(gateway.requests[0]!.body).toContain(
          "You are fx, a local coding CLI assistant",
        );
        expect(gateway.requests[0]!.body).not.toContain("ambient-state-skill");
        expect(gateway.requests[0]!.body).not.toContain("ambient-profile-skill");
        expect(gateway.requests[0]!.body).not.toContain("AMBIENT_PROFILE_INSTRUCTIONS");
        expect(gateway.requests[0]!.body).not.toContain("AMBIENT_STATE_SYSTEM_APPEND");
        expect(gateway.requests[1]!.body).toContain("SELECTED_STATE_SKILL_BODY");
        expect(gateway.requests[1]!.body).not.toContain("AMBIENT_STATE_SKILL_BODY");
        expect(gateway.requests[2]!.body).toContain(home);
        const mcpEnvironment = JSON.parse(
          readFileSync(mcpEnvironmentPath, "utf8"),
        );
        expect(mcpEnvironment.home).toBe(home);
        expect(existsSync(ambientMcpMarker)).toBe(false);

        await session.waitForComposer(5_000);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        session = null;
        await waitForProcessExit(mcpPid);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        if (mcpPid !== null && processAlive(mcpPid)) {
          process.kill(mcpPid, "SIGKILL");
        }
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "TUI resume cannot cross selected state roots",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-tui-resume-state-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stateA = join(root, "state-a");
      const stateB = join(root, "state-b");
      const validStderr = join(root, "valid.stderr");
      const invalidStderr = join(root, "invalid.stderr");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      mkdirSync(join(stateA, ".fx"), { recursive: true });
      mkdirSync(join(stateB, ".fx"), { recursive: true });
      writeFileSync(validStderr, "");
      writeFileSync(invalidStderr, "");
      writeStateSession(stateA, realpathSync(workspace), "state-a-session", 20);
      writeStateSession(stateB, realpathSync(workspace), "state-b-session", 30);
      writeStateSession(home, realpathSync(workspace), "ambient-session", 40);

      try {
        session = await TmuxSession.create({
          cmd: `${shellQuote(FX_BIN)} --state-dir ${shellQuote(stateA)} resume state-a-session`,
          cwd: workspace,
          env: { HOME: home, FX_AUTO_UPGRADE: "0" },
          stderrPath: validStderr,
        });
        await session.waitForComposer(10_000);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        session = null;
        expect(readFileSync(validStderr, "utf8")).toBe("");

        session = await TmuxSession.create({
          cmd: `${shellQuote(FX_BIN)} --state-dir ${shellQuote(stateA)} resume state-b-session`,
          cwd: workspace,
          env: { HOME: home, FX_AUTO_UPGRADE: "0" },
          stderrPath: invalidStderr,
          startupWaitMs: 100,
        });
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        session = null;
        expect(readFileSync(invalidStderr, "utf8")).toContain(
          "saved session not found",
        );
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP_TMUX)("tui: MCP startup", () => {
  test(
    "unresponsive MCP discovery does not block startup or shutdown",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-mcp-startup-")));
      const home = join(root, "home");
      mkdirSync(join(home, ".fx"), { recursive: true });

      let discoveryRequests = 0;
      const server = Bun.serve({
        hostname: "127.0.0.1",
        port: 0,
        async fetch(request) {
          const body = await request.text();
          if (body.includes('"method":"server/discover"')) discoveryRequests += 1;
          return await new Promise<Response>(() => {});
        },
      });
      writeFileSync(
        join(home, ".fx", "mcp.json"),
        JSON.stringify({
          mcp: {
            pending: {
              type: "http",
              url: `http://127.0.0.1:${server.port}`,
              enabled: true,
            },
          },
        }),
      );

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
          },
        });
        const pane = await session.waitForComposer(5_000);
        expect(hasEmptyComposer(pane)).toBe(true);
        const startupDeadline = Date.now() + 5_000;
        while (discoveryRequests < 1 && Date.now() < startupDeadline) {
          await Bun.sleep(25);
        }
        expect(discoveryRequests).toBe(1);

        await session.sendText("/mcp");
        const summary = await session.waitForText("MCP 1", 5_000);
        expect(summary).toContain("pending");
        expect(summary).toContain("Connecting");
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes("[Servers]"), 5_000);
        await session.sendText("/mcp list");
        const status = await session.waitForText("state=connecting", 5_000);
        expect(status).toContain("pending source=profile scope=profile policy=optional");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        server.stop(true);
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP_TMUX)("tui: credential onboarding", () => {
  test(
    "/setup opens an inline status-first hub",
    async () => {
      const home = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-direct-setup-")));
      session = await TmuxSession.create({
        env: {
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          HOME: home,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "0",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("/setup");
      const setup = await session.waitForPane(
        (pane) =>
          pane.includes("Setup") &&
          pane.includes("Connections") &&
          pane.includes("Model provider") &&
          pane.includes("Vercel team") &&
          pane.includes("Credential source") &&
          pane.includes("Enter Open") &&
          pane.includes("Esc Close"),
        TIMEOUT,
      );
      expect(setup).not.toContain("AI_GATEWAY_API_KEY");
      expect(setup).not.toContain("fx login");
      expect(setup).not.toContain("Vercel account");
      expect(setup).not.toContain("run /login");

      for (let index = 0; index < 2; index += 1) {
        await session.sendKeys("Down");
      }
      await session.sendKeys("Enter");
      await session.waitForPane(
        (pane) => pane.includes("Credential source") && pane.includes("Automatic"),
        TIMEOUT,
      );
      await session.sendKeys("Escape");
      await session.waitForText("Setup", TIMEOUT);
      await session.sendKeys("Escape");
      await session.waitForComposer(TIMEOUT);
    },
    TIMEOUT,
  );

  test(
    "startup shows credential onboarding on the first frame and Escape remains session-only",
    async () => {
      const home = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-login-onboarding-")));
      const env = {
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        HOME: home,
        USER: "fx-e2e-login-onboarding",
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_NO_OPEN_BROWSER: "1",
        FX_SKIP_ONBOARDING: "0",
      };

      session = await TmuxSession.create({ env });

      const initial = await session.waitForText("Welcome to fx", TIMEOUT);
      expect(initial).toContain("Sign in with Vercel");
      expect(initial).toContain("Add an API key");
      expect(initial).toContain("Esc to set up later");
      expect(initial).not.toContain("Change team");
      expect(initial).not.toContain("Switch credential");
      expect(initial).not.toContain("Skip for now");

      await session.sendKeys("Escape");
      const skipped = await session.waitForPane(
        (pane) => !pane.includes("Welcome to fx") && !pane.includes("Sign in with Vercel"),
        TIMEOUT,
      );
      expect(skipped).not.toContain("Add an API key");

      await session.kill();
      session = await TmuxSession.create({ env });
      const restarted = await session.waitForText("Welcome to fx", TIMEOUT);
      expect(restarted).toContain("Sign in with Vercel");
      expect(restarted).toContain("Add an API key");
    },
    60_000,
  );
});
