import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
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
import { FX_BIN, HAS_API_KEY, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  hasEmptyComposer,
  startFakeGateway,
  startDynamicFakeGateway,
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
      expect(pane).toContain("tab category");
      expect(pane).toContain("enter open");
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
          "shell",
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

        const initial = await session.waitForPane(
          (pane) => pane.includes("status-root") && pane.includes("initial-branch"),
          10_000,
        );
        expect(initial).not.toContain("⚡︎");

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
          (pane) => pane.includes("s-root") && pane.includes("detached"),
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

  test(
    "/new preserves the visible transcript in terminal scrollback",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-new-scrollback-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
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
            FX_RECORD: tapePath,
            FX_RECORD_INPUT: "1",
            FX_DEBUG_RECORD_SILENT_BANNER: "1",
          },
          stderrPath,
          width: 80,
          height: 18,
        });
        await session.waitForComposer(10_000);
        for (let i = 0; i < 8; i++) {
          await session.sendText("/status");
          await session.waitForComposer(5_000);
        }
        const before = await session.captureFullScrollback();
        const lastStatus = before.slice(before.lastIndexOf("* status:"));
        expect(lastStatus).toContain("agent_step_limit=0");

        await session.sendText("/new");
        await session.waitForPane(
          (pane) => pane.includes(banner) && !pane.includes("model=") && hasEmptyComposer(pane),
          5_000,
        );
        const after = await session.captureFullScrollback();
        const priorStatus = after.slice(after.lastIndexOf("* status:"), after.lastIndexOf(banner)).trimEnd();
        expect(priorStatus).toBe(lastStatus.split("\n┃")[0]?.trimEnd());
        expect(priorStatus).not.toContain("Commands 1");
        expect(priorStatus).not.toContain("run /login ·");
        expect(await session.capturePane()).not.toContain("model=");
        const replay = JSON.parse(execFileSync(FX_BIN, ["replay", tapePath, "--json"], { encoding: "utf8" }));
        expect(replay.frame_count).toBeGreaterThan(0);
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
    "/new keeps a completed reply in scrollback and starts the next prompt fresh",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-new-reply-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home, { recursive: true });
      writeFileSync(stderrPath, "");
      const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText("FIXTURE_REPLY_OK"));
      const version = execFileSync(FX_BIN, ["--version"], { encoding: "utf8" }).trim();
      const banner = `𝒇x v${version} · Run /help for commands`;

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
            AI_GATEWAY_API_KEY: "new-fixture-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
          },
          stderrPath,
          width: 100,
          height: 24,
        });
        await session.waitForComposer(10_000);
        await session.sendText("first fixture prompt");
        await session.waitForText("FIXTURE_REPLY_OK", 10_000);
        await session.sendText("/new");
        await session.waitForPane((pane) => pane.includes(banner) && hasEmptyComposer(pane), 10_000);
        const history = await session.captureFullScrollback();
        expect(history.lastIndexOf("FIXTURE_REPLY_OK")).toBeLessThan(history.lastIndexOf(banner));
        expect(history).toContain("FIXTURE_REPLY_OK");

        await session.sendText("second fixture prompt");
        await session.waitForText("FIXTURE_REPLY_OK", 10_000);
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1].body).toContain("second fixture prompt");
        expect(gateway.requests[1].body).not.toContain("first fixture prompt");
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
    TIMEOUT,
  );

  test(
    "/new waits for a resize before moving the old transcript into scrollback",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-new-resize-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "resize.fxtape");
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
            FX_RECORD: tapePath,
            FX_RECORD_INPUT: "1",
            FX_DEBUG_RECORD_SILENT_BANNER: "1",
          },
          stderrPath,
          width: 80,
          height: 18,
        });
        await session.waitForComposer(10_000);
        await session.sendText("/status");
        await session.waitForPane((pane) => pane.includes("agent_step_limit=0"), 5_000);
        const before = await session.captureFullScrollback();
        const expectedStatus = before.slice(before.lastIndexOf("* status:")).split("\n┃")[0]?.trimEnd();
        expect(expectedStatus).toContain("agent_step_limit=0");
        session.sendLiteralImmediate("/new");
        await session.resizeWindow(78, 18, 0);
        await Bun.sleep(40);
        session.sendKeysImmediate(["Enter"]);

        await session.waitForPane(
          (pane) => pane.includes(banner) && !pane.includes("model=") && hasEmptyComposer(pane),
          10_000,
        );
        const history = await session.captureFullScrollback();
        const oldStatus = history.slice(history.lastIndexOf("* status:"), history.lastIndexOf(banner));
        let lastIndex = -1;
        for (const field of ["* status:", "permission_mode=auto", "workspace=", "history_turns=0", "session_permission_grants=0", "agent_step_limit=0"]) {
          const index = oldStatus.indexOf(field);
          expect(index).toBeGreaterThan(lastIndex);
          lastIndex = index;
        }
        expect(oldStatus.replace(/\s+/g, "")).toBe(expectedStatus?.replace(/\s+/g, ""));
        expect(oldStatus).not.toContain("Commands 1");
        expect(oldStatus).not.toContain("run /login ·");
        expect(session.isAlive()).toBe(true);
        await session.sendText("/status");
        await session.waitForPane((pane) => pane.includes("agent_step_limit=0") && hasEmptyComposer(pane), 5_000);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        const replay = JSON.parse(execFileSync(FX_BIN, ["replay", tapePath, "--json"], { encoding: "utf8" }));
        expect(replay.frame_count).toBeGreaterThan(0);
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
    "/quit exits after a fresh-session handoff times out at an invalid terminal size",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-new-invalid-size-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      mkdirSync(home, { recursive: true });
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: { HOME: home, FX_AUTO_UPGRADE: "0", FX_TRACE_LOG: tracePath },
          stderrPath,
          width: 80,
          height: 18,
        });
        await session.waitForComposer(10_000);
        await session.sendText("/status");
        await session.waitForText("agent_step_limit=0", 5_000);
        session.sendLiteralImmediate("/new");
        await session.resizeWindow(78, 3, 0);
        session.sendKeysImmediate(["Enter"]);

        let trace = "";
        for (let attempt = 0; attempt < 100; attempt++) {
          trace = readFileSync(tracePath, "utf8");
          if (trace.includes("live_session_transition_deferred")) break;
          await Bun.sleep(25);
        }
        expect(trace).toContain("live_session_transition_deferred");
        session.sendLiteralImmediate("/quit");
        session.sendKeysImmediate(["Enter"]);
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        expect(readFileSync(tracePath, "utf8")).toContain("live_session_transition_cancelled reason=resize_timeout");
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
        fakeGatewayToolCall("state_home", "shell", {
          request: {
            action: "run",
            command: "printf '%s' \"$HOME\"",
            timeout_ms: 5_000,
          },
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

        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[0]!.headers.get("ai-language-model-id")).toBe(
          FAKE_GATEWAY_MODEL,
        );
        expect(gateway.requests[0]!.headers.get("authorization")).toBe(
          "Bearer selected-state-key",
        );
        expect(gateway.requests[0]!.body).toContain("SELECTED_PROFILE_SKILL_BODY");
        expect(gateway.requests[0]!.body).toContain("isolated-state-skill");
        expect(gateway.requests[0]!.body).toContain("SELECTED_PROFILE_INSTRUCTIONS");
        expect(gateway.requests[0]!.body).not.toContain("ambient-state-skill");
        expect(gateway.requests[0]!.body).not.toContain("ambient-profile-skill");
        expect(gateway.requests[0]!.body).not.toContain("AMBIENT_PROFILE_INSTRUCTIONS");
        expect(gateway.requests[1]!.body).toContain(home);
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

  test.each([false, true])(
    "TUI resume cannot cross selected state roots (sessions v2: %s)",
    async (sessionsV2) => {
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
      const gateway = startFakeGateway([
        fakeGatewayFinalText("selected state seed"),
        fakeGatewayFinalText("other state seed"),
        fakeGatewayFinalText("ambient state seed"),
      ]);
      const env = {
        HOME: home,
        AI_GATEWAY_API_KEY: "state-resume-test-key",
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_SESSIONS_V2: sessionsV2 ? "1" : undefined,
        FX_AUTO_UPGRADE: "0",
      };
      try {
        const sessionIds: string[] = [];
        for (const selectedHome of [stateA, stateB, home]) {
          const seeded = await runFx(["ask", "--json", "Persist a resume-boundary fixture."], {
            cwd: workspace,
            env: { ...env, HOME: selectedHome },
            timeoutMs: TIMEOUT,
          });
          expect(seeded.code).toBe(0);
          sessionIds.push(JSON.parse(seeded.stdout).session_id);
        }
        const [selectedSessionId, otherSessionId, ambientSessionId] = sessionIds;
        session = await TmuxSession.create({
          cmd: `${shellQuote(FX_BIN)} --state-dir ${shellQuote(stateA)} resume ${shellQuote(selectedSessionId!)}`,
          cwd: workspace,
          env,
          stderrPath: validStderr,
        });
        await session.waitForComposer(10_000);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        session = null;
        expect(readFileSync(validStderr, "utf8")).toBe("");

        for (const deniedSessionId of [otherSessionId, ambientSessionId]) {
          session = await TmuxSession.create({
            cmd: `${shellQuote(FX_BIN)} --state-dir ${shellQuote(stateA)} resume ${shellQuote(deniedSessionId!)}`,
            cwd: workspace,
            env,
            stderrPath: invalidStderr,
            startupWaitMs: 100,
          });
          expect(await session.waitForSessionEnd(5_000)).toBe(true);
          session = null;
          expect(readFileSync(invalidStderr, "utf8")).toContain(
            "saved session not found",
          );
        }
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        gateway.stop();
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
          if (body.includes('"method":"initialize"')) discoveryRequests += 1;
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
        const beforeListMenu = await session.captureFullScrollback();
        await session.sendText("/mcp list");
        const listMenu = await session.waitForText("[Servers]", 5_000);
        expect(listMenu).toContain("pending");
        expect(listMenu).toContain("Connecting");
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes("[Servers]"), 5_000);
        expect(await session.captureFullScrollback()).toBe(beforeListMenu);

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
    "/setup opens the inline provider picker columns",
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
      const picker = await session.waitForPane(
        (pane) =>
          pane.includes("/provider") &&
          pane.includes("vercel") &&
          pane.includes("codex") &&
          pane.includes("grok"),
        TIMEOUT,
      );
      expect(picker).not.toContain("Connections");
      expect(picker).not.toContain("Credential source");

      await session.sendKeys("Enter");
      await session.waitForPane(
        (pane) => pane.includes("oauth") && pane.includes("api-key"),
        TIMEOUT,
      );

      // No key exists anywhere in this environment, so the api-key leaf skips
      // the which-key column and opens the paste field directly.
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await session.waitForText("Paste or type a key", TIMEOUT);

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
      expect(initial).toContain("esc to set up later");
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

describe.skipIf(SKIP_TMUX)("tui: custom themes", () => {
  async function startThemedSession(
    root: string,
    themeFiles: Record<string, unknown>,
    options: { fxTheme?: string; settingsTheme?: string; colorFgBg: string },
  ): Promise<{ pane: string; escapes: string; stderrPath: string }> {
    const home = join(root, "home");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(join(home, ".fx", "themes"), { recursive: true });
    for (const [file, contents] of Object.entries(themeFiles)) {
      writeFileSync(join(home, ".fx", "themes", file), JSON.stringify(contents));
    }
    if (options.settingsTheme) {
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ theme: options.settingsTheme }),
      );
    }
    writeFileSync(stderrPath, "");

    session = await TmuxSession.create({
      cwd: root,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_THEME: options.fxTheme,
        COLORFGBG: options.colorFgBg,
        COLORTERM: undefined,
        TERM_PROGRAM: "Apple_Terminal",
      },
      stderrPath,
      width: 100,
      height: 30,
    });
    const pane = await session.waitForComposer(10_000);
    const escapes = await session.capturePaneEscapes();
    return { pane, escapes, stderrPath };
  }

  test(
    "FX_THEME loads a VS Code theme file from ~/.fx/themes",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx", "themes"), { recursive: true });
      writeFileSync(
        join(home, ".fx", "themes", "e2e-accent.json"),
        JSON.stringify({
          name: "E2E Accent",
          colors: { "editor.foreground": "#FF0000" },
        }),
      );
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_THEME: "e2e-accent",
            COLORFGBG: "15;0",
            COLORTERM: undefined,
            TERM_PROGRAM: "Apple_Terminal",
          },
          stderrPath,
          width: 100,
          height: 30,
        });

        const pane = await session.waitForComposer(10_000);
        expect(pane).toContain("Run /help for commands");
        const escapes = await session.capturePaneEscapes();
        // editor.foreground #FF0000 quantizes to xterm-256 color 196 without
        // truecolor (Apple_Terminal), and themes the hint text at startup.
        expect(escapes).toContain("38;5;196");
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
    "pinned theme swaps to its sibling variant on a mismatched terminal",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-swap-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-pair-dark.json": { name: "Pair Dark", type: "dark", colors: { hint: "#0000FF" } },
            "e2e-pair-light.json": { name: "Pair Light", type: "light", colors: { hint: "#00FF00" } },
          },
          { fxTheme: "e2e-pair-dark", colorFgBg: "0;15" }, // light terminal
        );
        expect(pane).toContain("Run /help for commands");
        // The light sibling's hint (#00FF00 -> xterm-256 46) applies, not the
        // pinned dark theme's (#0000FF -> 21).
        expect(escapes).toContain("38;5;46");
        expect(escapes).not.toContain("38;5;21");
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
    "pinned theme falls back to the builtin variant when no sibling exists",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-fallback-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-pair-dark.json": { name: "Pair Dark", type: "dark", colors: { hint: "#0000FF" } },
          },
          { fxTheme: "e2e-pair-dark", colorFgBg: "0;15" }, // light terminal, no e2e-pair-light.json on disk
        );
        expect(pane).toContain("Run /help for commands");
        // Builtin fx-light hint, not the mismatched dark theme's blue.
        expect(escapes).toContain("38;5;235");
        expect(escapes).not.toContain("38;5;21");
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
    "a sibling whose declared variant also mismatches falls back to builtin",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-misdeclared-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-pair-dark.json": { name: "Pair Dark", type: "dark", colors: { hint: "#0000FF" } },
            // Misdeclared: named -light but says dark, with a green marker.
            "e2e-pair-light.json": { name: "Pair Light", type: "dark", colors: { hint: "#00FF00" } },
          },
          { fxTheme: "e2e-pair-dark", colorFgBg: "0;15" }, // light terminal
        );
        expect(pane).toContain("Run /help for commands");
        expect(escapes).toContain("38;5;235");
        expect(escapes).not.toContain("38;5;46");
        expect(escapes).not.toContain("38;5;21");
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
    "settings.json theme applies without FX_THEME",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-settings-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-accent.json": { name: "E2E Accent", type: "dark", colors: { hint: "#FF0000" } },
          },
          { settingsTheme: "e2e-accent", colorFgBg: "15;0" }, // dark terminal, no FX_THEME
        );
        expect(pane).toContain("Run /help for commands");
        // The configured theme's hint (#FF0000 -> xterm-256 196) applies.
        expect(escapes).toContain("38;5;196");
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
    "FX_THEME wins over the settings.json theme",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-precedence-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-accent.json": { name: "E2E Accent", type: "dark", colors: { hint: "#FF0000" } },
          },
          { settingsTheme: "e2e-accent", fxTheme: "dark", colorFgBg: "15;0" },
        );
        expect(pane).toContain("Run /help for commands");
        // Builtin fx-dark hint (255), not the configured theme's red.
        expect(escapes).toContain("38;5;255");
        expect(escapes).not.toContain("38;5;196");
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
    "settings-pinned variant ignores live terminal mode flips",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-pin-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {},
          { settingsTheme: "dark", colorFgBg: "15;0" }, // dark terminal, pinned dark
        );
        expect(pane).toContain("Run /help for commands");
        expect(escapes).toContain("38;5;255"); // fx-dark hint
        expect(escapes).not.toContain("38;5;235"); // fx-light hint

        // The terminal reports a light-mode change mid-session (DEC 997);
        // a pinned variant must not follow it.
        session!.sendKeysImmediate(["-H", "1b", "5b", "3f", "39", "39", "37", "3b", "32", "6e"]);
        await new Promise((resolve) => setTimeout(resolve, 1500));

        const after = await session!.capturePaneEscapes();
        expect(after).toContain("38;5;255");
        expect(after).not.toContain("38;5;235");
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
