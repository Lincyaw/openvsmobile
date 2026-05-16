// One connection = one workspace registry. Multiple active workspaces
// per connection, each with its own PTY pool. Terminal notifications
// always carry workspaceId so the client can route them to the right
// (focused or background) view.

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
import {
  WorkspaceRegistry,
  listDirAt,
  readFileAt,
  type ActiveWorkspace,
} from "./workspace.js";

const SERVER_VERSION = "0.1.0";
const PROTOCOL_VERSION = "1.0";

export interface ConnectionDeps {
  expectedToken: string;
}

type Handler = (params: unknown) => Promise<unknown> | unknown;

export class Connection {
  private authed = false;
  private readonly workspaces: WorkspaceRegistry;
  private readonly methods = new Map<string, Handler>();

  constructor(
    private readonly ws: WebSocket,
    private readonly deps: ConnectionDeps,
  ) {
    // The data/exit sinks need workspace ids on the wire. We capture the
    // workspace id inside the per-workspace TerminalRegistry by giving each
    // workspace a closure that already knows its own id.
    //
    // The WorkspaceRegistry below builds those closures lazily, but the
    // registry itself only needs raw "(sessionId, data) -> void" sinks
    // *with* workspaceId baked in. Easiest path: have the registry accept a
    // factory it can call per-workspace.
    //
    // Rather than reshape the registry contract, we go via a thin lookup —
    // when output arrives we ask which workspace owns this sessionId.
    this.workspaces = new WorkspaceRegistry(
      (sessionId, data) => {
        const wsId = this.workspaceIdForTerminal(sessionId);
        if (wsId === null) return;
        sendNotification(this.ws, "terminal.data", {
          sessionId,
          workspaceId: wsId,
          dataBase64: data.toString("base64"),
        });
      },
      (sessionId, exitCode) => {
        const wsId = this.workspaceIdForTerminal(sessionId);
        sendNotification(this.ws, "terminal.exit", {
          sessionId,
          workspaceId: wsId, // may be null if the workspace was just closed
          exitCode,
        });
      },
    );

    this.register();

    ws.on("message", (raw) => {
      const text = typeof raw === "string" ? raw : raw.toString("utf8");
      this.handleRaw(text);
    });
    ws.on("close", () => {
      this.workspaces.disposeAll();
    });
    ws.on("error", () => {
      this.workspaces.disposeAll();
    });
  }

  private workspaceIdForTerminal(sessionId: string): string | null {
    for (const info of this.workspaces.listActive()) {
      const ws = this.workspaces.get(info.id);
      if (ws.terminals.has(sessionId)) return ws.id;
    }
    // Terminal already removed from its registry — still report best-effort.
    return null;
  }

  private register(): void {
    // ---- Auth ----
    this.methods.set("auth.handshake", (params) => this.onHandshake(params));

    // ---- Workspace ----
    this.methods.set("workspace.list", () => ({
      active: this.workspaces.listActive(),
      recents: this.workspaces.listRecents(),
    }));
    this.methods.set("workspace.open", async (params) => {
      const root = (params as { root?: unknown } | undefined)?.root;
      const ws = await this.workspaces.open(root);
      return { workspace: ws.info() };
    });
    this.methods.set("workspace.activate", (params) => {
      const id = (params as { id?: unknown } | undefined)?.id;
      const ws = this.workspaces.activate(id);
      return { workspace: ws.info() };
    });
    this.methods.set("workspace.close", (params) => {
      const id = (params as { id?: unknown } | undefined)?.id;
      if (typeof id !== "string") {
        throw new RpcError(RPC_ERR.invalidParams, "id required");
      }
      this.workspaces.close(id);
      // Tell the client too — this primarily exists for server-initiated
      // closes on shutdown, but echoing it on user-initiated close keeps
      // the client's reactive code paths uniform.
      sendNotification(this.ws, "workspace.closed", { id });
      return {};
    });
    this.methods.set("workspace.current", () => {
      const ws = this.workspaces.current();
      return { workspace: ws ? ws.info() : null };
    });

    // ---- Filesystem ----
    // fs.listDir has two shapes:
    //   { workspaceId, path }       — path must be inside that workspace
    //   { path, picker: true }      — workspace-less, OS-scoped (picker only)
    this.methods.set("fs.listDir", async (params) => {
      const p = (params as
        | { workspaceId?: unknown; path?: unknown; picker?: unknown }
        | undefined) ?? {};
      if (p.picker === true) {
        const { entries } = await listDirAt(p.path);
        return { entries };
      }
      const ws = this.workspaces.requireById(p.workspaceId);
      const { resolved, entries } = await listDirAt(p.path);
      ws.assertContains(resolved);
      return { entries };
    });
    this.methods.set("fs.readFile", async (params) => {
      const p = (params as
        | { workspaceId?: unknown; path?: unknown }
        | undefined) ?? {};
      const ws = this.workspaces.requireById(p.workspaceId);
      const { resolved, contentBase64, encoding } = await readFileAt(p.path);
      ws.assertContains(resolved);
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
      const ws = this.workspaces.requireById(p.workspaceId);
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
        for (const info of this.workspaces.listActive()) {
          const ws = this.workspaces.get(info.id);
          for (const t of ws.terminals.list()) {
            out.push({ ...t, workspaceId: ws.id });
          }
        }
        return { sessions: out };
      }
      const ws = this.workspaces.requireById(p.workspaceId);
      return {
        sessions: ws.terminals
          .list()
          .map((t) => ({ ...t, workspaceId: ws.id })),
      };
    });
  }

  private findWorkspaceOwning(sessionId: string): ActiveWorkspace {
    for (const info of this.workspaces.listActive()) {
      const ws = this.workspaces.get(info.id);
      if (ws.terminals.has(sessionId)) return ws;
    }
    throw new RpcError(RPC_ERR.invalidParams, `no such session: ${sessionId}`);
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
    if (p.token !== this.deps.expectedToken) {
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
    return {
      ok: true,
      serverVersion: SERVER_VERSION,
      protocolVersion: PROTOCOL_VERSION,
    };
  }
}
