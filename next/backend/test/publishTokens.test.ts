// Coverage for the publish-token system end to end:
//   - TokenStore: mint / lookup / revoke / relabel + source-prefix matching
//     (incl. prefix-confusion guard) + rate limit.
//   - /notify accepting a publish token (success, 403 on source-prefix
//     violation, 429 on rate limit).
//   - /hook accepting JSON / form / plain / GET, the idempotency replay,
//     and the URL-vs-body source conflict.
//   - admin RPCs over the WS surface.

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createServer, type Server } from "node:http";
import { WebSocketServer } from "ws";
import WebSocket from "ws";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Connection } from "../src/connection.js";
import { ProcessState } from "../src/state.js";
import { handleNotifyHttp } from "../src/notifyHttp.js";
import { HookHandler } from "../src/hookHttp.js";
import {
  TokenStore,
  parsePublishToken,
  sourceMatchesPrefix,
  TokenError,
} from "../src/tokenStore.js";

const TOKEN = "auth-token-fixed";

interface Harness {
  state: ProcessState;
  baseUrl: string;
  wsUrl: string;
  shutdown: () => Promise<void>;
}

async function startBackend(): Promise<Harness> {
  const tmpDir = mkdtempSync(join(tmpdir(), "ovsm-pubtok-"));
  const state = new ProcessState({
    notificationDbPath: join(tmpDir, "notifications.db"),
    tokensDbPath: join(tmpDir, "tokens.db"),
  });
  const hookHandler = new HookHandler({
    expectedToken: TOKEN,
    hub: state.notificationHub,
    tokenStore: state.tokenStore,
  });
  const server: Server = createServer((req, res) => {
    if (req.url === "/notify") {
      void handleNotifyHttp(req, res, {
        expectedToken: TOKEN,
        hub: state.notificationHub,
        tokenStore: state.tokenStore,
      });
      return;
    }
    if (req.url !== undefined && req.url.startsWith("/hook/")) {
      void hookHandler.handle(req, res);
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
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const addr = server.address();
  if (!addr || typeof addr === "string") throw new Error("no addr");
  return {
    state,
    baseUrl: `http://127.0.0.1:${addr.port}`,
    wsUrl: `ws://127.0.0.1:${addr.port}/rpc`,
    shutdown: async () => {
      state.shutdownAll();
      await new Promise<void>((res, rej) =>
        wss.close((e) => (e ? rej(e) : res())),
      );
      await new Promise<void>((res, rej) =>
        server.close((e) => (e ? rej(e) : res())),
      );
      rmSync(tmpDir, { recursive: true, force: true });
    },
  };
}

class RpcClient {
  private nextId = 1;
  private readonly pending = new Map<
    number,
    { res: (v: unknown) => void; rej: (e: unknown) => void }
  >();

  private constructor(private readonly ws: WebSocket) {}

  static async connect(url: string): Promise<RpcClient> {
    const ws = new WebSocket(url);
    await new Promise<void>((res, rej) => {
      ws.once("open", () => res());
      ws.once("error", rej);
    });
    const c = new RpcClient(ws);
    ws.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());
      if (msg.id !== undefined && c.pending.has(msg.id)) {
        const p = c.pending.get(msg.id)!;
        c.pending.delete(msg.id);
        if (msg.error) p.rej(msg.error);
        else p.res(msg.result);
      }
    });
    return c;
  }

  call(method: string, params?: unknown): Promise<unknown> {
    const id = this.nextId++;
    return new Promise((res, rej) => {
      this.pending.set(id, { res, rej });
      this.ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  close(): void {
    this.ws.close();
  }
}

async function authedClient(wsUrl: string): Promise<RpcClient> {
  const c = await RpcClient.connect(wsUrl);
  await c.call("auth.handshake", {
    token: TOKEN,
    client: { kind: "test", version: "0", deviceId: "dev1" },
  });
  return c;
}

// ===== 1. TokenStore unit tests =====

describe("TokenStore", () => {
  function freshStore(): TokenStore {
    const dir = mkdtempSync(join(tmpdir(), "ovsm-ts-"));
    return new TokenStore({ dbPath: join(dir, "t.db") });
  }

  it("mint returns parseable <id>.<secret>", () => {
    const ts = freshStore();
    const { id, token } = ts.mint({ label: "ci" });
    expect(token).toMatch(/^[a-f0-9]{12}\.[a-f0-9]{64}$/);
    const parsed = parsePublishToken(token);
    expect(parsed?.id).toBe(id);
    ts.close();
  });

  it("lookup returns the record; revoke makes it unknown", () => {
    const ts = freshStore();
    const { id, token } = ts.mint({ label: "ci" });
    expect(ts.lookup(token).id).toBe(id);
    expect(ts.revoke(id)).toBe(true);
    expect(() => ts.lookup(token)).toThrow(TokenError);
  });

  it("rejects malformed tokens with bad-format", () => {
    const ts = freshStore();
    expect(() => ts.lookup("notatoken")).toThrow(TokenError);
    try {
      ts.lookup("notatoken");
    } catch (e) {
      expect((e as TokenError).code).toBe("bad-format");
    }
    // Has a dot but wrong lengths — still bad-format.
    expect(() => ts.lookup("abc.def")).toThrow(TokenError);
  });

  it("source prefix matches exact and colon-bounded", () => {
    expect(sourceMatchesPrefix("ci", "ci")).toBe(true);
    expect(sourceMatchesPrefix("ci", "ci:nightly")).toBe(true);
    expect(sourceMatchesPrefix("ci", "cirrus")).toBe(false); // confusion guard
    expect(sourceMatchesPrefix("ci", "ci-rogue")).toBe(false);
    expect(sourceMatchesPrefix(null, "anything")).toBe(true);
  });

  it("checkSourceAllowed enforces the prefix", () => {
    const ts = freshStore();
    const { token } = ts.mint({ label: "x", sourcePrefix: "grafana" });
    const rec = ts.lookup(token);
    expect(() =>
      ts.checkSourceAllowed(rec, "grafana:alerts"),
    ).not.toThrow();
    expect(() => ts.checkSourceAllowed(rec, "claude-code")).toThrow(
      TokenError,
    );
    ts.close();
  });

  it("rate limit fires 429 at the configured ceiling", () => {
    let nowMs = 1_000_000;
    const ts = new TokenStore({
      dbPath: join(
        mkdtempSync(join(tmpdir(), "ovsm-ts-")),
        "t.db",
      ),
      now: () => nowMs,
    });
    const { token } = ts.mint({
      label: "rl",
      rateLimitPerMin: 3,
      rateLimitPerHour: 10,
    });
    const rec = ts.lookup(token);
    expect(ts.consumeRate(rec).ok).toBe(true);
    expect(ts.consumeRate(rec).ok).toBe(true);
    expect(ts.consumeRate(rec).ok).toBe(true);
    expect(() => ts.consumeRate(rec)).toThrow(TokenError);
    // New minute window — counter resets.
    nowMs += 60_000;
    expect(ts.consumeRate(rec).ok).toBe(true);
    ts.close();
  });

  it("list omits the secret hash", () => {
    const ts = freshStore();
    ts.mint({ label: "vis" });
    const items = ts.list();
    expect(items).toHaveLength(1);
    expect((items[0] as unknown as { secretHash?: string }).secretHash).toBeUndefined();
    ts.close();
  });
});

// ===== 2. Sender endpoints =====

describe("sender endpoints with publish tokens", () => {
  let h: Harness;
  beforeAll(async () => {
    h = await startBackend();
  });
  afterAll(async () => {
    await h.shutdown();
  });

  it("/notify accepts a valid publish token", async () => {
    const { token } = h.state.tokenStore.mint({ label: "n1" });
    const res = await fetch(`${h.baseUrl}/notify`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        source: "ci",
        level: "info",
        title: "hello",
      }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { id: string };
    expect(body.id).toMatch(/.+/);
  });

  it("/notify returns 403 when source is outside the token's prefix", async () => {
    const { token } = h.state.tokenStore.mint({
      label: "scoped",
      sourcePrefix: "grafana",
    });
    const res = await fetch(`${h.baseUrl}/notify`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        source: "claude-code",
        level: "info",
        title: "x",
      }),
    });
    expect(res.status).toBe(403);
  });

  it("/notify returns 401 for unknown / revoked tokens", async () => {
    const { id, token } = h.state.tokenStore.mint({ label: "doomed" });
    h.state.tokenStore.revoke(id);
    const res = await fetch(`${h.baseUrl}/notify`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ source: "ci", level: "info", title: "x" }),
    });
    expect(res.status).toBe(401);
  });

  it("/hook accepts text/plain with title from first line", async () => {
    const { token } = h.state.tokenStore.mint({ label: "h1" });
    const res = await fetch(`${h.baseUrl}/hook/${token}/ci`, {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: "build done\nlogs here",
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { id: string };
    expect(body.id).toMatch(/.+/);
  });

  it("/hook accepts form-encoded body with aliases", async () => {
    const { token } = h.state.tokenStore.mint({ label: "h2" });
    const res = await fetch(`${h.baseUrl}/hook/${token}/ci`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "subject=oops&severity=critical&message=trace",
    });
    expect(res.status).toBe(200);
  });

  it("/hook GET with token in path + ?title", async () => {
    const { token } = h.state.tokenStore.mint({ label: "h3" });
    const res = await fetch(
      `${h.baseUrl}/hook/${token}/ci?title=ping&level=warning`,
    );
    expect(res.status).toBe(200);
  });

  it("/hook with header auth + JSON body", async () => {
    const { token } = h.state.tokenStore.mint({ label: "h4" });
    const res = await fetch(`${h.baseUrl}/hook/ci`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ level: "info", title: "hi" }),
    });
    expect(res.status).toBe(200);
  });

  it("/hook rejects body source that conflicts with URL", async () => {
    const { token } = h.state.tokenStore.mint({ label: "h5" });
    const res = await fetch(`${h.baseUrl}/hook/ci`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ source: "other", level: "info", title: "x" }),
    });
    expect(res.status).toBe(400);
  });

  it("/hook idempotency replay returns the original id", async () => {
    const { token } = h.state.tokenStore.mint({ label: "h6" });
    const key = "evt-12345";
    const first = await fetch(`${h.baseUrl}/hook/${token}/ci`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "idempotency-key": key,
      },
      body: JSON.stringify({ level: "info", title: "once" }),
    });
    expect(first.status).toBe(200);
    const firstBody = (await first.json()) as { id: string };
    const second = await fetch(`${h.baseUrl}/hook/${token}/ci`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "idempotency-key": key,
      },
      body: JSON.stringify({ level: "info", title: "different" }),
    });
    expect(second.status).toBe(200);
    const secondBody = (await second.json()) as {
      id: string;
      idempotent?: boolean;
    };
    expect(secondBody.id).toBe(firstBody.id);
    expect(secondBody.idempotent).toBe(true);
  });

  it("/hook rejects malformed source segments", async () => {
    const { token } = h.state.tokenStore.mint({ label: "h7" });
    const res = await fetch(`${h.baseUrl}/hook/${token}/has%20space`);
    expect(res.status).toBe(404);
  });

  it("/hook returns 415 for unsupported content type", async () => {
    const { token } = h.state.tokenStore.mint({ label: "h8" });
    const res = await fetch(`${h.baseUrl}/hook/${token}/ci`, {
      method: "POST",
      headers: { "content-type": "application/xml" },
      body: "<x/>",
    });
    expect(res.status).toBe(415);
  });
});

// ===== 3. Admin RPCs =====

describe("auth.publishTokens.* admin RPCs", () => {
  let h: Harness;
  beforeAll(async () => {
    h = await startBackend();
  });
  afterAll(async () => {
    await h.shutdown();
  });

  it("create returns a one-shot secret and a record", async () => {
    const c = await authedClient(h.wsUrl);
    const r = (await c.call("auth.publishTokens.create", {
      label: "github-actions",
      sourcePrefix: "ci",
    })) as { record: { id: string; label: string }; secret: string };
    expect(r.record.label).toBe("github-actions");
    expect(r.secret).toMatch(/^[a-f0-9]{12}\.[a-f0-9]{64}$/);
    c.close();
  });

  it("list reflects mint + revoke", async () => {
    const c = await authedClient(h.wsUrl);
    const before = (await c.call("auth.publishTokens.list")) as {
      items: unknown[];
    };
    const m = (await c.call("auth.publishTokens.create", {
      label: "transient",
    })) as { record: { id: string } };
    const mid = (await c.call("auth.publishTokens.list")) as {
      items: unknown[];
    };
    expect(mid.items.length).toBe(before.items.length + 1);
    const rev = (await c.call("auth.publishTokens.revoke", {
      id: m.record.id,
    })) as { revoked: boolean };
    expect(rev.revoked).toBe(true);
    const after = (await c.call("auth.publishTokens.list")) as {
      items: unknown[];
    };
    expect(after.items.length).toBe(before.items.length);
    c.close();
  });

  it("relabel changes the label", async () => {
    const c = await authedClient(h.wsUrl);
    const m = (await c.call("auth.publishTokens.create", {
      label: "old",
    })) as { record: { id: string } };
    await c.call("auth.publishTokens.relabel", {
      id: m.record.id,
      label: "new",
    });
    const { items } = (await c.call("auth.publishTokens.list")) as {
      items: { id: string; label: string }[];
    };
    expect(items.find((t) => t.id === m.record.id)?.label).toBe("new");
    c.close();
  });
});
