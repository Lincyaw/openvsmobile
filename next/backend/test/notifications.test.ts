// Integration tests for the notification system: HTTP POST /notify, RPC
// methods, supersedes chains, GC sweep, multi-device markRead, and the
// `mobile-notify` CLI smoke run.
//
// We spin up the real backend (one HTTP server hosting /rpc + /notify) on
// an OS-assigned port per suite. Storage uses a per-suite temp DB so the
// dev machine's notification history is untouched.

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createServer, type Server } from "node:http";
import { WebSocketServer } from "ws";
import WebSocket from "ws";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";
import { Connection } from "../src/connection.js";
import { ProcessState } from "../src/state.js";
import { handleNotifyHttp } from "../src/notifyHttp.js";
import {
  NotificationStore,
  NotificationHub,
  validateNotificationInput,
} from "../src/notifications.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const CLI_PATH = join(HERE, "..", "bin", "mobile-notify.mjs");
const TOKEN = "test-token-fixed-for-suite";

interface Harness {
  state: ProcessState;
  server: Server;
  port: number;
  tmpDir: string;
  baseUrl: string;
  wsUrl: string;
  shutdown: () => Promise<void>;
}

async function startBackend(): Promise<Harness> {
  const tmpDir = mkdtempSync(join(tmpdir(), "ovsm-notif-"));
  const state = new ProcessState({
    notificationDbPath: join(tmpDir, "notifications.db"),
    disableGcWorker: true,
  });
  const server = createServer((req, res) => {
    if (req.url === "/notify") {
      void handleNotifyHttp(req, res, {
        expectedToken: TOKEN,
        hub: state.notificationHub,
      });
      return;
    }
    res.statusCode = 404;
    res.end();
  });
  const wss = new WebSocketServer({ server, path: "/rpc" });
  wss.on("connection", (ws) => {
    new Connection(ws, {
      expectedToken: TOKEN,
      serverVersion: "0.0.0-test",
      state,
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const addr = server.address();
  if (!addr || typeof addr === "string") throw new Error("no addr");
  const port = addr.port;
  const baseUrl = `http://127.0.0.1:${port}`;
  const wsUrl = `ws://127.0.0.1:${port}/rpc`;
  return {
    state,
    server,
    port,
    tmpDir,
    baseUrl,
    wsUrl,
    shutdown: async () => {
      state.shutdownAll();
      await new Promise<void>((resolve, reject) => {
        wss.close((err) => (err ? reject(err) : resolve()));
      });
      await new Promise<void>((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      });
      rmSync(tmpDir, { recursive: true, force: true });
    },
  };
}

class RpcClient {
  private readonly ws: WebSocket;
  private nextId = 1;
  private readonly pending = new Map<number, { res: (v: unknown) => void; rej: (e: unknown) => void }>();
  public readonly notifs: Array<{ method: string; params: unknown }> = [];
  private notifWaiters: Array<() => void> = [];

  private constructor(ws: WebSocket) {
    this.ws = ws;
  }

  static async connect(url: string): Promise<RpcClient> {
    const ws = new WebSocket(url);
    await new Promise<void>((resolve, reject) => {
      ws.once("open", () => resolve());
      ws.once("error", reject);
    });
    const client = new RpcClient(ws);
    ws.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());
      if (msg.id !== undefined && client.pending.has(msg.id)) {
        const p = client.pending.get(msg.id)!;
        client.pending.delete(msg.id);
        if (msg.error) p.rej(msg.error);
        else p.res(msg.result);
        return;
      }
      if (msg.method !== undefined) {
        client.notifs.push({ method: msg.method, params: msg.params });
        const waiters = client.notifWaiters.splice(0);
        for (const w of waiters) w();
      }
    });
    return client;
  }

  call(method: string, params?: unknown): Promise<unknown> {
    const id = this.nextId++;
    return new Promise((res, rej) => {
      this.pending.set(id, { res, rej });
      this.ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  async waitNotif(method: string, timeoutMs = 2000): Promise<unknown> {
    const deadline = Date.now() + timeoutMs;
    while (true) {
      const idx = this.notifs.findIndex((n) => n.method === method);
      if (idx >= 0) return this.notifs.splice(idx, 1)[0]!.params;
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new Error(`timed out waiting for ${method}`);
      await new Promise<void>((resolve) => {
        const t = setTimeout(resolve, remaining);
        this.notifWaiters.push(() => {
          clearTimeout(t);
          resolve();
        });
      });
    }
  }

  close(): Promise<void> {
    return new Promise((resolve) => {
      this.ws.once("close", () => resolve());
      this.ws.close();
    });
  }
}

async function postNotify(
  baseUrl: string,
  body: unknown,
  opts: { token?: string | null } = {},
): Promise<{ status: number; body: unknown }> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (opts.token !== null) {
    headers.authorization = `Bearer ${opts.token ?? TOKEN}`;
  }
  const res = await fetch(`${baseUrl}/notify`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  let parsed: unknown = null;
  const text = await res.text();
  if (text.length > 0) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = text;
    }
  }
  return { status: res.status, body: parsed };
}

describe("validateNotificationInput (unit)", () => {
  it("rejects missing source", () => {
    expect(() =>
      validateNotificationInput({ level: "info", title: "hi" }),
    ).toThrow(/source required/);
  });
  it("rejects oversized title", () => {
    expect(() =>
      validateNotificationInput({
        source: "test",
        level: "info",
        title: "x".repeat(81),
      }),
    ).toThrow(/title exceeds/);
  });
  it("rejects bad level", () => {
    expect(() =>
      validateNotificationInput({
        source: "test",
        level: "critical",
        title: "hi",
      }),
    ).toThrow(/level must be/);
  });
  it("accepts the happy path", () => {
    const out = validateNotificationInput({
      source: "test:case",
      level: "warning",
      title: "hi",
      body: "ok",
      important: true,
    });
    expect(out.source).toBe("test:case");
    expect(out.level).toBe("warning");
    expect(out.important).toBe(true);
  });
});

describe("NotificationStore (unit, no transport)", () => {
  it("important+ttl interaction: important wins by default, explicit ttl still honored", () => {
    const dir = mkdtempSync(join(tmpdir(), "ovsm-store-"));
    const store = new NotificationStore({ dbPath: join(dir, "n.db") });
    try {
      const a = store.insert({
        source: "t",
        level: "info",
        title: "pinned",
        important: true,
      });
      expect(a.notification.ttlUntil ?? null).toBe(null);
      const b = store.insert({
        source: "t",
        level: "info",
        title: "pinned with ttl",
        important: true,
        ttl: 60,
      });
      expect(typeof b.notification.ttlUntil).toBe("number");
      const c = store.insert({
        source: "t",
        level: "info",
        title: "default ttl",
      });
      expect(typeof c.notification.ttlUntil).toBe("number");
    } finally {
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("markImportant(false) re-arms ttl on a previously-pinned row", () => {
    const dir = mkdtempSync(join(tmpdir(), "ovsm-store-"));
    const store = new NotificationStore({ dbPath: join(dir, "n.db") });
    try {
      const a = store.insert({
        source: "t",
        level: "info",
        title: "p",
        important: true,
      });
      expect(store.markImportant(a.notification.id, false)).toBe(true);
      // Read it back via list.
      const { items } = store.list({ limit: 10 });
      const row = items.find((i) => i.id === a.notification.id)!;
      expect(typeof row.ttlUntil).toBe("number");
      expect(row.important).toBeUndefined();
    } finally {
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("gcExpired deletes only expired non-important non-superseded rows", () => {
    const dir = mkdtempSync(join(tmpdir(), "ovsm-store-"));
    const store = new NotificationStore({ dbPath: join(dir, "n.db") });
    try {
      const past = Date.now() - 10_000;
      // Expired non-important — should be swept.
      const a = store.insert({
        source: "t",
        level: "info",
        title: "old",
        timestamp: past,
        ttl: 1,
      });
      // Expired but important — should survive.
      const b = store.insert({
        source: "t",
        level: "info",
        title: "old pinned",
        timestamp: past,
        ttl: 1,
        important: true,
      });
      // Fresh — should survive.
      const c = store.insert({ source: "t", level: "info", title: "fresh" });
      const deleted = store.gcExpired();
      expect(deleted).toContain(a.notification.id);
      expect(deleted).not.toContain(b.notification.id);
      expect(deleted).not.toContain(c.notification.id);
    } finally {
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("POST /notify (HTTP)", () => {
  let h: Harness;
  beforeAll(async () => {
    h = await startBackend();
  });
  afterAll(async () => {
    await h.shutdown();
  });

  it("happy path: 200 + id, row persisted, fan-out fires to subscribed WS", async () => {
    const client = await RpcClient.connect(h.wsUrl);
    try {
      await client.call("auth.handshake", { token: TOKEN, client: { deviceId: "dev-1" } });
      await client.call("notification.subscribe");
      const res = await postNotify(h.baseUrl, {
        source: "ci:nightly",
        level: "success",
        title: "build green",
        body: "all checks passed",
      });
      expect(res.status).toBe(200);
      const id = (res.body as { id: string }).id;
      expect(typeof id).toBe("string");
      // Fan-out received.
      const showed = (await client.waitNotif("notification.show")) as {
        notification: { id: string; title: string };
      };
      expect(showed.notification.id).toBe(id);
      expect(showed.notification.title).toBe("build green");
      // Persisted: list returns it.
      const listRes = (await client.call("notification.list", { limit: 10 })) as {
        items: Array<{ id: string }>;
      };
      expect(listRes.items.some((i) => i.id === id)).toBe(true);
    } finally {
      await client.close();
    }
  });

  it("schema violation: missing source → 400", async () => {
    const res = await postNotify(h.baseUrl, { level: "info", title: "x" });
    expect(res.status).toBe(400);
  });

  it("schema violation: oversized title → 400", async () => {
    const res = await postNotify(h.baseUrl, {
      source: "t",
      level: "info",
      title: "x".repeat(81),
    });
    expect(res.status).toBe(400);
  });

  it("schema violation: bad level → 400", async () => {
    const res = await postNotify(h.baseUrl, {
      source: "t",
      level: "critical",
      title: "x",
    });
    expect(res.status).toBe(400);
  });

  it("auth fail: wrong token → 401, missing token → 401", async () => {
    const r1 = await postNotify(
      h.baseUrl,
      { source: "t", level: "info", title: "x" },
      { token: "wrong" },
    );
    expect(r1.status).toBe(401);
    const r2 = await postNotify(
      h.baseUrl,
      { source: "t", level: "info", title: "x" },
      { token: null },
    );
    expect(r2.status).toBe(401);
  });
});

describe("supersedes chain", () => {
  let h: Harness;
  beforeAll(async () => {
    h = await startBackend();
  });
  afterAll(async () => {
    await h.shutdown();
  });

  it("A → A' → A''  marks old rows superseded; superseded events fire in order", async () => {
    const client = await RpcClient.connect(h.wsUrl);
    try {
      await client.call("auth.handshake", { token: TOKEN });
      await client.call("notification.subscribe");

      const a = (await postNotify(h.baseUrl, {
        source: "claude-code:openvsmobile",
        level: "info",
        title: "step 1",
      })).body as { id: string };
      await client.waitNotif("notification.show");

      const aPrime = (await postNotify(h.baseUrl, {
        source: "claude-code:openvsmobile",
        level: "info",
        title: "step 2",
        supersedes: a.id,
      })).body as { id: string };
      const supersedeFrame = (await client.waitNotif("notification.superseded")) as {
        oldId: string;
        newId: string;
      };
      expect(supersedeFrame.oldId).toBe(a.id);
      expect(supersedeFrame.newId).toBe(aPrime.id);
      await client.waitNotif("notification.show");

      const aPrimePrime = (await postNotify(h.baseUrl, {
        source: "claude-code:openvsmobile",
        level: "info",
        title: "step 3",
        supersedes: aPrime.id,
      })).body as { id: string };
      const sup2 = (await client.waitNotif("notification.superseded")) as {
        oldId: string;
        newId: string;
      };
      expect(sup2.oldId).toBe(aPrime.id);
      expect(sup2.newId).toBe(aPrimePrime.id);
      await client.waitNotif("notification.show");

      // Default list (includeSuperseded omitted → false) returns only the
      // head of the chain.
      const list = (await client.call("notification.list", { limit: 20 })) as {
        items: Array<{ id: string }>;
      };
      const ids = list.items.map((i) => i.id);
      expect(ids).toContain(aPrimePrime.id);
      expect(ids).not.toContain(a.id);
      expect(ids).not.toContain(aPrime.id);
    } finally {
      await client.close();
    }
  });
});

describe("markRead / markImportant / delete via RPC", () => {
  let h: Harness;
  beforeAll(async () => {
    h = await startBackend();
  });
  afterAll(async () => {
    await h.shutdown();
  });

  it("markRead updates read_by and broadcasts readChanged", async () => {
    const a = await RpcClient.connect(h.wsUrl);
    const b = await RpcClient.connect(h.wsUrl);
    try {
      await a.call("auth.handshake", { token: TOKEN, client: { deviceId: "phone" } });
      await b.call("auth.handshake", { token: TOKEN, client: { deviceId: "laptop" } });
      await a.call("notification.subscribe");
      await b.call("notification.subscribe");

      const res = await postNotify(h.baseUrl, {
        source: "t",
        level: "info",
        title: "hi",
      });
      const { id } = res.body as { id: string };
      await a.waitNotif("notification.show");
      await b.waitNotif("notification.show");

      await a.call("notification.markRead", { ids: [id] });
      const ev = (await b.waitNotif("notification.readChanged")) as {
        ids: string[];
        readByDevice: string;
      };
      expect(ev.ids).toContain(id);
      expect(ev.readByDevice).toBe("phone");

      const list = (await a.call("notification.list", { limit: 5 })) as {
        items: Array<{ id: string; readBy?: string[] }>;
      };
      const row = list.items.find((i) => i.id === id)!;
      expect(row.readBy).toEqual(["phone"]);
    } finally {
      await a.close();
      await b.close();
    }
  });

  it("markImportant(true) clears ttl; markImportant(false) re-arms it", async () => {
    const a = await RpcClient.connect(h.wsUrl);
    try {
      await a.call("auth.handshake", { token: TOKEN });
      await a.call("notification.subscribe");
      const res = await postNotify(h.baseUrl, {
        source: "t",
        level: "info",
        title: "later",
        ttl: 1,
      });
      const { id } = res.body as { id: string };
      await a.waitNotif("notification.show");
      await a.call("notification.markImportant", { id, important: true });
      // Force-expire all rows: bump now far into the future, ensure pinned
      // row survives.
      const deleted = h.state.notificationHub.runGcOnce(Date.now() + 10_000 * 1000);
      expect(deleted).not.toContain(id);

      await a.call("notification.markImportant", { id, important: false });
      // Now it should have a fresh ttl that's NOT past — still survives a
      // sweep "right now" but would be swept far in the future.
      const deletedNow = h.state.notificationHub.runGcOnce();
      expect(deletedNow).not.toContain(id);
    } finally {
      await a.close();
    }
  });

  it("markImportant on unknown id throws notificationNotFound", async () => {
    const a = await RpcClient.connect(h.wsUrl);
    try {
      await a.call("auth.handshake", { token: TOKEN });
      await expect(
        a.call("notification.markImportant", { id: "no-such-id", important: true }),
      ).rejects.toMatchObject({ code: -32010 });
    } finally {
      await a.close();
    }
  });

  it("notification.delete broadcasts notification.deleted", async () => {
    const a = await RpcClient.connect(h.wsUrl);
    try {
      await a.call("auth.handshake", { token: TOKEN });
      await a.call("notification.subscribe");
      const res = await postNotify(h.baseUrl, {
        source: "t",
        level: "info",
        title: "x",
      });
      const { id } = res.body as { id: string };
      await a.waitNotif("notification.show");
      await a.call("notification.delete", { ids: [id] });
      const ev = (await a.waitNotif("notification.deleted")) as { ids: string[] };
      expect(ev.ids).toContain(id);
    } finally {
      await a.close();
    }
  });
});

describe("GC worker", () => {
  let h: Harness;
  beforeAll(async () => {
    h = await startBackend();
  });
  afterAll(async () => {
    await h.shutdown();
  });

  it("sweeps expired non-important non-superseded rows and broadcasts deleted", async () => {
    const a = await RpcClient.connect(h.wsUrl);
    try {
      await a.call("auth.handshake", { token: TOKEN });
      await a.call("notification.subscribe");
      // Insert one already-expired row.
      const past = Date.now() - 10_000;
      const expiredRes = await postNotify(h.baseUrl, {
        source: "t",
        level: "info",
        title: "old",
        timestamp: past,
        ttl: 1,
      });
      const expiredId = (expiredRes.body as { id: string }).id;
      await a.waitNotif("notification.show");
      // Insert one fresh row.
      const freshRes = await postNotify(h.baseUrl, {
        source: "t",
        level: "info",
        title: "fresh",
      });
      const freshId = (freshRes.body as { id: string }).id;
      await a.waitNotif("notification.show");

      const deleted = h.state.notificationHub.runGcOnce();
      expect(deleted).toContain(expiredId);
      expect(deleted).not.toContain(freshId);
      const ev = (await a.waitNotif("notification.deleted")) as { ids: string[] };
      expect(ev.ids).toContain(expiredId);
    } finally {
      await a.close();
    }
  });
});

describe("CLI smoke: mobile-notify --from-json -", () => {
  let h: Harness;
  beforeAll(async () => {
    h = await startBackend();
  });
  afterAll(async () => {
    await h.shutdown();
  });

  it("posts a payload from stdin and prints the assigned id", async () => {
    const payload = {
      source: "cli:test",
      level: "info",
      title: "from cli",
      body: "hello",
    };
    const child = spawn(
      process.execPath,
      [
        CLI_PATH,
        "--server",
        `127.0.0.1:${h.port}`,
        "--token",
        TOKEN,
        "--from-json",
        "-",
      ],
      { stdio: ["pipe", "pipe", "pipe"] },
    );
    child.stdin.write(JSON.stringify(payload));
    child.stdin.end();
    const stdoutChunks: Buffer[] = [];
    const stderrChunks: Buffer[] = [];
    child.stdout.on("data", (c) => stdoutChunks.push(c));
    child.stderr.on("data", (c) => stderrChunks.push(c));
    const exitCode: number = await new Promise((resolve) =>
      child.on("close", (code) => resolve(code ?? -1)),
    );
    const stdout = Buffer.concat(stdoutChunks).toString("utf8").trim();
    const stderr = Buffer.concat(stderrChunks).toString("utf8");
    expect(exitCode, `stderr: ${stderr}`).toBe(0);
    expect(stdout).toMatch(/^[0-9a-f-]{36}$/);
    // Verify it actually landed in the store.
    const stored = h.state.notificationHub.list({ limit: 5 }).items.find(
      (n) => n.id === stdout,
    );
    expect(stored).toBeDefined();
    expect(stored!.title).toBe("from cli");
  });

  it("missing token: exits with code 2 and writes to stderr", async () => {
    // Point at a config file that exists but has nothing useful. We use
    // HOME=/tmp/<empty-dir> so the CLI's config lookup misses.
    const emptyHome = mkdtempSync(join(tmpdir(), "ovsm-home-"));
    try {
      const child = spawn(
        process.execPath,
        [CLI_PATH, "--server", `127.0.0.1:${h.port}`, "--source", "t", "--title", "x"],
        {
          stdio: ["ignore", "pipe", "pipe"],
          env: {
            ...process.env,
            HOME: emptyHome,
            OPENVSMOBILE_TOKEN: "",
            OPENVSMOBILE_SERVER: "",
            OPENVSMOBILE_RUNTIME_INFO_PATH: join(emptyHome, "nope.json"),
          },
        },
      );
      const exitCode: number = await new Promise((resolve) =>
        child.on("close", (code) => resolve(code ?? -1)),
      );
      expect(exitCode).toBe(2);
    } finally {
      rmSync(emptyHome, { recursive: true, force: true });
    }
  });
});

describe("hub fan-out gating", () => {
  let h: Harness;
  beforeAll(async () => {
    h = await startBackend();
  });
  afterAll(async () => {
    await h.shutdown();
  });

  it("unsubscribed connection receives nothing on notification.show", async () => {
    const a = await RpcClient.connect(h.wsUrl);
    try {
      await a.call("auth.handshake", { token: TOKEN });
      // Deliberately do NOT subscribe.
      await postNotify(h.baseUrl, {
        source: "t",
        level: "info",
        title: "silent",
      });
      // Wait long enough that any incorrectly-pushed frame would land.
      await new Promise((r) => setTimeout(r, 100));
      expect(a.notifs.find((n) => n.method === "notification.show")).toBeUndefined();
    } finally {
      await a.close();
    }
  });

  it("subscribe → unsubscribe drops subsequent shows", async () => {
    const a = await RpcClient.connect(h.wsUrl);
    try {
      await a.call("auth.handshake", { token: TOKEN });
      await a.call("notification.subscribe");
      await postNotify(h.baseUrl, { source: "t", level: "info", title: "1" });
      await a.waitNotif("notification.show");
      await a.call("notification.unsubscribe");
      await postNotify(h.baseUrl, { source: "t", level: "info", title: "2" });
      await new Promise((r) => setTimeout(r, 100));
      // No new show frame after unsubscribe.
      expect(a.notifs.find((n) => n.method === "notification.show")).toBeUndefined();
    } finally {
      await a.close();
    }
  });
});

describe("NotificationHub wiring (unit)", () => {
  it("publish without fan-out attached doesn't crash", () => {
    const dir = mkdtempSync(join(tmpdir(), "ovsm-hub-"));
    const store = new NotificationStore({ dbPath: join(dir, "n.db") });
    const hub = new NotificationHub(store);
    try {
      const { id } = hub.publish({ source: "t", level: "info", title: "ok" });
      expect(typeof id).toBe("string");
    } finally {
      hub.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

