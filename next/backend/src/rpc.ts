// JSON-RPC 2.0 framing primitives + the method dispatch table + handler
// bodies. This module is transport-agnostic: it speaks JsonRpcRequest /
// JsonRpcResponse objects and knows nothing about WebSockets. See
// docs/conventions.md §1 "Method dispatch lives in rpc.ts, not in the
// transport".
//
// Layout:
//   1. Wire types + error catalog.
//   2. Frame codec (parse / send) used by connection.ts.
//   3. Param validation helpers (private).
//   4. RpcContext interface — what a handler can do to its caller.
//   5. Method table + handlers.
//   6. dispatch() + runAuthHandshake() entry points.

import type { WebSocket } from "ws";
import { listDirAt, readFileAt, type ActiveWorkspace } from "./workspace.js";
import type { ProcessState } from "./state.js";
import { diffKind, readLog, runDiff } from "./git.js";
import { parseUnifiedDiff } from "./diffParser.js";

// -------- 1. Wire types + error catalog --------

export type JsonRpcId = string | number;

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: JsonRpcId;
  method: string;
  params?: unknown;
}

export interface JsonRpcNotification {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
}

export interface JsonRpcSuccess {
  jsonrpc: "2.0";
  id: JsonRpcId;
  result: unknown;
}

export interface JsonRpcError {
  jsonrpc: "2.0";
  id: JsonRpcId | null;
  error: { code: number; message: string; data?: unknown };
}

export const RPC_ERR = {
  parse: -32700,
  invalidRequest: -32600,
  methodNotFound: -32601,
  invalidParams: -32602,
  internal: -32603,
  // Custom range (-32000 to -32099 reserved by the spec for application use)
  /// -32001: the caller has not been granted the capability they requested.
  /// Will fire from the plugin host when it lands; currently unused.
  capabilityDenied: -32001,
  /// -32002: authentication has not happened yet or the token is wrong.
  unauthorized: -32002,
  /// -32003: requested resource exists but the server is not ready to serve
  /// it yet (e.g. workspace model still initializing). Distinct from
  /// invalidParams so the client can choose to retry.
  notReady: -32003,
  /// -32004: workspace has no resident model — either because the workspace
  /// id is unknown or because model init has not completed. We use invalidParams
  /// for the unknown case (same as other workspace lookups) and notReady for
  /// the half-initialized case.
} as const;

export class RpcError extends Error {
  public readonly code: number;
  public readonly data: unknown;
  constructor(code: number, message: string, data?: unknown) {
    super(message);
    this.code = code;
    this.data = data;
  }
}

// -------- 2. Frame codec --------

export function sendNotification(
  ws: WebSocket,
  method: string,
  params: unknown,
): void {
  if (ws.readyState !== ws.OPEN) return;
  const msg: JsonRpcNotification = { jsonrpc: "2.0", method, params };
  ws.send(JSON.stringify(msg));
}

export function sendResult(
  ws: WebSocket,
  id: JsonRpcId,
  result: unknown,
): void {
  if (ws.readyState !== ws.OPEN) return;
  const msg: JsonRpcSuccess = { jsonrpc: "2.0", id, result };
  ws.send(JSON.stringify(msg));
}

export function sendError(
  ws: WebSocket,
  id: JsonRpcId | null,
  code: number,
  message: string,
  data?: unknown,
): void {
  if (ws.readyState !== ws.OPEN) return;
  const msg: JsonRpcError = {
    jsonrpc: "2.0",
    id,
    error: data === undefined ? { code, message } : { code, message, data },
  };
  ws.send(JSON.stringify(msg));
}

export function parseRequest(
  raw: string,
): { kind: "request"; req: JsonRpcRequest } | { kind: "error"; reason: string } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { kind: "error", reason: "parse" };
  }
  if (
    !parsed ||
    typeof parsed !== "object" ||
    (parsed as { jsonrpc?: unknown }).jsonrpc !== "2.0"
  ) {
    return { kind: "error", reason: "invalidRequest" };
  }
  const obj = parsed as Record<string, unknown>;
  if (typeof obj.method !== "string") {
    return { kind: "error", reason: "invalidRequest" };
  }
  if (obj.id === undefined) {
    // Notification from client — we don't accept any in v0, but parse cleanly.
    return {
      kind: "request",
      req: {
        jsonrpc: "2.0",
        id: 0,
        method: obj.method,
        params: obj.params,
      },
    };
  }
  if (typeof obj.id !== "string" && typeof obj.id !== "number") {
    return { kind: "error", reason: "invalidRequest" };
  }
  return {
    kind: "request",
    req: {
      jsonrpc: "2.0",
      id: obj.id,
      method: obj.method,
      params: obj.params,
    },
  };
}

// -------- 3. Param validation helpers --------
//
// The same shape-check pattern (`typeof p.x !== "string" → invalidParams`)
// recurs across most handlers. These helpers collapse the duplication and
// give every validation failure a consistent error message.

type ParamBag = Record<string, unknown>;

function asBag(params: unknown): ParamBag {
  if (params === undefined || params === null) return {};
  if (typeof params !== "object" || Array.isArray(params)) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      "params must be an object",
    );
  }
  return params as ParamBag;
}

function requireString(p: ParamBag, key: string): string {
  const v = p[key];
  if (typeof v !== "string" || v.length === 0) {
    throw new RpcError(RPC_ERR.invalidParams, `${key} required`);
  }
  return v;
}

function optionalString(p: ParamBag, key: string): string | undefined {
  const v = p[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "string") {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `${key} must be a string when provided`,
    );
  }
  return v;
}

function requirePositiveInt(p: ParamBag, key: string): number {
  const v = p[key];
  if (typeof v !== "number" || !Number.isInteger(v) || v < 1) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `${key} must be a positive integer`,
    );
  }
  return v;
}

function optionalNonNegativeInt(p: ParamBag, key: string): number | undefined {
  const v = p[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "number" || !Number.isInteger(v) || v < 0) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `${key} must be a non-negative int when provided`,
    );
  }
  return v;
}

function optionalBool(p: ParamBag, key: string): boolean | undefined {
  const v = p[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "boolean") {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `${key} must be a boolean when provided`,
    );
  }
  return v;
}

function optionalPositiveInt(p: ParamBag, key: string): number | undefined {
  const v = p[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "number" || !Number.isInteger(v) || v < 1) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `${key} must be a positive int when provided`,
    );
  }
  return v;
}

function optionalStringArray(p: ParamBag, key: string): string[] | undefined {
  const v = p[key];
  if (v === undefined || v === null) return undefined;
  if (!Array.isArray(v) || v.some((s) => typeof s !== "string")) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `${key} must be a string[] when provided`,
    );
  }
  return v as string[];
}

// -------- 4. RpcContext --------

/// What handlers need from the caller. Intentionally narrow: a handler can
/// see the shared `ProcessState`, send a notification back, force-close the
/// underlying transport, and (when the dispatcher is built per-connection)
/// register itself as a subscriber. The handler does not know whether the
/// transport is a WebSocket, an in-memory pipe, or a test harness.
export interface RpcContext {
  state: ProcessState;
  /// Token the caller must supply during handshake. Compared against the
  /// `token` param. Never logged.
  expectedToken: string;
  /// Server version baked at boot time. Returned from auth.handshake.
  serverVersion: string;
  /// Mark this caller as authenticated and register it as a subscriber for
  /// future broadcast notifications.
  markAuthenticated: () => void;
  /// The underlying WebSocket. Handler-only knowledge — the *dispatcher*
  /// stays transport-agnostic. Workspace subscription needs to register a
  /// per-ws subscriber against the workspace model; that's the one place a
  /// handler legitimately needs the socket handle. Tests inject a
  /// minimal stub.
  ws: WebSocket;
}

const PROTOCOL_VERSION = "1.0";

/// Method name of the one RPC the connection layer treats specially (its
/// success flips the auth bit; its failure tears down the socket). Exported
/// so the transport routes to `runAuthHandshake` without re-stating the
/// string.
export const METHOD_AUTH_HANDSHAKE = "auth.handshake";

// -------- 5. Method table + handlers --------

type Handler = (ctx: RpcContext, params: unknown) => Promise<unknown> | unknown;

const methods = new Map<string, Handler>();

methods.set("system.ping", () => ({ now: Date.now() }));

// ---- Workspace ----

methods.set("workspace.list", (ctx) => ({
  active: ctx.state.workspaces.listActive(),
  recents: ctx.state.workspaces.listRecents(),
}));

methods.set("workspace.open", async (ctx, params) => {
  const p = asBag(params);
  const activate = optionalBool(p, "activate") ?? true;
  const ws = await ctx.state.workspaces.open(p.root, { activate });
  return { workspace: ws.info() };
});

methods.set("workspace.activate", (ctx, params) => {
  const p = asBag(params);
  const ws = ctx.state.workspaces.activate(p.id);
  return { workspace: ws.info() };
});

methods.set("workspace.close", (ctx, params) => {
  const p = asBag(params);
  const id = requireString(p, "id");
  ctx.state.workspaces.close(id);
  // Broadcast to every subscriber, not just this connection. Two clients
  // sharing the same backend both deserve to know the workspace is gone.
  ctx.state.broadcastWorkspaceClosed(id);
  return {};
});

methods.set("workspace.current", (ctx) => {
  const ws = ctx.state.workspaces.current();
  return { workspace: ws ? ws.info() : null };
});

// ---- Filesystem ----

methods.set("fs.listDir", async (ctx, params) => {
  const p = asBag(params);
  if (p.picker === true) {
    const { entries, version } = await listDirAt(p.path, null);
    return { entries, version };
  }
  const ws = ctx.state.workspaces.requireById(p.workspaceId);
  const { entries, version } = await listDirAt(p.path, ws);
  return { entries, version };
});

methods.set("fs.readFile", async (ctx, params) => {
  const p = asBag(params);
  const ws = ctx.state.workspaces.requireById(p.workspaceId);
  const ifEtag = optionalString(p, "ifEtag");
  const result = await readFileAt(p.path, ws, ifEtag);
  if ("notModified" in result) {
    return { etag: result.etag, notModified: true };
  }
  return {
    etag: result.etag,
    contentBase64: result.contentBase64,
    encoding: result.encoding,
  };
});

// ---- Workspace subscription + git ----
//
// These methods drive the workspace push surface defined in
// docs/design/mobile-code-platform.md §4.1. The actual model + watcher logic
// lives in workspaceModel.ts; handlers are thin glue.

methods.set("workspace.subscribe", (ctx, params) => {
  const p = asBag(params);
  const ws = ctx.state.workspaces.requireById(p.workspaceId);
  const model = ws.model;
  if (model === null) {
    throw new RpcError(
      RPC_ERR.notReady,
      `workspace ${ws.id} model not yet initialized`,
    );
  }
  const sinceVersion = optionalNonNegativeInt(p, "sinceVersion");
  const paths = optionalStringArray(p, "paths");
  const result = model.subscribe(ctx.ws, {
    ...(sinceVersion !== undefined ? { sinceVersion } : {}),
    ...(paths !== undefined ? { paths } : {}),
  });
  // For snapshot mode, send the decoration snapshot on the next tick so the
  // subscribe RESPONSE arrives first.
  if (result.mode === "snapshot") {
    const entries = model.buildDecorationSnapshot();
    const version = result.baseVersion;
    const workspaceId = ws.id;
    const sock = ctx.ws;
    queueMicrotask(() => {
      sendNotification(sock, "workspace.decoration.snapshot", {
        workspaceId,
        entries,
        version,
      });
    });
  }
  return result;
});

methods.set("workspace.unsubscribe", (ctx, params) => {
  const p = asBag(params);
  const ws = ctx.state.workspaces.requireById(p.workspaceId);
  if (ws.model !== null) ws.model.unsubscribe(ctx.ws);
  return {};
});

methods.set("git.diff", async (ctx, params) => {
  const p = asBag(params);
  const ws = ctx.state.workspaces.requireById(p.workspaceId);
  const path = requireString(p, "path");
  const baseSha = optionalString(p, "baseSha");
  const workingHash = optionalString(p, "workingHash");
  // Cache lookup. Two requests with the same key short-circuit the spawn.
  const cacheKey = makeDiffCacheKey(ws.id, path, baseSha, workingHash);
  const cached = ctx.state.diffCache.get(cacheKey);
  if (cached !== undefined) return cached;

  const kind = await diffKind(ws.root, path, baseSha);
  let result: unknown;
  if (kind === "binary") {
    result = { kind: "binary", meta: { path } };
  } else if (kind === "deleted") {
    result = { kind: "deleted", meta: { path } };
  } else if (kind === "absent") {
    // No diff to compute — treat as text with zero hunks for the caller.
    result = { kind: "text", hunks: [] };
  } else {
    const { stdout, tooLarge } = await runDiff(ws.root, path, baseSha);
    if (tooLarge || stdout.length > DIFF_TEXT_LIMIT_BYTES) {
      result = {
        kind: "too-large",
        meta: { path, sizeBytes: stdout.length || -1 },
      };
    } else {
      result = { kind: "text", hunks: parseUnifiedDiff(stdout) };
    }
  }
  ctx.state.diffCache.set(cacheKey, result);
  return result;
});

methods.set("git.log", async (ctx, params) => {
  const p = asBag(params);
  const ws = ctx.state.workspaces.requireById(p.workspaceId);
  const path = optionalString(p, "path");
  const limit = optionalPositiveInt(p, "limit") ?? 50;
  const beforeSha = optionalString(p, "beforeSha");
  return readLog(ws.root, {
    limit,
    ...(path !== undefined ? { path } : {}),
    ...(beforeSha !== undefined ? { beforeSha } : {}),
  });
});

// Cap unified-diff text at 500KB. Beyond that we surface a `too-large` kind
// rather than ship a megabyte of patch over a phone link. The cap is
// intentionally lower than git's own maxBuffer (8 MiB) so the wire payload
// stays bounded even when git is happy to keep going.
const DIFF_TEXT_LIMIT_BYTES = 500 * 1024;

function makeDiffCacheKey(
  workspaceId: string,
  path: string,
  baseSha: string | undefined,
  workingHash: string | undefined,
): string {
  return `${workspaceId} ${path} ${baseSha ?? "WT"} ${workingHash ?? ""}`;
}

// ---- Terminal ----

methods.set("terminal.create", (ctx, params) => {
  const p = asBag(params);
  const ws = ctx.state.workspaces.requireById(p.workspaceId);
  const cols = typeof p.cols === "number" ? p.cols : 80;
  const rows = typeof p.rows === "number" ? p.rows : 24;
  const cwd =
    typeof p.cwd === "string" && p.cwd.length > 0 ? p.cwd : ws.root;
  const snap = ws.terminals.create(cols, rows, cwd);
  return { sessionId: snap.id, workspaceId: ws.id };
});

methods.set("terminal.write", (ctx, params) => {
  const p = asBag(params);
  const sessionId = requireString(p, "sessionId");
  const dataBase64 = requireString(p, "dataBase64");
  const ws = findWorkspaceOwning(ctx, sessionId);
  ws.terminals.write(sessionId, Buffer.from(dataBase64, "base64"));
  return {};
});

methods.set("terminal.resize", (ctx, params) => {
  const p = asBag(params);
  const sessionId = requireString(p, "sessionId");
  const cols = requirePositiveInt(p, "cols");
  const rows = requirePositiveInt(p, "rows");
  const ws = findWorkspaceOwning(ctx, sessionId);
  ws.terminals.resize(sessionId, cols, rows);
  return {};
});

methods.set("terminal.dispose", (ctx, params) => {
  const p = asBag(params);
  const sessionId = requireString(p, "sessionId");
  const ws = findWorkspaceOwning(ctx, sessionId);
  ws.terminals.dispose(sessionId);
  return {};
});

methods.set("terminal.list", (ctx, params) => {
  const p = asBag(params);
  if (p.workspaceId === undefined || p.workspaceId === null) {
    // No filter — return every session across every active workspace.
    return { sessions: ctx.state.listAllTerminals() };
  }
  const ws = ctx.state.workspaces.requireById(p.workspaceId);
  return {
    sessions: ws.terminals
      .list()
      .map((t) => ({ ...t, workspaceId: ws.id })),
  };
});

methods.set("terminal.history", (ctx, params) => {
  const p = asBag(params);
  const sessionId = requireString(p, "sessionId");
  const maxBytes = optionalNonNegativeInt(p, "maxBytes");
  const ws = findWorkspaceOwning(ctx, sessionId);
  return ws.terminals.history(sessionId, maxBytes);
});

function findWorkspaceOwning(
  ctx: RpcContext,
  sessionId: string,
): ActiveWorkspace {
  const ws = ctx.state.findSession(sessionId);
  if (ws === null) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `no such session: ${sessionId}`,
    );
  }
  return ws;
}

// -------- 6. Entry points --------

/// Resolve `method` on the dispatch table, validate params, run the handler.
/// Auth gating is the caller's responsibility: `connection.ts` rejects any
/// non-handshake call before reaching `dispatch` when the connection has
/// not yet authenticated.
export async function dispatch(
  ctx: RpcContext,
  req: JsonRpcRequest,
): Promise<unknown> {
  const handler = methods.get(req.method);
  if (!handler) {
    throw new RpcError(
      RPC_ERR.methodNotFound,
      `unknown method: ${req.method}`,
    );
  }
  return await handler(ctx, req.params);
}

/// Handle the `auth.handshake` method. Lives outside the regular dispatch
/// table because it carries the side effect of flipping the context's
/// authenticated bit, and a failure must terminate the transport (the client
/// has no use for a half-authenticated connection).
export function runAuthHandshake(ctx: RpcContext, rawParams: unknown): unknown {
  const p = asBag(rawParams);
  const token = optionalString(p, "token");
  if (token === undefined || token.length === 0) {
    throw new RpcError(RPC_ERR.unauthorized, "missing or invalid token");
  }
  if (token !== ctx.expectedToken) {
    throw new RpcError(RPC_ERR.unauthorized, "token mismatch");
  }
  // protocolVersion is currently informational; we just reject malformed
  // values. Future negotiation lives here.
  optionalString(p, "protocolVersion");
  ctx.markAuthenticated();
  return {
    ok: true,
    serverVersion: ctx.serverVersion,
    protocolVersion: PROTOCOL_VERSION,
    defaultCwd: process.env.HOME ?? "/",
  };
}
