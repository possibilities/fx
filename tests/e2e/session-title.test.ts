import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const MAIN_MODEL = "openai/gpt-5.5";
const TITLE_MODEL = "openai/gpt-5.6-luna";
const GENERATED_TITLE = "renderer-loop-refactor";

type FixtureRoot = {
  root: string;
  home: string;
  workspace: string;
};

function createFixtureRoot(label: string, settings: string = "{}"): FixtureRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-session-title-${label}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), settings);
  return { root, home, workspace: realpathSync(workspace) };
}

function startTitleAwareGateway(title = GENERATED_TITLE) {
  const namingRequests: string[] = [];
  const gateway = startDynamicFakeGateway(raw => {
    if (raw.includes("Generate a short session title")) {
      namingRequests.push(raw);
      return fakeGatewayFinalText(title);
    }
    return fakeGatewayFinalText("MAIN_ANSWER_OK");
  }, {
    models: [MAIN_MODEL, TITLE_MODEL].map(id => ({ id, type: "language", tags: ["tool-use"] })),
    titleResponses: [fakeGatewayFinalText(title)],
  });
  return { ...gateway, namingRequests };
}

function baseEnv(root: FixtureRoot, gateway: { baseUrl: string; chatUrl: string }) {
  return {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: root.home,
    AI_GATEWAY_API_KEY: "synthetic-title",
    FX_DISABLE_KEYCHAIN: "1",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_SKIP_ONBOARDING: "1",
    FX_MODEL: MAIN_MODEL,
    FX_PERMISSION_MODE: "full-access",
    FX_MAX_AGENT_STEPS: "2",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
}

function sessionTitles(root: FixtureRoot): string[] {
  const sessionsDir = join(root.home, ".fx", "sessions");
  if (!existsSync(sessionsDir)) return [];
  const titles: string[] = [];
  for (const id of readdirSync(sessionsDir)) {
    const manifest = join(sessionsDir, id, "session.json");
    if (!existsSync(manifest)) continue;
    const value = JSON.parse(readFileSync(manifest, "utf8"));
    if (typeof value.title === "string") titles.push(value.title);
  }
  return titles;
}

function titleRequests(gateway: ReturnType<typeof startTitleAwareGateway>) {
  return [...gateway.titleRequests, ...gateway.namingRequests];
}

test("fx ask retains its derived title without a naming request", async () => {
  const root = createFixtureRoot("ask");
  const gateway = startTitleAwareGateway();
  try {
    const result = await runFx(["ask", "refactor the renderer loop to fix the crash"], {
      cwd: root.workspace,
      env: baseEnv(root, gateway),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("MAIN_ANSWER_OK");

    const titleCalls = titleRequests(gateway);
    expect(titleCalls.length).toBe(0);
    expect(sessionTitles(root)).not.toContain(GENERATED_TITLE);

    const list = await runFx(["sessions", "--json"], {
      cwd: root.workspace,
      env: baseEnv(root, gateway),
      timeoutMs: 15_000,
    });
    expect(list.code).toBe(0);
    expect(list.stdout).not.toContain(GENERATED_TITLE);
  } finally {
    gateway.stop();
  }
});

test("fx ask keeps the derived title when session_titles is off", async () => {
  const root = createFixtureRoot("disabled", JSON.stringify({ session_titles: false }));
  const gateway = startTitleAwareGateway();
  try {
    const result = await runFx(["ask", "refactor the renderer loop to fix the crash"], {
      cwd: root.workspace,
      env: baseEnv(root, gateway),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("MAIN_ANSWER_OK");
    expect(titleRequests(gateway).length).toBe(0);
    expect(sessionTitles(root)).not.toContain(GENERATED_TITLE);
  } finally {
    gateway.stop();
  }
});

test("fx ask never admits a title request even when a title provider is available", async () => {
  const root = createFixtureRoot("unusable");
  const gateway = startTitleAwareGateway("\n  \n");
  try {
    const result = await runFx(["ask", "refactor the renderer loop to fix the crash"], {
      cwd: root.workspace,
      env: baseEnv(root, gateway),
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("MAIN_ANSWER_OK");
    expect(titleRequests(gateway).length).toBe(0);
    const titles = sessionTitles(root);
    expect(titles.length).toBe(1);
    expect(titles[0]).not.toBe(GENERATED_TITLE);
    expect(titles[0].length).toBeGreaterThan(0);
  } finally {
    gateway.stop();
  }
});

const SKIP_TMUX = !tmuxAvailable();

function traceTmpDir(root: FixtureRoot): string {
  const dir = join(root.root, "tmp");
  mkdirSync(dir, { recursive: true });
  return dir;
}

function traceReports(root: FixtureRoot): string[] {
  return readdirSync(traceTmpDir(root))
    .filter(name => name.startsWith("fx-trace-") && name.endsWith(".md"))
    .sort();
}

async function captureTraceReport(tui: TmuxSession, root: FixtureRoot): Promise<string> {
  const before = new Set(traceReports(root));
  await tui.sendText("/trace");
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const fresh = traceReports(root).filter(name => !before.has(name));
    if (fresh.length > 0) {
      // The filename becomes visible between create and the content write, so
      // wait for the report's closing section before reading.
      const path = join(traceTmpDir(root), fresh[fresh.length - 1]);
      const content = readFileSync(path, "utf8");
      if (content.includes("## Transcript Timeline")) return content;
    }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error("trace report was not written");
}

test.skipIf(SKIP_TMUX)("tui trace report shows an installed session title", async () => {
  const root = createFixtureRoot("tui-trace", JSON.stringify({ statusLine: { session: true }, session_naming: { gateway: { model: TITLE_MODEL } } }));
  const gateway = startTitleAwareGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await TmuxSession.create({
      cmd: JSON.stringify(FX_BIN),
      cwd: root.workspace,
      isolated: true,
      remainOnExit: true,
      env: { ...baseEnv(root, gateway), TMPDIR: traceTmpDir(root) },
    });
    await tui.waitForStableComposer(15000);
    await tui.sendText("refactor the renderer loop to fix the crash");
    await tui.waitForText("MAIN_ANSWER_OK", 20000);
    await tui.waitForText(GENERATED_TITLE, 15000);

    const report = await captureTraceReport(tui, root);
    expect(report).toContain("## Session Title");
    expect(report).toContain("setting: true");
    expect(report).toContain(`title: ${GENERATED_TITLE}`);
    expect(report).toContain("generation: engine=session_naming pending=0 attempted=1");
    expect(titleRequests(gateway).length).toBe(1);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 60_000);

test.skipIf(SKIP_TMUX)("tui trace report explains why no session title was generated", async () => {
  const root = createFixtureRoot("tui-trace-failed", JSON.stringify({ session_naming: { gateway: { model: TITLE_MODEL } } }));
  const gateway = startTitleAwareGateway("\n  \n");
  let tui: TmuxSession | undefined;
  try {
    tui = await TmuxSession.create({
      cmd: JSON.stringify(FX_BIN),
      cwd: root.workspace,
      isolated: true,
      remainOnExit: true,
      env: { ...baseEnv(root, gateway), TMPDIR: traceTmpDir(root) },
    });
    await tui.waitForStableComposer(15000);
    await tui.sendText("refactor the renderer loop to fix the crash");
    await tui.waitForText("MAIN_ANSWER_OK", 20000);

    // The title task finishes right after the fake gateway responds, but there
    // is no visible signal for a failed title, so retry while it is running.
    const deadline = Date.now() + 20_000;
    let report = "";
    while (Date.now() < deadline) {
      report = await captureTraceReport(tui, root);
      if (report.includes("generation: engine=session_naming pending=0")) break;
      await new Promise(resolve => setTimeout(resolve, 250));
    }
    expect(report).toContain("## Session Title");
    expect(report).toContain("generation: engine=session_naming pending=0 attempted=1");
    expect(titleRequests(gateway).length).toBe(2);
    expect(sessionTitles(root)).not.toContain(GENERATED_TITLE);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 60_000);

test.skipIf(SKIP_TMUX)("tui shows the generated session title", async () => {
  const root = createFixtureRoot("tui", JSON.stringify({ statusLine: { session: true }, session_naming: { gateway: { model: TITLE_MODEL } } }));
  const gateway = startTitleAwareGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await TmuxSession.create({
      cmd: JSON.stringify(FX_BIN),
      cwd: root.workspace,
      isolated: true,
      remainOnExit: true,
      env: baseEnv(root, gateway),
    });
    await tui.waitForStableComposer(15000);
    await tui.sendText("refactor the renderer loop to fix the crash");
    await tui.waitForText("MAIN_ANSWER_OK", 20000);
    await tui.waitForText(GENERATED_TITLE, 15000);
    expect(sessionTitles(root)).toContain(GENERATED_TITLE);
    expect(titleRequests(gateway).length).toBe(1);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 60_000);

test.skipIf(SKIP_TMUX)("manual rename wins over an in-flight naming request and later prompts", async () => {
  const root = createFixtureRoot("manual-rename", JSON.stringify({
    session_naming: { gateway: { model: TITLE_MODEL }, timeout_ms: 10_000 },
  }));
  const started = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  let namingCalls = 0;
  let mainCalls = 0;
  const gateway = startDynamicFakeGateway(async raw => {
    if (raw.includes("Generate a short session title")) {
      namingCalls += 1;
      started.resolve();
      await release.promise;
      return fakeGatewayFinalText("Obsolete Generated Title");
    }
    mainCalls += 1;
    return fakeGatewayFinalText(mainCalls === 1 ? "FIRST_MAIN_ANSWER" : "SECOND_MAIN_ANSWER");
  }, { models: [MAIN_MODEL, TITLE_MODEL].map(id => ({ id, type: "language", tags: ["tool-use"] })) });
  let tui: TmuxSession | undefined;
  try {
    tui = await TmuxSession.create({
      cmd: JSON.stringify(FX_BIN), cwd: root.workspace, isolated: true,
      remainOnExit: true, env: baseEnv(root, gateway),
    });
    await tui.waitForStableComposer(15_000);
    await tui.sendText("prepare a bounded naming request");
    await tui.waitForText("FIRST_MAIN_ANSWER", 15_000);
    await Promise.race([started.promise, Bun.sleep(10_000).then(() => { throw new Error("naming was not admitted"); })]);
    await tui.sendText("/rename Manual Title");
    for (let n = 0; n < 100 && !sessionTitles(root).includes("Manual Title"); n += 1) await Bun.sleep(25);
    expect(sessionTitles(root)).toContain("Manual Title");
    release.resolve();
    await tui.sendText("continue the same session");
    await tui.waitForText("SECOND_MAIN_ANSWER", 15_000);
    expect(sessionTitles(root)).toContain("Manual Title");
    expect(sessionTitles(root)).not.toContain("obsolete-generated-title");
    expect(namingCalls).toBe(1);
  } finally {
    release.resolve();
    await tui?.kill();
    gateway.stop();
  }
}, 45_000);
