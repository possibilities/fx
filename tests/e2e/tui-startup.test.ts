import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
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
