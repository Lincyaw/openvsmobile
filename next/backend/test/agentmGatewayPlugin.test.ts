// End-to-end smoke for the AgentM gateway example plugin.
//
// This starts a fake AgentM gateway over a real Unix socket, launches the
// plugin through PluginHost, and verifies the full bridge:
//   app ui.event -> AgentM inbound
//   AgentM outbound -> openvsmobile replyable notification
//   notification.reply -> AgentM inbound

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { WebSocket } from "ws";
import net from "node:net";
import { Buffer } from "node:buffer";
import { randomUUID } from "node:crypto";
import { cp, mkdir, rm, unlink } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  FakeWebSocket,
  makeTempDir,
  rmTempDir,
  sleep,
} from "./_helpers.js";
import { dispatch, type RpcContext } from "../src/rpc.js";
import { ProcessState } from "../src/state.js";
import { PluginHost } from "../src/plugins/host.js";
import type { NotificationInput } from "../src/notifications.js";

const THIS_FILE_DIR = dirname(fileURLToPath(import.meta.url));
const EXAMPLE_AGENTM_DIR = resolve(
  THIS_FILE_DIR,
  "..",
  "..",
  "examples",
  "plugins",
  "agentm-gateway",
);

type Env = {
  v: number;
  id: string;
  kind: string;
  ts: number;
  body: Record<string, unknown>;
  session_key?: string;
  scenario?: string;
};

let staging: string | null = null;

beforeEach(async () => {
  staging = await makeTempDir("openvsmobile-agentm-plugin-");
});

afterEach(async () => {
  if (staging !== null) {
    await rmTempDir(staging);
    staging = null;
  }
});

function encode(env: Env): Buffer {
  const body = Buffer.from(JSON.stringify(env), "utf8");
  const header = Buffer.allocUnsafe(4);
  header.writeUInt32BE(body.length, 0);
  return Buffer.concat([header, body]);
}

function decode(buffer: Buffer): { frames: Env[]; rest: Buffer } {
  const frames: Env[] = [];
  let offset = 0;
  while (buffer.length - offset >= 4) {
    const len = buffer.readUInt32BE(offset);
    const end = offset + 4 + len;
    if (buffer.length < end) break;
    frames.push(JSON.parse(buffer.subarray(offset + 4, end).toString("utf8")));
    offset = end;
  }
  return { frames, rest: buffer.subarray(offset) };
}

function env(kind: string, body: Record<string, unknown>, extra = {}): Env {
  return {
    v: 2,
    id: randomUUID(),
    kind,
    ts: Date.now() / 1000,
    body,
    ...extra,
  };
}

async function waitFor<T>(
  predicate: () => T | undefined | Promise<T | undefined>,
  budgetMs: number,
  stepMs = 25,
): Promise<T> {
  const deadline = Date.now() + budgetMs;
  while (Date.now() < deadline) {
    const v = await predicate();
    if (v !== undefined) return v;
    await sleep(stepMs);
  }
  const v = await predicate();
  if (v !== undefined) return v;
  throw new Error(`waitFor timed out after ${budgetMs}ms`);
}

class FakeAgentMGateway {
  private server: net.Server | null = null;
  private socket: net.Socket | null = null;
  private buffer = Buffer.alloc(0);
  public readonly frames: Env[] = [];

  constructor(private readonly socketPath: string) {}

  async start(): Promise<void> {
    await unlink(this.socketPath).catch(() => {});
    this.server = net.createServer((socket) => {
      this.socket = socket;
      socket.on("data", (chunk) => {
        this.buffer = Buffer.concat([this.buffer, chunk]);
        const decoded = decode(this.buffer);
        this.buffer = decoded.rest;
        for (const frame of decoded.frames) this.onFrame(frame);
      });
    });
    await new Promise<void>((resolve, reject) => {
      this.server?.once("error", reject);
      this.server?.listen(this.socketPath, () => resolve());
    });
  }

  private onFrame(frame: Env): void {
    this.frames.push(frame);
    if (frame.kind === "hello") {
      this.send(
        env("welcome", {
          server_version: "fake-agentm",
          wire_version: 2,
          peer_id: "openvsmobile",
          session_resume: [],
          capabilities: { model: "fake", commands: [] },
        }),
      );
    }
  }

  send(frame: Env): void {
    this.socket?.write(encode(frame));
  }

  sendOutbound(
    kind: string,
    content: string,
    sessionKey = "openvsmobile:phone",
  ): void {
    this.send(
      env(
        "outbound",
        {
          channel: "openvsmobile",
          chat_id: "phone",
          content,
          metadata: { kind },
        },
        { session_key: sessionKey },
      ),
    );
  }

  async waitForFrame(
    predicate: (frame: Env) => boolean,
    budgetMs = 5000,
  ): Promise<Env> {
    return waitFor(() => this.frames.find(predicate), budgetMs);
  }

  async close(): Promise<void> {
    this.socket?.destroy();
    await new Promise<void>((resolve) => {
      if (this.server === null) {
        resolve();
        return;
      }
      this.server.close(() => resolve());
    });
    await unlink(this.socketPath).catch(() => {});
  }
}

async function call<T = unknown>(
  ctx: RpcContext,
  method: string,
  params: unknown = {},
): Promise<T> {
  return (await dispatch(ctx, {
    jsonrpc: "2.0",
    id: 1,
    method,
    params,
  })) as T;
}

async function buildHarness(socketPath: string): Promise<{
  gateway: FakeAgentMGateway;
  host: PluginHost;
  hostLogs: string[];
  ctx: RpcContext;
  notifications: NotificationInput[];
  restoreEnv: () => void;
}> {
  if (staging === null) throw new Error("staging dir not set up");
  const pluginsDir = join(staging, "plugins");
  const logDir = join(staging, "logs");
  await mkdir(pluginsDir, { recursive: true });
  await mkdir(logDir, { recursive: true });
  await cp(EXAMPLE_AGENTM_DIR, join(pluginsDir, "agentm-gateway"), {
    recursive: true,
  });

  const gateway = new FakeAgentMGateway(socketPath);
  await gateway.start();

  const oldConnect = process.env.OPENVSMOBILE_PLUGIN_AGENTM_CONNECT;
  const oldChannel = process.env.OPENVSMOBILE_PLUGIN_AGENTM_CHANNEL;
  const oldChatId = process.env.OPENVSMOBILE_PLUGIN_AGENTM_CHAT_ID;
  process.env.OPENVSMOBILE_PLUGIN_AGENTM_CONNECT = `unix://${socketPath}`;
  process.env.OPENVSMOBILE_PLUGIN_AGENTM_CHANNEL = "openvsmobile";
  process.env.OPENVSMOBILE_PLUGIN_AGENTM_CHAT_ID = "phone";
  const restoreEnv = () => {
    if (oldConnect === undefined) delete process.env.OPENVSMOBILE_PLUGIN_AGENTM_CONNECT;
    else process.env.OPENVSMOBILE_PLUGIN_AGENTM_CONNECT = oldConnect;
    if (oldChannel === undefined) delete process.env.OPENVSMOBILE_PLUGIN_AGENTM_CHANNEL;
    else process.env.OPENVSMOBILE_PLUGIN_AGENTM_CHANNEL = oldChannel;
    if (oldChatId === undefined) delete process.env.OPENVSMOBILE_PLUGIN_AGENTM_CHAT_ID;
    else process.env.OPENVSMOBILE_PLUGIN_AGENTM_CHAT_ID = oldChatId;
  };

  let nextNotification = 1;
  const notifications: NotificationInput[] = [];
  const hostLogs: string[] = [];
  const host = new PluginHost({
    pluginsDir,
    logDir,
    killGraceMs: 500,
    logger: (line) => hostLogs.push(line),
    onHostLog: () => {},
    notificationPublisher: (input) => {
      notifications.push(input);
      return { id: `notif-${nextNotification++}` };
    },
  });
  const state = new ProcessState({
    pluginHost: host,
    notificationDbPath: join(staging, "notifications.db"),
    tokensDbPath: join(staging, "tokens.db"),
  });
  const sock = new FakeWebSocket();
  const ctx: RpcContext = {
    state,
    expectedToken: "test-token",
    serverVersion: "0.0.0-test",
    ws: sock as unknown as WebSocket,
    markAuthenticated: () => {},
  };
  await host.start();
  return { gateway, host, hostLogs, ctx, notifications, restoreEnv };
}

describe("examples/plugins/agentm-gateway", () => {
  it("bridges UI input, AgentM outbounds, and notification replies", async () => {
    if (staging === null) throw new Error("staging dir not set up");
    const socketPath = join(staging, "agentm.sock");
    const harness = await buildHarness(socketPath);
    let hostShutdown = false;
    try {
      const hello = await harness.gateway.waitForFrame((f) => f.kind === "hello");
      expect(hello.body.peer_name).toBe("openvsmobile");

      await call(harness.ctx, "ui.event", {
        pluginId: "agentm-gateway",
        panelId: "chat",
        nodeId: "agentm-input",
        type: "changed",
        payload: { value: "hello agent" },
      });
      await call(harness.ctx, "ui.event", {
        pluginId: "agentm-gateway",
        panelId: "chat",
        nodeId: "agentm-send",
        type: "tap",
      });

      const firstInbound = await harness.gateway.waitForFrame(
        (f) => f.kind === "inbound" && f.body.content === "hello agent",
      );
      expect(firstInbound.session_key).toBe("openvsmobile:phone");
      expect(firstInbound.body.action).toBe("submit");
      expect(firstInbound.body.policy).toBe("interrupt_first");
      expect(firstInbound.body.channel).toBe("openvsmobile");
      expect(firstInbound.body.chat_id).toBe("phone");

      harness.gateway.sendOutbound("assistant_text", "mobile bridge works");

      const notification = await waitFor(
        () => harness.notifications.find((n) => n.title === "AgentM replied"),
        5000,
      );
      expect(notification.source).toBe("agentm-gateway");
      expect(notification.body).toBe("mobile bridge works");
      expect(notification.spoken?.body).toBe("mobile bridge works");
      expect(notification.reply?.target).toEqual({
        kind: "plugin",
        pluginId: "agentm-gateway",
      });

      harness.host.dispatchNotificationReply({
        pluginId: "agentm-gateway",
        notificationId: "notif-1",
        text: "reply from notification",
        event: "agentm.reply",
        context: { sessionKey: "openvsmobile:phone" },
      });

      const replyInbound = await harness.gateway.waitForFrame(
        (f) => f.kind === "inbound" && f.body.content === "reply from notification",
      );
      expect(replyInbound.session_key).toBe("openvsmobile:phone");
      expect(replyInbound.body.action).toBe("submit");

      await harness.host.shutdown();
      hostShutdown = true;
      expect(
        harness.hostLogs.some((line) => line.includes("escalating to SIGKILL")),
      ).toBe(false);
    } finally {
      if (!hostShutdown) await harness.host.shutdown();
      await harness.gateway.close();
      harness.restoreEnv();
      await rm(dirname(socketPath), { recursive: true, force: true }).catch(() => {});
    }
  });
});
