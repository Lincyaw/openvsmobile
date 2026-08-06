// End-to-end smoke for the Codex app-server example plugin.
//
// A real RFC 6455 server verifies the plugin's built-in-only WebSocket client,
// including bearer headers. PluginHost then exercises the complete bridge:
// app input -> thread/turn RPCs, Codex deltas -> native panel + notification,
// and server approval request -> native alert -> JSON-RPC response.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { WebSocket as RpcWebSocket } from "ws";
import { WebSocket, WebSocketServer } from "ws";
import http from "node:http";
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { FakeWebSocket, makeTempDir, rmTempDir, sleep } from "./_helpers.js";
import { dispatch, type RpcContext } from "../src/rpc.js";
import { ProcessState } from "../src/state.js";
import { PluginHost } from "../src/plugins/host.js";
import type { NotificationInput } from "../src/notifications.js";

const THIS_FILE_DIR = dirname(fileURLToPath(import.meta.url));
const EXAMPLE_CODEX_DIR = resolve(
  THIS_FILE_DIR,
  "..",
  "..",
  "examples",
  "plugins",
  "codex-client",
);

type JsonObject = Record<string, unknown>;

let staging: string | null = null;

beforeEach(async () => {
  staging = await makeTempDir("openvsmobile-codex-plugin-");
});

afterEach(async () => {
  if (staging !== null) {
    await rmTempDir(staging);
    staging = null;
  }
});

async function waitFor<T>(
  predicate: () => T | undefined | Promise<T | undefined>,
  budgetMs = 5_000,
  stepMs = 25,
): Promise<T> {
  const deadline = Date.now() + budgetMs;
  while (Date.now() < deadline) {
    const value = await predicate();
    if (value !== undefined) return value;
    await sleep(stepMs);
  }
  const value = await predicate();
  if (value !== undefined) return value;
  throw new Error(`waitFor timed out after ${budgetMs}ms`);
}

function testThread(id = "thread-1"): JsonObject {
  return {
    id,
    name: null,
    preview: "Mobile Codex smoke",
    updatedAt: Math.floor(Date.now() / 1_000),
    turns: [],
  };
}

class FakeCodexAppServer {
  private server: http.Server | null = null;
  private wss: WebSocketServer | null = null;
  private socket: WebSocket | null = null;
  public endpoint = "";
  public authorization = "";
  public readonly messages: JsonObject[] = [];

  async start(): Promise<void> {
    this.server = http.createServer((_req, res) => {
      res.writeHead(404).end();
    });
    this.wss = new WebSocketServer({ noServer: true });
    this.server.on("upgrade", (req, socket, head) => {
      this.authorization = String(req.headers.authorization ?? "");
      this.wss?.handleUpgrade(req, socket, head, (ws) => {
        this.wss?.emit("connection", ws, req);
      });
    });
    this.wss.on("connection", (socket) => {
      this.socket = socket;
      socket.on("message", (data) => {
        const message = JSON.parse(data.toString("utf8")) as JsonObject;
        this.messages.push(message);
        this.handle(message);
      });
    });
    await new Promise<void>((resolveListen, reject) => {
      this.server?.once("error", reject);
      this.server?.listen(0, "127.0.0.1", () => resolveListen());
    });
    const address = this.server.address();
    if (address === null || typeof address === "string") {
      throw new Error("fake Codex server did not bind a TCP port");
    }
    this.endpoint = `ws://127.0.0.1:${address.port}`;
  }

  private handle(message: JsonObject): void {
    const id = message.id;
    const method = message.method;
    if (typeof id !== "number" || typeof method !== "string") return;
    switch (method) {
      case "initialize":
        this.send({
          id,
          result: {
            userAgent: "codex-cli/test",
            platformFamily: "unix",
            platformOs: "linux",
          },
        });
        break;
      case "thread/list":
        this.send({
          id,
          result: { data: [], nextCursor: null, backwardsCursor: null },
        });
        break;
      case "thread/start":
        this.send({ id, result: { thread: testThread() } });
        break;
      case "turn/start":
        this.send({
          id,
          result: {
            turn: { id: "turn-1", items: [], status: "inProgress" },
          },
        });
        break;
      default:
        this.send({ id, result: {} });
        break;
    }
  }

  send(message: JsonObject): void {
    if (this.socket?.readyState !== WebSocket.OPEN) {
      throw new Error("fake Codex WebSocket is not open");
    }
    this.socket.send(JSON.stringify(message));
  }

  async waitForMessage(
    predicate: (message: JsonObject) => boolean,
  ): Promise<JsonObject> {
    return waitFor(() => this.messages.find(predicate));
  }

  async close(): Promise<void> {
    this.socket?.close();
    await new Promise<void>((resolveClose) => {
      if (this.wss === null) {
        resolveClose();
        return;
      }
      this.wss.close(() => resolveClose());
    });
    await new Promise<void>((resolveClose) => {
      if (this.server === null) {
        resolveClose();
        return;
      }
      this.server.close(() => resolveClose());
    });
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

function findNodeById(
  node: unknown,
  id: string,
): Record<string, unknown> | undefined {
  if (node === null || typeof node !== "object") return undefined;
  const current = node as Record<string, unknown>;
  if (current.id === id) return current;
  for (const key of ["children", "items"]) {
    const children = current[key];
    if (!Array.isArray(children)) continue;
    for (const child of children) {
      const found = findNodeById(child, id);
      if (found !== undefined) return found;
    }
  }
  return undefined;
}

async function buildHarness(server: FakeCodexAppServer): Promise<{
  host: PluginHost;
  ctx: RpcContext;
  socket: FakeWebSocket;
  notifications: NotificationInput[];
  restoreEnv: () => void;
}> {
  if (staging === null) throw new Error("staging dir not set up");
  const pluginsDir = join(staging, "plugins");
  const logDir = join(staging, "logs");
  const credentialFile = join(staging, "codex.credential");
  await mkdir(pluginsDir, { recursive: true });
  await mkdir(logDir, { recursive: true });
  await cp(EXAMPLE_CODEX_DIR, join(pluginsDir, "codex-client"), {
    recursive: true,
  });
  await writeFile(credentialFile, "test-capability-token\n", { mode: 0o600 });

  const oldConnect = process.env.OPENVSMOBILE_PLUGIN_CODEX_CONNECT;
  const oldCredential = process.env.OPENVSMOBILE_PLUGIN_CODEX_CREDENTIAL_FILE;
  process.env.OPENVSMOBILE_PLUGIN_CODEX_CONNECT = server.endpoint;
  process.env.OPENVSMOBILE_PLUGIN_CODEX_CREDENTIAL_FILE = credentialFile;
  const restoreEnv = () => {
    if (oldConnect === undefined)
      delete process.env.OPENVSMOBILE_PLUGIN_CODEX_CONNECT;
    else process.env.OPENVSMOBILE_PLUGIN_CODEX_CONNECT = oldConnect;
    if (oldCredential === undefined) {
      delete process.env.OPENVSMOBILE_PLUGIN_CODEX_CREDENTIAL_FILE;
    } else {
      process.env.OPENVSMOBILE_PLUGIN_CODEX_CREDENTIAL_FILE = oldCredential;
    }
  };

  const notifications: NotificationInput[] = [];
  const host = new PluginHost({
    pluginsDir,
    logDir,
    killGraceMs: 500,
    logger: () => {},
    onHostLog: () => {},
    workspaceResolver: () => ({
      id: "workspace-1",
      root: "/work/mobile",
      label: "mobile",
    }),
    notificationPublisher: (input) => {
      notifications.push(input);
      return { id: `notification-${notifications.length}` };
    },
  });
  const state = new ProcessState({
    pluginHost: host,
    notificationDbPath: join(staging, "notifications.db"),
    tokensDbPath: join(staging, "tokens.db"),
  });
  const socket = new FakeWebSocket();
  const ctx: RpcContext = {
    state,
    expectedToken: "test-token",
    serverVersion: "0.0.0-test",
    ws: socket as unknown as RpcWebSocket,
    markAuthenticated: () => {},
  };
  await host.start();
  await call(ctx, "ui.subscribe");
  return { host, ctx, socket, notifications, restoreEnv };
}

describe("examples/plugins/codex-client", () => {
  it("bridges authenticated turns, streaming output, notifications, and approvals", async () => {
    const server = new FakeCodexAppServer();
    await server.start();
    const harness = await buildHarness(server);
    try {
      await server
        .waitForMessage((message) => message.method === "initialized")
        .catch(async (err) => {
          const log = await readFile(
            join(staging ?? "", "logs", "codex-client.stderr.log"),
            "utf8",
          ).catch(() => "<no plugin stderr>");
          throw new Error(`${String(err)}\n${log}`);
        });
      expect(server.authorization).toBe("Bearer test-capability-token");

      const connectedPanel = await waitFor(() => {
        const panel = harness.host.ui
          .activePanels()
          .find((candidate) => candidate.pluginId === "codex-client");
        if (findNodeById(panel?.tree, "codex-status")?.title !== "Connected") {
          return undefined;
        }
        return panel;
      });
      expect(
        findNodeById(connectedPanel.tree, "codex-cwd")?.text,
      ).toBeUndefined();

      await call(harness.ctx, "ui.event", {
        pluginId: "codex-client",
        panelId: "chat",
        nodeId: "codex-input",
        type: "changed",
        payload: { value: "Inspect the repository" },
      });
      await call(harness.ctx, "ui.event", {
        pluginId: "codex-client",
        panelId: "chat",
        nodeId: "codex-send",
        type: "tap",
      });

      const threadStart = await server.waitForMessage(
        (message) => message.method === "thread/start",
      );
      expect((threadStart.params as JsonObject).cwd).toBe("/work/mobile");
      expect((threadStart.params as JsonObject).approvalPolicy).toBe(
        "on-request",
      );
      expect((threadStart.params as JsonObject).sandbox).toBe(
        "workspace-write",
      );

      const turnStart = await server.waitForMessage(
        (message) => message.method === "turn/start",
      );
      const turnParams = turnStart.params as JsonObject;
      expect(turnParams.threadId).toBe("thread-1");
      expect(turnParams.input).toEqual([
        { type: "text", text: "Inspect the repository", text_elements: [] },
      ]);

      server.send({
        method: "item/agentMessage/delta",
        params: {
          threadId: "thread-1",
          turnId: "turn-1",
          itemId: "assistant-1",
          delta: "Repository inspection complete.",
        },
      });
      server.send({
        method: "turn/completed",
        params: {
          threadId: "thread-1",
          turn: {
            id: "turn-1",
            status: "completed",
            items: [
              {
                type: "agentMessage",
                id: "assistant-1",
                text: "Repository inspection complete.",
              },
            ],
          },
        },
      });

      const finalPanel = await waitFor(() => {
        const panel = harness.host.ui
          .activePanels()
          .find((candidate) => candidate.pluginId === "codex-client");
        const markdown = findNodeById(
          panel?.tree,
          "message-assistant-1-body",
        )?.markdown;
        return markdown === "Repository inspection complete."
          ? panel
          : undefined;
      });
      expect(
        findNodeById(finalPanel.tree, "codex-active-turn"),
      ).toBeUndefined();
      const notification = await waitFor(() =>
        harness.notifications.find(
          (candidate) => candidate.title === "Codex replied",
        ),
      );
      expect(notification.body).toBe("Repository inspection complete.");
      expect(notification.reply?.placeholder).toBe("Reply to Codex");

      server.send({
        id: 900,
        method: "item/commandExecution/requestApproval",
        params: {
          threadId: "thread-1",
          turnId: "turn-2",
          itemId: "command-1",
          startedAtMs: Date.now(),
          command: "pnpm test",
          cwd: "/work/mobile",
          reason: "Run the test suite",
        },
      });
      const modal = await waitFor(() => {
        const match = harness.socket
          .notifications("ui.modal")
          .find((candidate) => {
            const params = candidate.params as JsonObject;
            const alert = params.alert as JsonObject | undefined;
            return alert?.id === "codex-approval-1";
          });
        return match;
      });
      const modalParams = modal.params as JsonObject;
      expect((modalParams.alert as JsonObject).title).toBe(
        "Allow this command?",
      );

      await call(harness.ctx, "ui.event", {
        pluginId: "codex-client",
        panelId: "chat",
        nodeId: "codex-approval-1",
        type: "approval:1:accept",
      });
      const approval = await server.waitForMessage(
        (message) => message.id === 900 && message.result !== undefined,
      );
      expect(approval.result).toEqual({ decision: "accept" });
    } finally {
      harness.host.shutdown();
      harness.restoreEnv();
      await server.close();
    }
  });
});
