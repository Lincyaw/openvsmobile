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
import { randomUUID } from "node:crypto";
import { listDirAt, readFileAt, type ActiveWorkspace } from "./workspace.js";
import type { ProcessState, Subscriber } from "./state.js";
import {
  hashWorkingFile,
  indexBlobSha,
  isGitRepo,
  pathInIndex,
  pathInTree,
  readHeadInfo,
  readLog,
  readStatus,
  resolveRef,
  runDiffArgs,
} from "./git.js";
import { parseUnifiedDiff, type DiffHunk } from "./diffParser.js";
import { findFiles } from "./findFiles.js";
import { stat as fsStat } from "node:fs/promises";
import { join as pathJoin } from "node:path";

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

// Pull RPC for the working-tree status. Pairs with the workspace.subscribe
// push surface (which carries deltas); callers use this when they need a
// full snapshot on demand outside the subscribe path.
methods.set("git.status", async (ctx, params) => {
  const p = asBag(params);
  const ws = ctx.state.workspaces.requireById(p.workspaceId);
  if (!(await isGitRepo(ws.root))) {
    return {
      isGitRepo: false,
      branch: null,
      ahead: 0,
      behind: 0,
      entries: [],
    };
  }
  const [head, entries] = await Promise.all([
    readHeadInfo(ws.root),
    readStatus(ws.root),
  ]);
  return {
    isGitRepo: true,
    branch: head?.branch ?? null,
    ahead: head?.ahead ?? 0,
    behind: head?.behind ?? 0,
    entries: entries.map((e) => ({ path: e.path, status: e.status })),
  };
});

methods.set("git.diff", async (ctx, params) => {
  const p = asBag(params);
  const ws = ctx.state.workspaces.requireById(p.workspaceId);
  const path = requireString(p, "path");
  const base = optionalString(p, "base") ?? "HEAD";
  // `head` is allowed to be explicitly null (working tree) or a string (ref
  // / "INDEX"). Missing param is treated as null per the protocol default.
  const headParam = p.head;
  if (
    headParam !== undefined &&
    headParam !== null &&
    typeof headParam !== "string"
  ) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      "head must be a string or null when provided",
    );
  }
  const head: string | null =
    headParam === undefined || headParam === null
      ? null
      : (headParam as string);

  // Existence pre-check. A path that has never lived anywhere (working tree,
  // index, or either ref's tree) is a caller bug — surface invalidParams
  // rather than silently returning an empty diff.
  await assertPathExists(ws.root, path, base, head);

  const baseSha = await resolveBaseSha(ws.root, base, path);
  const headSha = await resolveHeadSha(ws.root, head, path);
  // Content-addressed cache key (first principle #3). Two callers asking
  // for the same (workspace, path, baseSha, headSha) get the same patch
  // byte-for-byte, so a second resolve short-circuits the git spawn.
  const cacheKey = `${ws.id} ${path} ${baseSha} ${headSha}`;
  const cached = ctx.state.diffCache.get(cacheKey) as GitDiffResult | undefined;
  if (cached !== undefined) return cached;

  const selectorArgs = buildDiffSelectorArgs(base, head);
  const { stdout, tooLarge: bufferOverflow } = await runDiffArgs(
    ws.root,
    selectorArgs,
    path,
  );

  // Binary detection. Git auto-detects and emits a literal
  //   `Binary files a/x and b/x differ`
  // line inside the patch when the blob has NUL bytes. The marker can show
  // up at the start of stdout (no `diff --git` preamble in some shapes) or
  // after it; scanning the body covers every permutation.
  const isBinary = /(^|\n)Binary files .* and .* differ\n?/.test(stdout);

  const overSize = stdout.length > DIFF_TEXT_LIMIT_BYTES;
  const tooLarge = bufferOverflow || overSize;

  let hunks: WireHunk[] = [];
  if (!isBinary && !tooLarge) {
    hunks = toWireHunks(parseUnifiedDiff(stdout));
  }

  const result: GitDiffResult = {
    hunks,
    baseSha,
    headSha,
    isBinary,
  };
  if (tooLarge) {
    result.tooLarge = true;
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
  return readLog(ws.root, { limit, path, beforeSha });
});

// Cap unified-diff text at 500 KiB. Beyond that we surface `tooLarge: true`
// rather than ship the patch over a phone link. The cap matches design-doc
// section 2.2 (binary / >500KB / deleted files render an explanatory
// placeholder, not the diff); it is intentionally lower than git's own
// maxBuffer (8 MiB) so the wire payload stays bounded even when git is happy
// to keep going.
const DIFF_TEXT_LIMIT_BYTES = 500 * 1024;

/// Wire-shape hunk. Narrows DiffParser's DiffLine.kind to the three values
/// the protocol commits to. Internal `noNewline` markers are dropped at the
/// RPC boundary.
interface WireHunk {
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  header: string;
  lines: { kind: "context" | "add" | "del"; text: string }[];
}

interface GitDiffResult {
  hunks: WireHunk[];
  baseSha: string;
  headSha: string;
  isBinary: boolean;
  tooLarge?: true;
}

/// Sentinel returned in `baseSha` / `headSha` when the slot has no real blob
/// to point at: deleted working-tree file, or `INDEX` for a path not in the
/// index. 40 chars so the wire field is always a fixed-width SHA-like
/// string.
const ZERO_SHA = "0000000000000000000000000000000000000000";

/// Translate (base, head) into the args that go AFTER `git diff` and BEFORE
/// the pathspec. Throws invalidParams for nonsensical combinations.
function buildDiffSelectorArgs(base: string, head: string | null): string[] {
  if (head === null) {
    if (base === "INDEX") {
      // Bare `git diff -- <path>` = index to working tree.
      return [];
    }
    return [base];
  }
  if (head === "INDEX") {
    if (base === "INDEX") {
      throw new RpcError(
        RPC_ERR.invalidParams,
        "base and head cannot both be INDEX",
      );
    }
    return ["--cached", base];
  }
  if (base === "INDEX") {
    throw new RpcError(
      RPC_ERR.invalidParams,
      "INDEX as base only supported with head=null or head=INDEX",
    );
  }
  return [base, head];
}

async function resolveBaseSha(
  cwd: string,
  base: string,
  path: string,
): Promise<string> {
  if (base === "INDEX") {
    return (await indexBlobSha(cwd, path)) ?? ZERO_SHA;
  }
  const sha = await resolveRef(cwd, base);
  if (sha === null) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `cannot resolve base ref: ${base}`,
    );
  }
  return sha;
}

async function resolveHeadSha(
  cwd: string,
  head: string | null,
  path: string,
): Promise<string> {
  if (head === null) {
    return (await hashWorkingFile(cwd, path)) ?? ZERO_SHA;
  }
  if (head === "INDEX") {
    return (await indexBlobSha(cwd, path)) ?? ZERO_SHA;
  }
  const sha = await resolveRef(cwd, head);
  if (sha === null) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `cannot resolve head ref: ${head}`,
    );
  }
  return sha;
}

async function assertPathExists(
  cwd: string,
  path: string,
  base: string,
  head: string | null,
): Promise<void> {
  // Working tree first: a present file is the cheapest "yes".
  try {
    await fsStat(pathJoin(cwd, path));
    return;
  } catch {
    // not on disk; keep looking
  }
  // Index covers staged additions even before the first commit.
  if (await pathInIndex(cwd, path)) return;
  // Commit trees on either side of the requested diff.
  const refs = new Set<string>();
  if (base !== "INDEX") refs.add(base);
  if (head !== null && head !== "INDEX") refs.add(head);
  for (const ref of refs) {
    const resolved = await resolveRef(cwd, ref);
    if (resolved === null) continue;
    if (await pathInTree(cwd, resolved, path)) return;
  }
  throw new RpcError(RPC_ERR.invalidParams, `no such path: ${path}`);
}

function toWireHunks(hunks: DiffHunk[]): WireHunk[] {
  return hunks.map((h) => ({
    oldStart: h.oldStart,
    oldLines: h.oldLines,
    newStart: h.newStart,
    newLines: h.newLines,
    header: h.header,
    lines: h.lines
      .filter((l) => l.kind !== "noNewline")
      .map((l) => ({
        kind: l.kind as "context" | "add" | "del",
        text: l.text,
      })),
  }));
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

// ---- Notifications ----
//
// All under `notification.*`; subscription is per-connection. Fan-out lives
// in state.ts (consults the per-Subscriber `notificationsSubscribed` flag).
// See docs/design/mobile-code-platform.md §4.5.

export const METHOD_NOTIFICATION_SUBSCRIBE = "notification.subscribe";
export const METHOD_NOTIFICATION_UNSUBSCRIBE = "notification.unsubscribe";
export const METHOD_NOTIFICATION_LIST = "notification.list";
export const METHOD_NOTIFICATION_MARK_READ = "notification.markRead";
export const METHOD_NOTIFICATION_DELETE = "notification.delete";
export const METHOD_NOTIFICATION_MARK_IMPORTANT = "notification.markImportant";

function requireSubscriber(ctx: RpcContext): Subscriber {
  // Should never trigger: the connection layer always supplies a Subscriber
  // for authenticated dispatch. Defensive throw so a future refactor doesn't
  // silently lose subscription state.
  if (!ctx.subscriber) {
    throw new RpcError(RPC_ERR.internal, "subscriber missing from context");
  }
  return ctx.subscriber;
}

function requireStringArray(p: ParamBag, key: string): string[] {
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

methods.set(METHOD_NOTIFICATION_SUBSCRIBE, (ctx) => {
  const sub = requireSubscriber(ctx);
  sub.notificationsSubscribed = true;
  return { ok: true };
});

methods.set(METHOD_NOTIFICATION_UNSUBSCRIBE, (ctx) => {
  const sub = requireSubscriber(ctx);
  sub.notificationsSubscribed = false;
  return { ok: true };
});

methods.set(METHOD_NOTIFICATION_LIST, (ctx, params) => {
  const p = asBag(params);
  const since = optionalNonNegativeInt(p, "since");
  const source = optionalString(p, "source");
  const includeRead = optionalBool(p, "includeRead");
  const limitRaw = p.limit;
  let limit = 50;
  if (limitRaw !== undefined && limitRaw !== null) {
    if (
      typeof limitRaw !== "number" ||
      !Number.isInteger(limitRaw) ||
      limitRaw < 1 ||
      limitRaw > 500
    ) {
      throw new RpcError(
        RPC_ERR.invalidParams,
        "limit must be an integer in [1, 500]",
      );
    }
    limit = limitRaw;
  }
  const query: Parameters<typeof ctx.state.notificationHub.list>[0] = { limit };
  if (since !== undefined) query.since = since;
  if (source !== undefined) query.source = source;
  if (includeRead !== undefined) query.includeRead = includeRead;
  // Pass the caller's deviceId through so the store can apply
  // `includeRead=false` as a per-device filter. Subscriber is always
  // present on authenticated dispatch.
  const sub = ctx.subscriber;
  if (sub?.notificationDeviceId !== undefined) {
    query.deviceId = sub.notificationDeviceId;
  }
  return ctx.state.notificationHub.list(query);
});

methods.set(METHOD_NOTIFICATION_MARK_READ, (ctx, params) => {
  const p = asBag(params);
  const ids = requireStringArray(p, "ids");
  const sub = requireSubscriber(ctx);
  // Old clients that didn't supply client.deviceId on handshake get an
  // ephemeral id at subscription time so their reads still hit the DB.
  // Acceptable transition (see task brief §5).
  if (sub.notificationDeviceId === undefined) {
    sub.notificationDeviceId = `ephemeral-${randomUUID()}`;
  }
  ctx.state.notificationHub.markRead(ids, sub.notificationDeviceId);
  return { ok: true };
});

methods.set(METHOD_NOTIFICATION_DELETE, (ctx, params) => {
  const p = asBag(params);
  const ids = requireStringArray(p, "ids");
  ctx.state.notificationHub.delete(ids);
  return { ok: true };
});

methods.set(METHOD_NOTIFICATION_MARK_IMPORTANT, (ctx, params) => {
  const p = asBag(params);
  const id = requireString(p, "id");
  const importantRaw = p.important;
  if (typeof importantRaw !== "boolean") {
    throw new RpcError(RPC_ERR.invalidParams, "important must be a boolean");
  }
  // Symmetric with `notification.delete`: unknown ids are silently swallowed
  // (probably already GC'd or never existed on this backend). Returning
  // `{ ok: true }` lets clients fire-and-forget without needing per-call
  // error handling.
  ctx.state.notificationHub.markImportant(id, importantRaw);
  return { ok: true };
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
