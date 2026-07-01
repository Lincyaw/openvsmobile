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
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
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
  });
  const server = createServer((req, res) => {
    if (req.url === "/notify") {
      void handleNotifyHttp(req, res, {
        expectedToken: TOKEN,
        hub: state.notificationHub,
        tokenStore: state.tokenStore,
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

  it("markImportant promote → demote re-anchors ttl at ~now + 7d (original ttl lost)", () => {
    const dir = mkdtempSync(join(tmpdir(), "ovsm-store-"));
    const store = new NotificationStore({ dbPath: join(dir, "n.db") });
    try {
      // Insert with a short explicit ttl so we can tell whether the original
      // window was preserved (the spec says it was — but the design we
      // committed to says it's not, since promote nukes ttl_until).
      const a = store.insert({
        source: "t",
        level: "info",
        title: "p",
        ttl: 3600, // 1h
      });
      expect(store.markImportant(a.notification.id, true)).toBe(true);
      const before = Date.now();
      expect(store.markImportant(a.notification.id, false)).toBe(true);
      const after = Date.now();
      const { items } = store.list({ limit: 10 });
      const row = items.find((i) => i.id === a.notification.id)!;
      expect(typeof row.ttlUntil).toBe("number");
      const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;
      // ttlUntil should be approximately now + 7d, NOT the original (now + 1h).
      expect(row.ttlUntil).toBeGreaterThanOrEqual(before + sevenDaysMs - 5);
      expect(row.ttlUntil).toBeLessThanOrEqual(after + sevenDaysMs + 5);
    } finally {
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("includeRead=false hides rows already read by THIS device, keeps others", () => {
    const dir = mkdtempSync(join(tmpdir(), "ovsm-store-"));
    const store = new NotificationStore({ dbPath: join(dir, "n.db") });
    try {
      const r1 = store.insert({ source: "t", level: "info", title: "one" });
      const r2 = store.insert({ source: "t", level: "info", title: "two" });
      store.markRead([r1.notification.id], "phoneA");
      // phoneA: should see only the unread row.
      const fromPhoneA = store.list({
        limit: 50,
        includeRead: false,
        deviceId: "phoneA",
      });
      const idsA = fromPhoneA.items.map((i) => i.id);
      expect(idsA).toContain(r2.notification.id);
      expect(idsA).not.toContain(r1.notification.id);
      // tabletB: hasn't read anything yet — should see both.
      const fromTabletB = store.list({
        limit: 50,
        includeRead: false,
        deviceId: "tabletB",
      });
      const idsB = fromTabletB.items.map((i) => i.id);
      expect(idsB).toContain(r1.notification.id);
      expect(idsB).toContain(r2.notification.id);
      // includeRead default (true): everyone sees both.
      const all = store.list({ limit: 50 });
      const idsAll = all.items.map((i) => i.id);
      expect(idsAll).toContain(r1.notification.id);
      expect(idsAll).toContain(r2.notification.id);
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

  it("oversized body → 413", async () => {
    // 2 MiB body — well above MAX_BODY_BYTES (1 MiB) in notifyHttp.ts.
    const huge = "a".repeat(2 * 1024 * 1024);
    const res = await fetch(`${h.baseUrl}/notify`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${TOKEN}`,
      },
      body: huge,
    });
    expect(res.status).toBe(413);
  });

  it("500 path does not leak error message to client body", async () => {
    // Monkey-patch the hub's publish to throw an error whose message
    // contains a sentinel we then assert is NOT in the response body.
    const hub = h.state.notificationHub;
    const original = hub.publish.bind(hub);
    hub.publish = (() => {
      throw new Error("SECRET_TOKEN_LEAK_abc123");
    }) as typeof hub.publish;
    try {
      const res = await postNotify(h.baseUrl, {
        source: "t",
        level: "info",
        title: "x",
      });
      expect(res.status).toBe(500);
      const bodyText = JSON.stringify(res.body);
      expect(bodyText).not.toContain("SECRET_TOKEN_LEAK");
      expect(bodyText).toContain("internal error");
    } finally {
      hub.publish = original;
    }
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

  it("markImportant on unknown id returns ok (symmetric with delete)", async () => {
    const a = await RpcClient.connect(h.wsUrl);
    try {
      await a.call("auth.handshake", { token: TOKEN });
      const res = await a.call("notification.markImportant", {
        id: "nonexistent-uuid",
        important: true,
      });
      expect(res).toEqual({ ok: true });
    } finally {
      await a.close();
    }
  });

  it("delete of unknown id returns ok and emits no broadcast", async () => {
    const a = await RpcClient.connect(h.wsUrl);
    try {
      await a.call("auth.handshake", { token: TOKEN });
      await a.call("notification.subscribe");
      const res = await a.call("notification.delete", {
        ids: ["nonexistent-uuid"],
      });
      expect(res).toEqual({ ok: true });
      // Give any phantom broadcast a moment to land.
      await new Promise((r) => setTimeout(r, 100));
      expect(
        a.notifs.find((n) => n.method === "notification.deleted"),
      ).toBeUndefined();
    } finally {
      await a.close();
    }
  });

  it("markRead is idempotent: same device twice keeps read_by length 1", async () => {
    const a = await RpcClient.connect(h.wsUrl);
    try {
      await a.call("auth.handshake", { token: TOKEN, client: { deviceId: "phoneA" } });
      await a.call("notification.subscribe");
      const res = await postNotify(h.baseUrl, {
        source: "t",
        level: "info",
        title: "hi",
      });
      const { id } = res.body as { id: string };
      await a.waitNotif("notification.show");
      await a.call("notification.markRead", { ids: [id] });
      await a.call("notification.markRead", { ids: [id] });
      const list = (await a.call("notification.list", { limit: 5 })) as {
        items: Array<{ id: string; readBy?: string[] }>;
      };
      const row = list.items.find((i) => i.id === id)!;
      expect(row.readBy).toEqual(["phoneA"]);
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

describe("GC sweep (event-driven)", () => {
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

  it("notification.list triggers a sweep when lastSweepMs is stale", async () => {
    // Use a fresh per-test backend so the GC trigger state isn't shared.
    const local = await startBackend();
    try {
      const a = await RpcClient.connect(local.wsUrl);
      try {
        await a.call("auth.handshake", { token: TOKEN });
        await a.call("notification.subscribe");

        // Insert an already-expired row directly through the hub so we
        // bypass the publish-time GC trigger entirely.
        const past = Date.now() - 10_000;
        const { id: expiredId } = local.state.notificationHub.publish({
          source: "t",
          level: "info",
          title: "old",
          timestamp: past,
          ttl: 1,
        });
        await a.waitNotif("notification.show");

        // lastSweepMs starts at 0; the first list call should fire a sweep.
        const listRes = (await a.call("notification.list", { limit: 50 })) as {
          items: Array<{ id: string }>;
        };
        // The expired row is gone from the result.
        expect(listRes.items.find((i) => i.id === expiredId)).toBeUndefined();
        // ...and a deleted broadcast lands.
        const ev = (await a.waitNotif("notification.deleted")) as { ids: string[] };
        expect(ev.ids).toContain(expiredId);
      } finally {
        await a.close();
      }
    } finally {
      await local.shutdown();
    }
  });

  it("two list calls within GC_MIN_INTERVAL_MS sweep only once", async () => {
    const local = await startBackend();
    try {
      const a = await RpcClient.connect(local.wsUrl);
      try {
        await a.call("auth.handshake", { token: TOKEN });
        await a.call("notification.subscribe");

        // First sweep — set lastSweepMs to "now-ish".
        local.state.notificationHub.runGcOnce();

        // Insert another already-expired row. Bypass the publish-time
        // trigger by checking the insertCounter first: we want a clean test
        // of the list-only trigger. We can do this by inserting fewer than
        // 100 times so the insert-trigger doesn't fire.
        local.state.notificationHub.publish({
          source: "t",
          level: "info",
          title: "stale1",
          timestamp: Date.now() - 10_000,
          ttl: 1,
        });
        await a.waitNotif("notification.show");

        // Two list calls in quick succession — only the first might have
        // triggered. lastSweepMs was set just above, so neither should
        // trigger now. The expired row remains visible because we set
        // includeSuperseded=false default; since superseded_by is NULL it
        // SHOULD show up if no sweep happened.
        const r1 = (await a.call("notification.list", { limit: 50 })) as {
          items: Array<{ id: string }>;
        };
        const r2 = (await a.call("notification.list", { limit: 50 })) as {
          items: Array<{ id: string }>;
        };
        // Both responses see the same set — sweep did not fire between them.
        expect(r1.items.length).toBe(r2.items.length);

        // No notification.deleted broadcasts because no sweep was run.
        await new Promise((r) => setTimeout(r, 100));
        expect(
          a.notifs.find((n) => n.method === "notification.deleted"),
        ).toBeUndefined();
      } finally {
        await a.close();
      }
    } finally {
      await local.shutdown();
    }
  });

  it("100 sequential inserts trigger an opportunistic sweep", async () => {
    const local = await startBackend();
    try {
      const a = await RpcClient.connect(local.wsUrl);
      try {
        await a.call("auth.handshake", { token: TOKEN });
        await a.call("notification.subscribe");

        // First, insert one already-expired row to give the GC something
        // to delete on the eventual sweep.
        const past = Date.now() - 10_000;
        local.state.notificationHub.publish({
          source: "t",
          level: "info",
          title: "doomed",
          timestamp: past,
          ttl: 1,
        });
        // Drain its show.
        await a.waitNotif("notification.show");

        // Drain notifications by emptying the array.
        a.notifs.length = 0;

        // Now do 99 more inserts (we already did 1 → counter is 1). The
        // 100th insert (counter==100) should trigger a sweep.
        for (let i = 0; i < 99; i++) {
          local.state.notificationHub.publish({
            source: "t",
            level: "info",
            title: `bump-${i}`,
          });
        }

        // Wait a moment for the deleted broadcast to land.
        const ev = (await a.waitNotif("notification.deleted", 2000)) as {
          ids: string[];
        };
        expect(ev.ids.length).toBeGreaterThanOrEqual(1);
      } finally {
        await a.close();
      }
    } finally {
      await local.shutdown();
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

  it("--from-claude-hook translates a Stop event into a notification", async () => {
    const transcriptDir = mkdtempSync(join(tmpdir(), "ovsm-transcript-"));
    const transcriptPath = join(transcriptDir, "session.jsonl");
    writeFileSync(
      transcriptPath,
      [
        JSON.stringify({
          type: "user",
          message: { role: "user", content: "run the check" },
        }),
        JSON.stringify({
          type: "assistant",
          message: {
            role: "assistant",
            content: [
              {
                type: "text",
                text: "All checks passed.\nNo follow-up needed.",
              },
            ],
          },
        }),
        "",
      ].join("\n"),
    );
    const hookEvent = {
      hook_event_name: "Stop",
      session_id: "abc123",
      cwd: "/home/u/proj",
      transcript_path: transcriptPath,
    };
    try {
      const child = spawn(
        process.execPath,
        [
          CLI_PATH,
          "--server",
          `127.0.0.1:${h.port}`,
          "--token",
          TOKEN,
          "--from-claude-hook",
        ],
        {
          stdio: ["pipe", "pipe", "pipe"],
          env: {
            ...process.env,
            ZELLIJ_SESSION_NAME: "ovsm-123e4567-e89b-12d3-a456-426614174000",
          },
        },
      );
      child.stdin.write(JSON.stringify(hookEvent));
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
      const stored = h.state.notificationHub
        .list({ limit: 5 })
        .items.find((n) => n.id === stdout);
      expect(stored).toBeDefined();
      expect(stored!.source).toBe("claude-code");
      expect(stored!.title).toBe("Claude: All checks passed.");
      expect(stored!.body).toBe("All checks passed.\nNo follow-up needed.");
      expect(stored!.groupKey).toBe("claude-code:abc123");
      expect(stored!.action).toEqual({
        kind: "open-terminal",
        sessionId: "123e4567-e89b-12d3-a456-426614174000",
        externalSessionId: "ovsm-123e4567-e89b-12d3-a456-426614174000",
      });
      expect(stored!.fields?.find((f) => f.key === "cwd")?.value).toBe(
        "/home/u/proj",
      );
      expect(stored!.fields?.find((f) => f.key === "transcript")?.value).toBe(
        transcriptPath,
      );
    } finally {
      rmSync(transcriptDir, { recursive: true, force: true });
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

  it("publish() fires the attached ntfy sender with the persisted notification", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ovsm-hub-"));
    const store = new NotificationStore({ dbPath: join(dir, "n.db") });
    const hub = new NotificationHub(store);
    const seen: Array<{ id: string; title: string; level: string }> = [];
    let resolveOne: (() => void) | null = null;
    const oneSent = new Promise<void>((resolve) => {
      resolveOne = resolve;
    });
    hub.attachNtfySender({
      async send(n) {
        seen.push({ id: n.id, title: n.title, level: n.level });
        resolveOne?.();
      },
    });
    try {
      const { id } = hub.publish({
        source: "t",
        level: "warning",
        title: "ntfy probe",
        body: "via stub",
      });
      // send() is fire-and-forget — wait for the stub to record the call.
      await oneSent;
      expect(seen).toHaveLength(1);
      expect(seen[0]!.id).toBe(id);
      expect(seen[0]!.title).toBe("ntfy probe");
      expect(seen[0]!.level).toBe("warning");
    } finally {
      hub.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("publish() does not throw when the attached ntfy sender rejects", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ovsm-hub-"));
    const store = new NotificationStore({ dbPath: join(dir, "n.db") });
    const hub = new NotificationHub(store);
    let resolveOne: (() => void) | null = null;
    const oneSent = new Promise<void>((resolve) => {
      resolveOne = resolve;
    });
    hub.attachNtfySender({
      async send() {
        // Simulate ntfy server unreachable. The fire-and-forget block in
        // publish() must swallow this without bubbling up to the caller.
        resolveOne?.();
        throw new Error("simulated ntfy down");
      },
    });
    try {
      expect(() =>
        hub.publish({ source: "t", level: "info", title: "ok" }),
      ).not.toThrow();
      await oneSent;
    } finally {
      hub.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
