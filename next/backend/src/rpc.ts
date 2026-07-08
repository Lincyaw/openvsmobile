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
import { listDirAt, readFileAt } from "./workspace.js";
import type { ProcessState, Subscriber } from "./state.js";
import { findFiles } from "./findFiles.js";
import { PluginHostError } from "./plugins/host.js";
import { safeSend } from "./wsSend.js";
import { register as registerGitHandlers } from "./rpcHandlers/gitHandlers.js";
import { register as registerAgentHookHandlers } from "./rpcHandlers/agentHookHandlers.js";
import { register as registerNotificationHandlers } from "./rpcHandlers/notificationHandlers.js";
import { register as registerPublishTokenHandlers } from "./rpcHandlers/publishTokenHandlers.js";

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
  /// Reserved for the runtime-revocation path (declared-but-revoked capability)
  /// that will surface from `src/plugins/host.ts` once C2 lands. The
  /// manifest-never-declared path uses -32011 (`capabilityNotDeclared`)
  /// instead. Currently no call sites — leave defined so the wire contract
  /// is stable when C2 ships.
  capabilityDenied: -32001,
  /// -32002: authentication has not happened yet or the token is wrong.
  unauthorized: -32002,
  /// -32003: requested resource exists but the server is not ready to serve
  /// it yet (e.g. workspace model still initializing). Distinct from
  /// invalidParams so the client can choose to retry.
  notReady: -32003,
  /// -32011: a plugin called a host RPC that requires a capability it
  /// did not declare in `plugin.json`. Distinct from -32001
  /// (`capabilityDenied`, reserved for runtime denials after a
  /// declared-but-revoked capability lands in C2); -32011 specifically
  /// means "the manifest never asked for this". See
  /// docs/design/mobile-code-platform.md §3.2 and CLAUDE.md.
  capabilityNotDeclared: -32011,
  // -32010..-32019 was speculatively reserved for the notification
  // namespace; only -32010 (`notificationNotFound`) ever landed there
  // and it has since been removed. The plugin host now uses -32011 per
  // §3.2 of the design doc. Re-add a notification code here if a future
  // RPC needs the distinction.
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
  safeSend(ws, JSON.stringify(msg));
}

export function sendResult(
  ws: WebSocket,
  id: JsonRpcId,
  result: unknown,
): void {
  if (ws.readyState !== ws.OPEN) return;
  const msg: JsonRpcSuccess = { jsonrpc: "2.0", id, result };
  safeSend(ws, JSON.stringify(msg));
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
  safeSend(ws, JSON.stringify(msg));
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

export type ParamBag = Record<string, unknown>;

export function asBag(params: unknown): ParamBag {
  if (params === undefined || params === null) return {};
  if (typeof params !== "object" || Array.isArray(params)) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      "params must be an object",
    );
  }
  return params as ParamBag;
}

export function requireString(p: ParamBag, key: string): string {
  const v = p[key];
  if (typeof v !== "string" || v.length === 0) {
    throw new RpcError(RPC_ERR.invalidParams, `${key} required`);
  }
  return v;
}

export function optionalString(p: ParamBag, key: string): string | undefined {
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

export function requirePositiveInt(p: ParamBag, key: string): number {
  const v = p[key];
  if (typeof v !== "number" || !Number.isInteger(v) || v < 1) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `${key} must be a positive integer`,
    );
  }
  return v;
}

export function optionalNonNegativeInt(p: ParamBag, key: string): number | undefined {
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

export function optionalPositiveInt(p: ParamBag, key: string): number | undefined {
  const v = p[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "number" || !Number.isInteger(v) || v < 1) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `${key} must be a positive integer when provided`,
    );
  }
  return v;
}

export function optionalBool(p: ParamBag, key: string): boolean | undefined {
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

export function optionalStringArray(p: ParamBag, key: string): string[] | undefined {
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
  /// The Subscriber object for the caller's WebSocket. Present on every
  /// authenticated dispatch; absent only during the pre-auth handshake (the
  /// connection layer doesn't register a subscriber until `markAuthenticated`
  /// fires). Per-connection notification subscription state and `deviceId`
  /// live on this object — see state.ts:Subscriber.
  subscriber?: Subscriber;
}

const PROTOCOL_VERSION = "1.0";

/// Method name of the one RPC the connection layer treats specially (its
/// success flips the auth bit; its failure tears down the socket). Exported
/// so the transport routes to `runAuthHandshake` without re-stating the
/// string.
export const METHOD_AUTH_HANDSHAKE = "auth.handshake";

// -------- 5. Method table + handlers --------

export type Handler = (ctx: RpcContext, params: unknown) => Promise<unknown> | unknown;

/// Extracted-handler modules call `register(methods)` with a writer-shaped
/// view over the internal map. Keeps the registration API narrow (no
/// peeking, no clearing, no re-binding) while letting the methods table
/// itself stay private.
export interface MethodRegistry {
  set(name: string, handler: Handler): void;
}

const methods = new Map<string, Handler>();

// Extracted handler groups. Done at module load so the dispatch table is
// fully populated before the first call. Import order: rpc.ts → handlers
// → back to rpc.ts (for helpers / types). No cycles because the handler
// modules only `import type` from rpc.ts's downstream deps; the runtime
// imports (`asBag`, `RpcError`, …) are leaves.
registerGitHandlers(methods);
registerAgentHookHandlers(methods);
registerNotificationHandlers(methods);
registerPublishTokenHandlers(methods);

methods.set("system.ping", () => ({ now: Date.now() }));

// ---- Workspace ----

methods.set("workspace.list", (ctx) => ({
  active: ctx.state.workspaces.listActive(),
  recents: ctx.state.workspaces.listRecents(),
}));

methods.set("workspace.open", async (ctx, params) => {
  const p = asBag(params);
  const activate = optionalBool(p, "activate") ?? true;
  const reuseExisting = optionalBool(p, "reuseExisting") ?? false;
  const ws = await ctx.state.workspaces.open(p.root, {
    activate,
    reuseExisting,
  });
  return { workspace: ws.info() };
});

methods.set("workspace.forgetRecent", (ctx, params) => {
  const p = asBag(params);
  return { recents: ctx.state.workspaces.forgetRecent(p.root) };
});

methods.set("workspace.clearRecents", (ctx) => ({
  recents: ctx.state.workspaces.clearRecents(),
}));

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

/// File-name fuzzy search. Pure pull RPC — see findFiles.ts for the walker
/// + scorer + scope-safety posture.
methods.set("workspace.findFiles", async (ctx, params) => {
  const p = asBag(params);
  const ws = ctx.state.workspaces.requireById(p.workspaceId);
  const query = requireString(p, "query");
  const rawLimit = optionalPositiveInt(p, "limit") ?? 50;
  // Hard ceiling at 200. A single mobile result list past that is unusable
  // and the walker pays for every candidate it scores.
  const limit = Math.min(rawLimit, 200);
  const includeIgnored = optionalBool(p, "includeIgnored") ?? false;
  return findFiles(ws.root, { query, limit, includeIgnored });
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
  // SubscribeRequest fields are optional; with exactOptionalPropertyTypes
  // off (tsconfig) we can pass `undefined` directly without the conditional-
  // spread dance.
  const result = model.subscribe(ctx.ws, { sinceVersion, paths });
  // For snapshot mode, send the decoration snapshot on the next tick so the
  // subscribe RESPONSE arrives first. Also seed the client's branch state
  // via `head.changed`: the drain loop only fires on *changes*, so without
  // this a fresh subscribe never learns the current branch and the client
  // permanently renders "Not a git repository". For non-git workspaces
  // `currentHead()` returns null and the push is skipped.
  if (result.mode === "snapshot") {
    const entries = model.buildDecorationSnapshot();
    const version = result.baseVersion;
    const workspaceId = ws.id;
    const sock = ctx.ws;
    const head = model.currentHead();
    queueMicrotask(() => {
      sendNotification(sock, "workspace.decoration.snapshot", {
        workspaceId,
        entries,
        version,
      });
      if (head !== null) {
        sendNotification(sock, "workspace.head.changed", {
          workspaceId,
          branch: head.branch,
          headSha: head.headSha,
          ahead: head.ahead,
          behind: head.behind,
          version,
        });
      }
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


// git.* handlers live in ./rpcHandlers/gitHandlers.ts (registered below).

// ---- Terminal ----

methods.set("terminal.create", (ctx, params) => {
  const p = asBag(params);
  const workspaceId = optionalString(p, "workspaceId");
  const ws =
    workspaceId === undefined
      ? ctx.state.workspaces.current()
      : ctx.state.workspaces.requireById(workspaceId);
  const cols = typeof p.cols === "number" ? p.cols : 80;
  const rows = typeof p.rows === "number" ? p.rows : 24;
  const cwd =
    typeof p.cwd === "string" && p.cwd.length > 0
      ? p.cwd
      : (ws?.root ?? process.env.HOME ?? "/");
  const snap = ctx.state.terminals.createWithWorkspaceRoot(
    cols,
    rows,
    cwd,
    workspaceId === undefined ? null : ws?.root,
  );
  return {
    sessionId: snap.id,
    workspaceId: ctx.state.workspaceIdForRoot(snap.workspaceRoot),
    ...snap,
  };
});

methods.set("terminal.write", (ctx, params) => {
  const p = asBag(params);
  const sessionId = requireString(p, "sessionId");
  const dataBase64 = requireString(p, "dataBase64");
  findTerminal(ctx, sessionId);
  ctx.state.terminals.write(sessionId, Buffer.from(dataBase64, "base64"));
  return {};
});

methods.set("terminal.resize", (ctx, params) => {
  const p = asBag(params);
  const sessionId = requireString(p, "sessionId");
  const cols = requirePositiveInt(p, "cols");
  const rows = requirePositiveInt(p, "rows");
  findTerminal(ctx, sessionId);
  ctx.state.terminals.resize(sessionId, cols, rows);
  return {};
});

methods.set("terminal.detach", (ctx, params) => {
  const p = asBag(params);
  const sessionId = requireString(p, "sessionId");
  findTerminal(ctx, sessionId);
  ctx.state.terminals.detach(sessionId);
  return {};
});

methods.set("terminal.rename", (ctx, params) => {
  const p = asBag(params);
  const sessionId = requireString(p, "sessionId");
  const rawTitle = p.title;
  if (rawTitle !== null && rawTitle !== undefined && typeof rawTitle !== "string") {
    throw new RpcError(
      RPC_ERR.invalidParams,
      "title must be a string or null when provided",
    );
  }
  findTerminal(ctx, sessionId);
  const session = ctx.state.renameTerminal(
    sessionId,
    rawTitle === undefined ? null : rawTitle,
  );
  return { session };
});

methods.set("terminal.dispose", (ctx, params) => {
  const p = asBag(params);
  const sessionId = requireString(p, "sessionId");
  findTerminal(ctx, sessionId);
  ctx.state.terminals.dispose(sessionId);
  return {};
});

methods.set("terminal.list", (ctx, params) => {
  const p = asBag(params);
  if (p.workspaceId === undefined || p.workspaceId === null) {
    // No filter — return every session known to this backend, whether or
    // not its workspaceRoot is currently open as a Workspace instance.
    return { sessions: ctx.state.listAllTerminals() };
  }
  return {
    sessions: ctx.state.listTerminalsForWorkspace(
      requireString(p, "workspaceId"),
    ),
  };
});

// `terminal.subscribe(ids?: string[])` — per-connection fan-out gate for
// `terminal.data` / `terminal.exit` pushes. Per first principle #5: the
// protocol carries scope from day one. v0 default (a connection that has
// never called `terminal.subscribe`) is implicit subscribe-all so legacy
// single-client peers keep working unchanged; a call with `ids` switches
// to a filtered set; omitting `ids` (or passing an empty array) is an
// explicit subscribe-all. `terminal.unsubscribe` opts the connection out
// of all terminal fan-out for as long as the connection lives.
methods.set("terminal.subscribe", (ctx, params) => {
  const sub = requireSubscriber(ctx);
  const p = asBag(params);
  const ids = optionalStringArray(p, "ids");
  if (ids === undefined || ids.length === 0) {
    sub.terminalsSubscribed = true;
  } else {
    sub.terminalsSubscribed = new Set(ids);
  }
  return { ok: true };
});

methods.set("terminal.unsubscribe", (ctx) => {
  const sub = requireSubscriber(ctx);
  sub.terminalsSubscribed = false;
  return { ok: true };
});

methods.set("terminal.listExternalSessions", async (ctx) => {
  const sessions = await ctx.state.listExternalSessions();
  return { sessions };
});

methods.set("terminal.adoptExternalSession", (ctx, params) => {
  const p = asBag(params);
  const sessionName = requireString(p, "sessionName");
  const cols = requirePositiveInt(p, "cols");
  const rows = requirePositiveInt(p, "rows");
  const cwdRaw = optionalString(p, "cwd");
  if (ctx.state.multiplexer.kind !== "zellij") {
    throw new RpcError(
      RPC_ERR.notReady,
      "adoptExternalSession: zellij not available on this host",
    );
  }
  if (ctx.state.isExternalSessionAdopted(sessionName)) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `zellij session "${sessionName}" is already adopted`,
    );
  }
  const workspaceId = optionalString(p, "workspaceId");
  const ws =
    workspaceId === undefined
      ? ctx.state.workspaces.current()
      : ctx.state.workspaces.requireById(workspaceId);
  const workspaceRoot = workspaceId === undefined ? null : ws?.root;
  const cwd =
    cwdRaw !== undefined && cwdRaw.length > 0
      ? cwdRaw
      : (ws?.root ?? process.env.HOME ?? "/");
  const snap = ctx.state.terminals.adopt(
    sessionName,
    cols,
    rows,
    cwd,
    workspaceRoot,
  );
  return {
    sessionId: snap.id,
    workspaceId: ctx.state.workspaceIdForRoot(snap.workspaceRoot),
    ...snap,
  };
});

methods.set("terminal.history", (ctx, params) => {
  const p = asBag(params);
  const sessionId = requireString(p, "sessionId");
  const maxBytes = optionalNonNegativeInt(p, "maxBytes");
  findTerminal(ctx, sessionId);
  return ctx.state.terminals.history(sessionId, maxBytes);
});

function findTerminal(
  ctx: RpcContext,
  sessionId: string,
): void {
  const session = ctx.state.findSession(sessionId);
  if (session === null) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `no such session: ${sessionId}`,
    );
  }
}

// notification.* handlers live in ./rpcHandlers/notificationHandlers.ts (registered below).

export function requireSubscriber(ctx: RpcContext): Subscriber {
  // Should never trigger: the connection layer always supplies a Subscriber
  // for authenticated dispatch. Defensive throw so a future refactor doesn't
  // silently lose subscription state.
  if (!ctx.subscriber) {
    throw new RpcError(RPC_ERR.internal, "subscriber missing from context");
  }
  return ctx.subscriber;
}

export function requireStringArray(p: ParamBag, key: string): string[] {
  const v = p[key];
  if (!Array.isArray(v)) {
    throw new RpcError(RPC_ERR.invalidParams, `${key} must be an array`);
  }
  const out: string[] = [];
  for (const item of v) {
    if (typeof item !== "string" || item.length === 0) {
      throw new RpcError(
        RPC_ERR.invalidParams,
        `${key} entries must be non-empty strings`,
      );
    }
    out.push(item);
  }
  return out;
}


// ---- UI descriptor protocol (design §4.3, issue #59) ----
//
// `ui.tree` pushes originate from the plugin host's UiPanelRegistry. The
// `ui.subscribe` handler registers the connection's socket for fan-out
// and replays the current set of active panels on the next microtask so
// the subscribe RESPONSE arrives first; `ui.event` forwards user
// interactions from the app into the owning plugin via a host→plugin
// JSON-RPC request. Connection-close unsubscribes are wired through
// `ProcessState.removeSubscriber`.

methods.set("ui.subscribe", (ctx) => {
  const host = ctx.state.pluginHost;
  if (host === null) {
    throw new RpcError(
      RPC_ERR.notReady,
      "ui.subscribe: plugin host not initialized on this backend",
    );
  }
  host.ui.subscribe(ctx.ws);
  const snaps = host.ui.activePanels();
  const sock = ctx.ws;
  queueMicrotask(() => {
    for (const snap of snaps) {
      sendNotification(sock, "ui.tree", snap);
    }
  });
  return { ok: true };
});

methods.set("ui.unsubscribe", (ctx) => {
  const host = ctx.state.pluginHost;
  if (host === null) return {};
  host.ui.unsubscribe(ctx.ws);
  return {};
});

methods.set("ui.event", (ctx, params) => {
  const host = ctx.state.pluginHost;
  if (host === null) {
    throw new RpcError(
      RPC_ERR.notReady,
      "ui.event: plugin host not initialized on this backend",
    );
  }
  const p = asBag(params);
  const pluginId = requireString(p, "pluginId");
  const panelId = requireString(p, "panelId");
  const nodeId = requireString(p, "nodeId");
  const type = requireString(p, "type");
  const payload = p.payload;
  // `dispatchUiEvent` throws Error-with-`code` shapes for known failures
  // (unknown plugin, plugin not active, capability not declared); they
  // propagate through `dispatch`'s catch into JSON-RPC error frames.
  // Re-wrap into RpcError for a consistent error type at the boundary.
  try {
    const arg: Parameters<typeof host.dispatchUiEvent>[0] = {
      pluginId,
      panelId,
      nodeId,
      type,
    };
    if (payload !== undefined) arg.payload = payload;
    host.dispatchUiEvent(arg);
  } catch (err) {
    if (err && typeof err === "object" && "code" in err) {
      const e = err as { code: number; message?: string };
      throw new RpcError(e.code, e.message ?? "ui.event failed");
    }
    throw err;
  }
  return {};
});


// ---- Plugin host ----
//
// Frontend surface for the plugin host. Subscription is per-connection — a
// peer that hasn't called `plugin.subscribe` doesn't receive
// `plugin.stateChanged` pushes. The host itself owns activation, kill
// semantics, persistence, and host→plugin command.invoke routing; the
// handlers here are thin glue that translates between RPC params and the
// host's public methods.

export const METHOD_PLUGIN_SUBSCRIBE = "plugin.subscribe";
export const METHOD_PLUGIN_UNSUBSCRIBE = "plugin.unsubscribe";

function requirePluginHost(ctx: RpcContext): NonNullable<RpcContext["state"]["pluginHost"]> {
  const host = ctx.state.pluginHost;
  if (host === null) {
    throw new RpcError(RPC_ERR.notReady, "plugin host not initialized");
  }
  return host;
}

/// Translate the host's PluginHostError into a wire RpcError so the
/// JSON-RPC error code travels through unchanged. Anything else
/// bubbles up to dispatch as an internal error.
function rethrowPluginError(err: unknown): never {
  if (err instanceof PluginHostError) {
    throw new RpcError(err.code, err.message);
  }
  throw err;
}

methods.set(METHOD_PLUGIN_SUBSCRIBE, (ctx) => {
  const sub = requireSubscriber(ctx);
  sub.pluginsSubscribed = true;
  return { ok: true };
});

methods.set(METHOD_PLUGIN_UNSUBSCRIBE, (ctx) => {
  const sub = requireSubscriber(ctx);
  sub.pluginsSubscribed = false;
  return { ok: true };
});

methods.set("plugin.list", (ctx) => {
  const host = requirePluginHost(ctx);
  return { plugins: host.listInfo() };
});

methods.set("plugin.enable", async (ctx, params) => {
  const host = requirePluginHost(ctx);
  const p = asBag(params);
  const id = requireString(p, "id");
  try {
    await host.enable(id);
  } catch (err) {
    rethrowPluginError(err);
  }
  return { ok: true };
});

methods.set("plugin.disable", async (ctx, params) => {
  const host = requirePluginHost(ctx);
  const p = asBag(params);
  const id = requireString(p, "id");
  try {
    await host.disable(id);
  } catch (err) {
    rethrowPluginError(err);
  }
  return { ok: true };
});

methods.set("plugin.log", async (ctx, params) => {
  const host = requirePluginHost(ctx);
  const p = asBag(params);
  const id = requireString(p, "id");
  const maxBytes = optionalPositiveInt(p, "maxBytes") ?? 32 * 1024;
  try {
    return await host.readLogTail(id, maxBytes);
  } catch (err) {
    rethrowPluginError(err);
  }
});

methods.set("plugin.invokeCommand", async (ctx, params) => {
  const host = requirePluginHost(ctx);
  const p = asBag(params);
  const id = requireString(p, "id");
  const commandId = requireString(p, "commandId");
  // `args` is opaque from the host's view — passed through untouched to
  // the plugin's `command.invoke` handler. Missing / null is fine; we
  // don't gate on shape.
  const args = p.args;
  let result: unknown;
  try {
    result = await host.invokeCommand(id, commandId, args);
  } catch (err) {
    rethrowPluginError(err);
  }
  // The plugin may legitimately respond with no result (e.g. for a
  // fire-and-forget command). Surface that as an empty result object so
  // the wire shape stays `{ result?: any }`.
  return result === undefined ? {} : { result };
});

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
  // Optional `client.deviceId` (additive — old clients omit it). When
  // present, store on the connection's Subscriber so `markRead` calls write
  // it into the notification's `read_by` array. See task brief §5.
  let deviceId: string | undefined;
  const clientRaw = p.client;
  if (clientRaw !== undefined && clientRaw !== null) {
    if (typeof clientRaw !== "object" || Array.isArray(clientRaw)) {
      throw new RpcError(
        RPC_ERR.invalidParams,
        "client must be an object when provided",
      );
    }
    deviceId = optionalString(clientRaw as ParamBag, "deviceId");
  }
  ctx.markAuthenticated();
  // markAuthenticated installs the subscriber; bind deviceId after.
  if (deviceId !== undefined && ctx.subscriber) {
    ctx.subscriber.notificationDeviceId = deviceId;
  }
  return {
    ok: true,
    serverVersion: ctx.serverVersion,
    protocolVersion: PROTOCOL_VERSION,
    defaultCwd: process.env.HOME ?? "/",
  };
}
