// A Connection is an authenticated subscriber over a single WebSocket.
// It does NOT own workspaces or terminals — those live in the shared
// ProcessState. Closing the socket removes this subscriber but leaves all
// workspaces and PTYs running so the client can reattach on reconnect.
//
// See docs/design/mobile-code-platform.md §5.1 (Session persistence).

import type { WebSocket } from "ws";
import {
  parseRequest,
  RPC_ERR,
  RpcError,
  sendError,
  sendNotification,
  sendResult,
  type JsonRpcId,
} from "./rpc.js";
import { listDirAt, readFileAt, type ActiveWorkspace } from "./workspace.js";
import type { ProcessState, Subscriber } from "./state.js";

const SERVER_VERSION = "0.1.0";
const PROTOCOL_VERSION = "1.0";

export interface ConnectionDeps {
  expectedToken: string;
  state: ProcessState;
}

type Handler = (params: unknown) => Promise<unknown> | unknown;

export class Connection implements Subscriber {
  private authed = false;
  private readonly methods = new Map<string, Handler>();
  public readonly ws: WebSocket;
  private readonly state: ProcessState;
  private readonly expectedToken: string;

  constructor(ws: WebSocket, deps: ConnectionDeps) {
    this.ws = ws;
    this.state = deps.state;
    this.expectedToken = deps.expectedToken;
    this.register();

    ws.on("message", (raw) => {
      const text = typeof raw === "string" ? raw : raw.toString("utf8");
      this.handleRaw(text);
    });
    // Critical: socket close does NOT dispose any state. PTYs and workspaces
    // keep running. We just unhook our notification fan-out target.
    ws.on("close", () => {
      this.state.removeSubscriber(this);
    });
    ws.on("error", () => {
      this.state.removeSubscriber(this);
    });
  }

  private register(): void {
    // ---- Auth ----
    this.methods.set("auth.handshake", (params) => this.onHandshake(params));

    // ---- System ----
    // Heartbeat used by the client to detect silent NAT/carrier drops.
    this.methods.set("system.ping", () => ({ now: Date.now() }));

    // ---- Workspace ----
    this.methods.set("workspace.list", () => ({
      active: this.state.workspaces.listActive(),
      recents: this.state.workspaces.listRecents(),
    }));
    this.methods.set("workspace.open", async (params) => {
      const p = (params as
        | { root?: unknown; activate?: unknown }
        | undefined) ?? {};
      let activate = true;
      if (p.activate !== undefined) {
        if (typeof p.activate !== "boolean") {
          throw new RpcError(
            RPC_ERR.invalidParams,
            "activate must be a boolean when provided",
          );
        }
        activate = p.activate;
      }
      const ws = await this.state.workspaces.open(p.root, { activate });
      return { workspace: ws.info() };
    });
    this.methods.set("workspace.activate", (params) => {
      const id = (params as { id?: unknown } | undefined)?.id;
      const ws = this.state.workspaces.activate(id);
      return { workspace: ws.info() };
    });
    this.methods.set("workspace.close", (params) => {
      const id = (params as { id?: unknown } | undefined)?.id;
      if (typeof id !== "string") {
        throw new RpcError(RPC_ERR.invalidParams, "id required");
      }
      this.state.workspaces.close(id);
      // Broadcast to every subscriber, not just this connection. Two clients
      // sharing the same backend both deserve to know the workspace is gone.
      this.state.broadcastWorkspaceClosed(id);
      return {};
    });
    this.methods.set("workspace.current", () => {
      const ws = this.state.workspaces.current();
      return { workspace: ws ? ws.info() : null };
    });

    // ---- Filesystem ----
    this.methods.set("fs.listDir", async (params) => {
      const p = (params as
        | { workspaceId?: unknown; path?: unknown; picker?: unknown }
        | undefined) ?? {};
      if (p.picker === true) {
        const { entries } = await listDirAt(p.path, null);
        return { entries };
      }
      const ws = this.state.workspaces.requireById(p.workspaceId);
      const { entries } = await listDirAt(p.path, ws);
      return { entries };
    });
    this.methods.set("fs.readFile", async (params) => {
      const p = (params as
        | { workspaceId?: unknown; path?: unknown }
        | undefined) ?? {};
      const ws = this.state.workspaces.requireById(p.workspaceId);
      const { contentBase64, encoding } = await readFileAt(p.path, ws);
      return { contentBase64, encoding };
    });

    // ---- Terminal ----
    this.methods.set("terminal.create", (params) => {
      const p = (params as
        | {
            workspaceId?: unknown;
            cols?: unknown;
            rows?: unknown;
            cwd?: unknown;
          }
        | undefined) ?? {};
      const ws = this.state.workspaces.requireById(p.workspaceId);
      const cols = typeof p.cols === "number" ? p.cols : 80;
      const rows = typeof p.rows === "number" ? p.rows : 24;
      const cwd =
        typeof p.cwd === "string" && p.cwd.length > 0 ? p.cwd : ws.root;
      const snap = ws.terminals.create(cols, rows, cwd);
      return { sessionId: snap.id, workspaceId: ws.id };
    });
    this.methods.set("terminal.write", (params) => {
      const p = (params as
        | { sessionId?: unknown; dataBase64?: unknown }
        | undefined) ?? {};
      if (typeof p.sessionId !== "string") {
        throw new RpcError(RPC_ERR.invalidParams, "sessionId required");
      }
      if (typeof p.dataBase64 !== "string") {
        throw new RpcError(RPC_ERR.invalidParams, "dataBase64 required");
      }
      const ws = this.findWorkspaceOwning(p.sessionId);
      ws.terminals.write(p.sessionId, Buffer.from(p.dataBase64, "base64"));
      return {};
    });
    this.methods.set("terminal.resize", (params) => {
      const p = (params as
        | { sessionId?: unknown; cols?: unknown; rows?: unknown }
        | undefined) ?? {};
      if (typeof p.sessionId !== "string") {
        throw new RpcError(RPC_ERR.invalidParams, "sessionId required");
      }
      if (typeof p.cols !== "number" || typeof p.rows !== "number") {
        throw new RpcError(RPC_ERR.invalidParams, "cols and rows required");
      }
      const ws = this.findWorkspaceOwning(p.sessionId);
      ws.terminals.resize(p.sessionId, p.cols, p.rows);
      return {};
    });
    this.methods.set("terminal.dispose", (params) => {
      const p = (params as { sessionId?: unknown } | undefined) ?? {};
      if (typeof p.sessionId !== "string") {
        throw new RpcError(RPC_ERR.invalidParams, "sessionId required");
      }
      const ws = this.findWorkspaceOwning(p.sessionId);
      ws.terminals.dispose(p.sessionId);
      return {};
    });
    this.methods.set("terminal.list", (params) => {
      const p = (params as { workspaceId?: unknown } | undefined) ?? {};
      if (p.workspaceId === undefined || p.workspaceId === null) {
        // No filter — return every session across every active workspace.
        const out: Array<unknown> = [];
        for (const info of this.state.workspaces.listActive()) {
          const ws = this.state.workspaces.get(info.id);
          for (const t of ws.terminals.list()) {
            out.push({ ...t, workspaceId: ws.id });
          }
        }
        return { sessions: out };
      }
      const ws = this.state.workspaces.requireById(p.workspaceId);
      return {
        sessions: ws.terminals
          .list()
          .map((t) => ({ ...t, workspaceId: ws.id })),
      };
    });
    this.methods.set("terminal.history", (params) => {
      const p = (params as
        | { sessionId?: unknown; maxBytes?: unknown }
        | undefined) ?? {};
      if (typeof p.sessionId !== "string") {
        throw new RpcError(RPC_ERR.invalidParams, "sessionId required");
      }
      let maxBytes: number | undefined;
      if (p.maxBytes !== undefined && p.maxBytes !== null) {
        if (!Number.isInteger(p.maxBytes) || (p.maxBytes as number) < 0) {
          throw new RpcError(
            RPC_ERR.invalidParams,
            "maxBytes must be a non-negative int when provided",
          );
        }
        maxBytes = p.maxBytes as number;
      }
      const ws = this.findWorkspaceOwning(p.sessionId);
      return ws.terminals.history(p.sessionId, maxBytes);
    });
  }

  private findWorkspaceOwning(sessionId: string): ActiveWorkspace {
    const ws = this.state.findSession(sessionId);
    if (ws === null) {
      throw new RpcError(RPC_ERR.invalidParams, `no such session: ${sessionId}`);
    }
    return ws;
  }

  private async handleRaw(raw: string): Promise<void> {
    const parsed = parseRequest(raw);
    if (parsed.kind === "error") {
      const code =
        parsed.reason === "parse" ? RPC_ERR.parse : RPC_ERR.invalidRequest;
      sendError(this.ws, null, code, parsed.reason);
      return;
    }
    const { id, method, params } = parsed.req;
    if (!this.authed && method !== "auth.handshake") {
      sendError(this.ws, id, RPC_ERR.unauthorized, "handshake required");
      return;
    }
    const handler = this.methods.get(method);
    if (!handler) {
      sendError(this.ws, id, RPC_ERR.methodNotFound, `unknown method: ${method}`);
      return;
    }
    try {
      const result = await handler(params);
      sendResult(this.ws, id, result);
    } catch (err) {
      this.replyError(id, err);
    }
  }

  private replyError(id: JsonRpcId, err: unknown): void {
    if (err instanceof RpcError) {
      sendError(this.ws, id, err.code, err.message, err.data);
      return;
    }
    const message = err instanceof Error ? err.message : String(err);
    sendError(this.ws, id, RPC_ERR.internal, message);
  }

  private onHandshake(rawParams: unknown): unknown {
    const p = (rawParams as
      | { token?: unknown; protocolVersion?: unknown; client?: unknown }
      | undefined) ?? {};
    if (typeof p.token !== "string" || p.token.length === 0) {
      setImmediate(() => this.ws.close(1008, "auth"));
      throw new RpcError(RPC_ERR.unauthorized, "missing or invalid token");
    }
    if (p.token !== this.expectedToken) {
      setImmediate(() => this.ws.close(1008, "auth"));
      throw new RpcError(RPC_ERR.unauthorized, "token mismatch");
    }
    if (
      p.protocolVersion !== undefined &&
      typeof p.protocolVersion !== "string"
    ) {
      throw new RpcError(
        RPC_ERR.invalidParams,
        "protocolVersion must be a string when provided",
      );
    }
    this.authed = true;
    // Register as a subscriber only after auth succeeds; pre-auth sockets
    // must never receive notifications.
    this.state.addSubscriber(this);
    return {
      ok: true,
      serverVersion: SERVER_VERSION,
      protocolVersion: PROTOCOL_VERSION,
      defaultCwd: process.env.HOME ?? "/",
    };
  }
}

// Notification helpers — kept exported because the smoke script and tests
// occasionally use them for assertions when wired against a real connection.
export { sendNotification };
