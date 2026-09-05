import { afterEach, expect, test } from "bun:test";
import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";

const TIMEOUT = 30_000;
const ACCOUNT_ID = "acct_broker_e2e";
const MAX_FRAME_BYTES = 64 * 1024;

function chatGptAccessToken(signature: string, accountId = ACCOUNT_ID): string {
  const payload = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: accountId },
  })).toString("base64url");
  return `header.${payload}.${signature}`;
}

function seedChatGptLogin(home: string, accessToken: string, accountId = ACCOUNT_ID): void {
  const fxDir = join(home, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, "chatgpt-auth.json");
  writeFileSync(
    authPath,
    JSON.stringify({
      version: 1,
      access_token: accessToken,
      refresh_token: "chatgpt-refresh-seed",
      expires_at_ms: Date.now() + 60 * 60 * 1000,
      account_id: accountId,
    }) + "\n",
    { mode: 0o600 },
  );
  chmodSync(authPath, 0o600);
  const settingsPath = join(fxDir, "settings.json");
  writeFileSync(
    settingsPath,
    JSON.stringify({ provider: "codex", codex_model: "gpt-5.6-sol" }) + "\n",
    { mode: 0o600 },
  );
  chmodSync(settingsPath, 0o600);
}

function startFakeChatGptToken(accountId = ACCOUNT_ID) {
  let rotations = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      await request.text();
      rotations += 1;
      return Response.json({
        access_token: chatGptAccessToken(`rotated-${rotations}`, accountId),
        refresh_token: `chatgpt-refresh-${rotations}`,
        expires_in: 3600,
      });
    },
  });
  return {
    url: `http://127.0.0.1:${server.port}/token`,
    get rotations() {
      return rotations;
    },
    stop: () => server.stop(true),
  };
}

/// One connected local stream socket: the consumer keeps the client end, and
/// the inherited server end is handed to fx as descriptor 3.
async function openInheritedChannel(dir: string) {
  const path = join(dir, "broker.sock");
  let accepted: net.Socket | null = null;
  const server = net.createServer();
  const acceptedReady = new Promise<net.Socket>((resolve) => {
    server.once("connection", (socket) => {
      accepted = socket;
      resolve(socket);
    });
  });
  await new Promise<void>((resolve) => server.listen(path, () => resolve()));
  const consumer = net.connect(path);
  await new Promise<void>((resolve, reject) => {
    consumer.once("connect", () => resolve());
    consumer.once("error", reject);
  });
  const fxEnd = await acceptedReady;
  server.close();
  const fxFd = (fxEnd as unknown as { _handle?: { fd?: number } })._handle?.fd;
  if (typeof fxFd !== "number") throw new Error("no inherited descriptor");
  return {
    consumer,
    fxFd,
    /// The parent must let go of fx's end once the child has it. Both
    /// descriptors share one open file description, so a parent that keeps
    /// reading would steal the consumer's own request bytes.
    releaseFxEnd: () => {
      try {
        accepted?.destroy();
      } catch {}
    },
    close: () => {
      try {
        consumer.destroy();
      } catch {}
      try {
        accepted?.destroy();
      } catch {}
    },
  };
}

class FrameReader {
  private buffer = Buffer.alloc(0);
  private frames: Buffer[] = [];
  private waiters: Array<(frame: Buffer) => void> = [];

  constructor(socket: net.Socket) {
    socket.on("data", (chunk: Buffer) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      while (this.buffer.length >= 4) {
        const length = this.buffer.readUInt32BE(0);
        if (length === 0 || length > MAX_FRAME_BYTES) {
          throw new Error(`invalid frame length ${length}`);
        }
        if (this.buffer.length < 4 + length) break;
        const frame = this.buffer.subarray(4, 4 + length);
        this.buffer = this.buffer.subarray(4 + length);
        const waiter = this.waiters.shift();
        if (waiter) {
          waiter(frame);
        } else {
          this.frames.push(frame);
        }
      }
    });
  }

  next(timeoutMs = 10_000, label = "frame"): Promise<Record<string, any>> {
    const queued = this.frames.shift();
    if (queued) return Promise.resolve(JSON.parse(queued.toString("utf8")));
    return new Promise((resolve, reject) => {
      let deliver: (frame: Buffer) => void;
      const timer = setTimeout(() => {
        const index = this.waiters.indexOf(deliver);
        if (index >= 0) this.waiters.splice(index, 1);
        reject(new Error(`${label} timeout`));
      }, timeoutMs);
      deliver = (frame) => {
        clearTimeout(timer);
        resolve(JSON.parse(frame.toString("utf8")));
      };
      this.waiters.push(deliver);
    });
  }
}

function writeFrame(socket: net.Socket, value: unknown): void {
  const payload = Buffer.from(JSON.stringify(value), "utf8");
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(payload.length, 0);
  socket.write(Buffer.concat([prefix, payload]));
}

const cleanups: Array<() => void> = [];

afterEach(() => {
  while (cleanups.length > 0) cleanups.pop()!();
});

function trackProcess(proc: ChildProcess): void {
  cleanups.push(() => {
    try {
      proc.kill("SIGKILL");
    } catch {}
  });
}

function makeHome(): string {
  const home = mkdtempSync(join(tmpdir(), "fx-broker-home-"));
  cleanups.push(() => rmSync(home, { recursive: true, force: true }));
  return home;
}

/// A small empty workspace. The broker is process authority, not project
/// state, and an unrelated repository only adds startup work to the run.
function makeWorkspace(): string {
  const workspace = mkdtempSync(join(tmpdir(), "fx-broker-workspace-"));
  cleanups.push(() => rmSync(workspace, { recursive: true, force: true }));
  return workspace;
}

function brokerEnv(home: string, tokenUrl: string): Record<string, string> {
  return {
    ...process.env,
    HOME: home,
    NO_COLOR: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SKIP_ONBOARDING: "1",
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_E2E_CHATGPT_TOKEN_URL: tokenUrl,
    AI_GATEWAY_API_KEY: "",
    OPENAI_API_KEY: "",
    VERCEL_OIDC_TOKEN: "",
  } as Record<string, string>;
}

test("a child holding fd 3 leases Codex authority and rotates one generation", async () => {
  const home = makeHome();
  const workspace = makeWorkspace();
  const seeded = chatGptAccessToken("seeded");
  seedChatGptLogin(home, seeded);
  const token = startFakeChatGptToken();
  cleanups.push(() => token.stop());

  const channel = await openInheritedChannel(home);
  cleanups.push(() => channel.close());
  const frames = new FrameReader(channel.consumer);

  const fx = nodeSpawn(FX_BIN, ["--codex-credential-fd", "3", "acp"], {
    cwd: workspace,
    env: brokerEnv(home, token.url),
    stdio: ["pipe", "pipe", "pipe", channel.fxFd],
  });
  trackProcess(fx);
  await new Promise<void>((resolve) => fx.once("spawn", () => resolve()));
  channel.releaseFxEnd();
  let stderr = "";
  fx.stderr!.on("data", (chunk: Buffer) => {
    stderr += chunk.toString();
  });

  // The hello frame carries the instance nonce and arrives before fx has
  // answered a single ACP request, so the broker is live before Fx starts.
  const hello = await frames.next();
  expect(stderr).toBe("");
  expect(hello.schema).toBe(1);
  const nonce = hello.hello.nonce as string;
  expect(nonce).toMatch(/^[0-9a-f]{48}$/);

  const resolved = await (async () => {
    writeFrame(channel.consumer, {
      schema: 1,
      request_id: "1",
      nonce,
      method: "codex.credential.resolve",
      params: { minimum_validity_seconds: 60 },
    });
    return frames.next();
  })();
  expect(resolved.ok).toBe(true);
  expect(resolved.request_id).toBe("1");
  expect(Object.keys(resolved.result).sort()).toEqual([
    "access_token",
    "account_id",
    "generation",
    "refresh_deadline",
  ]);
  expect(resolved.result.account_id).toBe(ACCOUNT_ID);
  expect(resolved.result.access_token).toBe(seeded);
  expect(resolved.result.generation).toBe(1);
  expect(resolved.result.refresh_deadline).toBeGreaterThan(Math.floor(Date.now() / 1000));
  expect(token.rotations).toBe(0);

  writeFrame(channel.consumer, {
    schema: 1,
    request_id: "2",
    nonce,
    method: "codex.credential.refresh",
    params: { account_id: ACCOUNT_ID, prior_generation: 1 },
  });
  const rotated = await frames.next();
  expect(rotated.ok).toBe(true);
  expect(rotated.result.generation).toBe(2);
  expect(rotated.result.access_token).toBe(chatGptAccessToken("rotated-1"));
  expect(rotated.result.account_id).toBe(ACCOUNT_ID);
  expect(token.rotations).toBe(1);

  // The same prior generation is now stale. It receives the already newer
  // lease unchanged rather than rotating the account a second time.
  writeFrame(channel.consumer, {
    schema: 1,
    request_id: "3",
    nonce,
    method: "codex.credential.refresh",
    params: { account_id: ACCOUNT_ID, prior_generation: 1 },
  });
  const stale = await frames.next();
  expect(stale.ok).toBe(true);
  expect(stale.result.generation).toBe(2);
  expect(stale.result.access_token).toBe(rotated.result.access_token);
  expect(token.rotations).toBe(1);

  writeFrame(channel.consumer, {
    schema: 1,
    request_id: "4",
    nonce,
    method: "codex.credential.refresh",
    params: { account_id: ACCOUNT_ID, prior_generation: 9 },
  });
  const future = await frames.next();
  expect(future.ok).toBe(false);
  expect(future.error.code).toBe("future_generation");
  expect(token.rotations).toBe(1);

  // A request that echoes the wrong nonce is refused once and ends the
  // channel: an unproven peer never gets a second attempt.
  writeFrame(channel.consumer, {
    schema: 1,
    request_id: "5",
    nonce: "f".repeat(48),
    method: "codex.credential.resolve",
    params: { minimum_validity_seconds: 60 },
  });
  const refused = await frames.next();
  expect(refused.ok).toBe(false);
  expect(refused.error.code).toBe("unauthorized");
  await new Promise<void>((resolve) => {
    if (channel.consumer.readableEnded) return resolve();
    channel.consumer.once("end", () => resolve());
    channel.consumer.once("close", () => resolve());
  });
  expect(stderr).toBe("");
}, TIMEOUT);

test("a borrowed credential fails the credential channel closed before start", async () => {
  const home = makeHome();
  const workspace = makeWorkspace();
  seedChatGptLogin(home, chatGptAccessToken("seeded"));
  const token = startFakeChatGptToken();
  cleanups.push(() => token.stop());
  const borrowed = makeHome();

  const channel = await openInheritedChannel(home);
  cleanups.push(() => channel.close());
  const frames = new FrameReader(channel.consumer);

  const fx = nodeSpawn(FX_BIN, ["--state-dir", home, "--codex-credential-fd", "3", "acp"], {
    cwd: workspace,
    env: { ...brokerEnv(home, token.url), FX_AUTH_READ_ONLY_HOME: borrowed },
    stdio: ["pipe", "pipe", "pipe", channel.fxFd],
  });
  trackProcess(fx);
  await new Promise<void>((resolve) => fx.once("spawn", () => resolve()));
  channel.releaseFxEnd();
  let stderr = "";
  fx.stderr!.on("data", (chunk: Buffer) => {
    stderr += chunk.toString();
  });

  const exitCode = await new Promise<number>((resolve) => {
    fx.on("close", (code) => resolve(code ?? -1));
  });
  expect(exitCode).not.toBe(0);
  expect(stderr).not.toBe("");
  await expect(frames.next(500)).rejects.toThrow("frame timeout");
}, TIMEOUT);

test("an explicit identity borrow fails the credential channel closed before start", async () => {
  const home = makeHome();
  const identity = makeHome();
  const workspace = makeWorkspace();
  seedChatGptLogin(home, chatGptAccessToken("ambient"));
  seedChatGptLogin(identity, chatGptAccessToken("borrowed"));
  const token = startFakeChatGptToken();
  cleanups.push(() => token.stop());

  const channel = await openInheritedChannel(home);
  cleanups.push(() => channel.close());
  const frames = new FrameReader(channel.consumer);

  const fx = nodeSpawn(
    FX_BIN,
    ["--identity", identity, "--codex-credential-fd", "3", "acp"],
    {
      cwd: workspace,
      env: brokerEnv(home, token.url),
      stdio: ["pipe", "pipe", "pipe", channel.fxFd],
    },
  );
  trackProcess(fx);
  await new Promise<void>((resolve) => fx.once("spawn", () => resolve()));
  channel.releaseFxEnd();
  let stderr = "";
  fx.stderr!.on("data", (chunk: Buffer) => {
    stderr += chunk.toString();
  });

  const exitCode = await new Promise<number>((resolve) => {
    fx.on("close", (code) => resolve(code ?? -1));
  });
  expect(exitCode).not.toBe(0);
  expect(stderr).toContain("cannot lease a borrowed read-only credential");
  await expect(frames.next(500)).rejects.toThrow("frame timeout");
}, TIMEOUT);

test("a selected state profile owns every credential broker lease and refresh", async () => {
  const ambientHome = makeHome();
  const stateHome = makeHome();
  const workspace = makeWorkspace();
  const ambientAccount = "acct_broker_ambient";
  const stateAccount = "acct_broker_state";
  const ambientToken = chatGptAccessToken("ambient-seed", ambientAccount);
  const stateToken = chatGptAccessToken("state-seed", stateAccount);
  seedChatGptLogin(ambientHome, ambientToken, ambientAccount);
  seedChatGptLogin(stateHome, stateToken, stateAccount);
  const token = startFakeChatGptToken(stateAccount);
  cleanups.push(() => token.stop());

  const channel = await openInheritedChannel(stateHome);
  cleanups.push(() => channel.close());
  const frames = new FrameReader(channel.consumer);
  const fx = nodeSpawn(
    FX_BIN,
    ["--state-dir", stateHome, "--codex-credential-fd", "3", "acp"],
    {
      cwd: workspace,
      env: brokerEnv(ambientHome, token.url),
      stdio: ["pipe", "pipe", "pipe", channel.fxFd],
    },
  );
  trackProcess(fx);
  await new Promise<void>((resolve) => fx.once("spawn", () => resolve()));
  channel.releaseFxEnd();
  let stderr = "";
  fx.stderr!.on("data", (chunk: Buffer) => {
    stderr += chunk.toString();
  });

  const hello = await frames.next(10_000, "selected-state hello");
  const nonce = hello.hello.nonce as string;
  writeFrame(channel.consumer, {
    schema: 1,
    request_id: "1",
    nonce,
    method: "codex.credential.resolve",
    params: { minimum_validity_seconds: 60 },
  });
  const resolved = await frames.next(10_000, "selected-state resolve");
  expect(resolved.ok).toBe(true);
  expect(resolved.result.account_id).toBe(stateAccount);
  expect(resolved.result.access_token).toBe(stateToken);

  writeFrame(channel.consumer, {
    schema: 1,
    request_id: "2",
    nonce,
    method: "codex.credential.refresh",
    params: { account_id: stateAccount, prior_generation: 1 },
  });
  const refreshed = await frames.next(10_000, "selected-state refresh");
  expect(refreshed.ok).toBe(true);
  expect(refreshed.result.account_id).toBe(stateAccount);
  expect(refreshed.result.access_token).toBe(chatGptAccessToken("rotated-1", stateAccount));
  expect(token.rotations).toBe(1);
  expect(stderr).toBe("");

  const ambientAuth = JSON.parse(
    readFileSync(join(ambientHome, ".fx", "chatgpt-auth.json"), "utf8"),
  );
  const stateAuth = JSON.parse(
    readFileSync(join(stateHome, ".fx", "chatgpt-auth.json"), "utf8"),
  );
  expect(ambientAuth.access_token).toBe(ambientToken);
  expect(ambientAuth.account_id).toBe(ambientAccount);
  expect(stateAuth.access_token).toBe(refreshed.result.access_token);
  expect(stateAuth.account_id).toBe(stateAccount);
}, TIMEOUT);
