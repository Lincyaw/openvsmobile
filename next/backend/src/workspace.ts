// Workspace model + filesystem helpers.
//
// A workspace is a window-like session: it has a UUID, a root path, a label,
// and (via the registry) its own terminal sessions. The user can have N
// active workspaces at once; closing one disposes its terminals.
//
// Recents are persisted as plain root strings. Re-opening the same path
// later creates a *new* workspace with a fresh id; matching by path is
// intentional only at the recents UI level.

import { promises as fs, constants as fsConstants } from "node:fs";
import { basename, isAbsolute, normalize, resolve, sep } from "node:path";
import { randomUUID } from "node:crypto";
import { RpcError, RPC_ERR } from "./rpc.js";
import { loadRecents, pushRecent, saveRecents } from "./config.js";
import {
  TerminalRegistry,
  type TerminalDataSink,
  type TerminalExitSink,
} from "./terminal.js";
import { WorkspaceModel } from "./workspaceModel.js";

const MAX_FILE_BYTES = 2 * 1024 * 1024; // 2 MiB hard cap on fs.readFile.

/// The "version" field returned by fs.listDir when no workspace is in scope
/// (i.e. picker mode). The protocol carries it so the client can detect "the
/// listDir result was already stale before I got it" — but the picker has no
/// model, so it has no version either.
const PICKER_VERSION = 0;

export interface TreeEntry {
  name: string;
  kind: "file" | "dir" | "symlink";
  /// `symlinkTarget`, when present, is the raw POSIX string returned by
  /// `readlink(2)`. It may be relative or absolute; it may point outside the
  /// workspace; the backend does NOT resolve it. The client decides what to
  /// do (treat as opaque, attempt scope-checked traversal, or display only).
  size?: number;
  symlinkTarget?: string;
  /// Legacy alias for `kind` — older clients (pre-PR-B Flutter) consume
  /// `type` and only know "file" / "dir". We emit both during the migration
  /// window so the existing app build keeps working; new code reads `kind`.
  /// Symlinks surface as `type: "file"` for the legacy reader (it has no
  /// concept of click-through), matching the old behavior.
  // TODO(remove-when-flutter-reads-kind): drop legacy 'type' alias — see PR-B.
  type: "file" | "dir";
}

export interface WorkspaceInfo {
  id: string;
  root: string;
  label: string;
  createdAt: number;
}

export class ActiveWorkspace {
  public readonly id: string;
  public readonly root: string;
  public readonly label: string;
  public readonly createdAt: number;
  public readonly terminals: TerminalRegistry;
  /// Resident workspace model: file tree decorations, HEAD info, journal,
  /// subscribers. Created in `init()` so the constructor stays synchronous
  /// (the registry awaits init before exposing the workspace).
  public model: WorkspaceModel | null = null;

  constructor(root: string, onData: TerminalDataSink, onExit: TerminalExitSink) {
    this.id = randomUUID();
    this.root = root;
    this.label = basename(root) || root;
    this.createdAt = Date.now();
    this.terminals = new TerminalRegistry(onData, onExit);
  }

  /// Construct + start the resident model. Separated from the constructor
  /// because watcher install + initial `git status` are both async.
  public async initModel(onInvalidate?: () => void): Promise<void> {
    this.model = new WorkspaceModel({
      workspaceId: this.id,
      root: this.root,
      ...(onInvalidate !== undefined ? { onInvalidate } : {}),
    });
    await this.model.init();
  }

  public info(): WorkspaceInfo {
    return {
      id: this.id,
      root: this.root,
      label: this.label,
      createdAt: this.createdAt,
    };
  }

  public assertContains(target: string): void {
    const root = this.root.endsWith(sep) ? this.root : this.root + sep;
    if (target !== this.root && !target.startsWith(root)) {
      throw new RpcError(
        RPC_ERR.invalidParams,
        `path is outside workspace ${this.root}`,
      );
    }
  }

  public dispose(): void {
    this.terminals.disposeAll();
    if (this.model !== null) {
      // Best-effort: chokidar close is async but workspace teardown is sync
      // in the registry. We fire-and-forget; nothing else holds a reference
      // to the watcher after this point.
      void this.model.dispose();
      this.model = null;
    }
  }
}

export class WorkspaceRegistry {
  private readonly active = new Map<string, ActiveWorkspace>();
  private currentId: string | null = null;
  private recents: string[];
  /// Fired by each workspace's resident model when its diff cache entries
  /// must be invalidated (head.changed / tree.delta). Configured via
  /// `setInvalidateHook` so ProcessState can wire ProcessState.diffCache in
  /// without WorkspaceRegistry depending on ProcessState.
  private invalidateHook: ((workspaceId: string) => void) | null = null;

  constructor(
    private readonly onTerminalData: TerminalDataSink,
    private readonly onTerminalExit: TerminalExitSink,
  ) {
    this.recents = loadRecents();
  }

  /// Wire the per-workspace invalidate callback. Called once at boot from
  /// ProcessState; the hook is fired by each ActiveWorkspace's model.
  public setInvalidateHook(hook: (workspaceId: string) => void): void {
    this.invalidateHook = hook;
  }

  public listActive(): WorkspaceInfo[] {
    return [...this.active.values()].map((w) => w.info());
  }

  public listRecents(): string[] {
    return [...this.recents];
  }

  public current(): ActiveWorkspace | null {
    if (this.currentId === null) return null;
    return this.active.get(this.currentId) ?? null;
  }

  public get(id: string): ActiveWorkspace {
    const w = this.active.get(id);
    if (!w) {
      throw new RpcError(RPC_ERR.invalidParams, `no such workspace: ${id}`);
    }
    return w;
  }

  public async open(
    rawRoot: unknown,
    options: { activate?: boolean } = {},
  ): Promise<ActiveWorkspace> {
    const root = await validatedRoot(rawRoot);
    const ws = new ActiveWorkspace(root, this.onTerminalData, this.onTerminalExit);
    // initModel installs watchers + runs initial git status. We await before
    // publishing the workspace so a `workspace.subscribe` immediately after
    // `workspace.open` sees a populated model — not "no such workspace" or a
    // half-initialized state with version 0.
    const hook = this.invalidateHook;
    if (hook !== null) {
      await ws.initModel(() => hook(ws.id));
    } else {
      await ws.initModel();
    }
    this.active.set(ws.id, ws);
    const activate = options.activate ?? true;
    if (activate) {
      this.currentId = ws.id;
    }
    // When activate === false, currentId is intentionally left as-is — even
    // if it was null. Caller chose to pre-stage a workspace without focusing.
    this.recents = pushRecent(this.recents, root);
    saveRecents(this.recents);
    return ws;
  }

  public activate(rawId: unknown): ActiveWorkspace {
    if (typeof rawId !== "string" || rawId.length === 0) {
      throw new RpcError(RPC_ERR.invalidParams, "id required");
    }
    const w = this.active.get(rawId);
    if (!w) {
      throw new RpcError(RPC_ERR.invalidParams, `no such workspace: ${rawId}`);
    }
    this.currentId = w.id;
    return w;
  }

  // Returns the new current workspace id (or null) so the caller can decide
  // whether to emit notifications.
  public close(rawId: unknown): string | null {
    if (typeof rawId !== "string" || rawId.length === 0) {
      throw new RpcError(RPC_ERR.invalidParams, "id required");
    }
    const w = this.active.get(rawId);
    if (!w) {
      throw new RpcError(RPC_ERR.invalidParams, `no such workspace: ${rawId}`);
    }
    w.dispose();
    this.active.delete(rawId);
    if (this.currentId === rawId) {
      const first = this.active.values().next().value as
        | ActiveWorkspace
        | undefined;
      this.currentId = first ? first.id : null;
    }
    return this.currentId;
  }

  public disposeAll(): string[] {
    const ids = [...this.active.keys()];
    for (const w of this.active.values()) w.dispose();
    this.active.clear();
    this.currentId = null;
    return ids;
  }

  public requireById(rawId: unknown): ActiveWorkspace {
    if (typeof rawId !== "string" || rawId.length === 0) {
      throw new RpcError(RPC_ERR.invalidParams, "workspaceId required");
    }
    return this.get(rawId);
  }
}

// -------- Filesystem helpers (called from rpc.ts handlers) --------

async function validatedRoot(rawRoot: unknown): Promise<string> {
  if (typeof rawRoot !== "string" || rawRoot.length === 0) {
    throw new RpcError(RPC_ERR.invalidParams, "root must be a non-empty string");
  }
  if (!isAbsolute(rawRoot)) {
    throw new RpcError(RPC_ERR.invalidParams, "root must be an absolute path");
  }
  const normalized = normalize(rawRoot);
  // Resolve symlinks to canonical form. `assertContains` is a lexical
  // prefix check, so the root we store has to already be the post-symlink
  // canonical path or symlinked roots silently bypass containment.
  let root: string;
  try {
    root = await fs.realpath(normalized);
  } catch (err) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `cannot access ${normalized}: ${(err as Error).message}`,
    );
  }
  let stat;
  try {
    stat = await fs.stat(root);
  } catch (err) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `cannot access ${root}: ${(err as Error).message}`,
    );
  }
  if (!stat.isDirectory()) {
    throw new RpcError(RPC_ERR.invalidParams, `${root} is not a directory`);
  }
  try {
    await fs.access(root, fsConstants.R_OK);
  } catch {
    throw new RpcError(RPC_ERR.invalidParams, `${root} is not readable`);
  }
  return root;
}

// Validate + canonicalize a caller-supplied absolute path. Realpath-resolves
// the target so a downstream lexical `assertContains` cannot be bypassed by
// a symlink. Returns the same opaque "outside workspace" error for both
// not-found and out-of-scope when `scope` is supplied — preventing a client
// from probing filesystem layout via differential error messages.
async function resolveCallerPath(
  rawPath: unknown,
  scope: ActiveWorkspace | null,
): Promise<string> {
  if (typeof rawPath !== "string" || rawPath.length === 0) {
    throw new RpcError(RPC_ERR.invalidParams, "path must be a non-empty string");
  }
  if (!isAbsolute(rawPath)) {
    throw new RpcError(RPC_ERR.invalidParams, "path must be absolute");
  }
  const normalized = normalize(rawPath);
  let resolved: string;
  try {
    resolved = await fs.realpath(normalized);
  } catch (err) {
    if (scope !== null) {
      // Collapse "not found" into "outside workspace" so the existence of a
      // file outside the workspace can't be probed by error string.
      throw new RpcError(
        RPC_ERR.invalidParams,
        `path is outside workspace ${scope.root}`,
      );
    }
    throw new RpcError(
      RPC_ERR.invalidParams,
      `cannot access ${normalized}: ${(err as Error).message}`,
    );
  }
  if (scope !== null) {
    scope.assertContains(resolved);
  }
  return resolved;
}

export async function listDirAt(
  rawPath: unknown,
  scope: ActiveWorkspace | null,
): Promise<{ resolved: string; entries: TreeEntry[]; version: number }> {
  const target = await resolveCallerPath(rawPath, scope);
  let dirents;
  try {
    dirents = await fs.readdir(target, { withFileTypes: true });
  } catch (err) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `cannot read directory ${target}: ${(err as Error).message}`,
    );
  }
  const entries: TreeEntry[] = [];
  for (const d of dirents) {
    const isSymlink = d.isSymbolicLink();
    const kind: TreeEntry["kind"] = isSymlink
      ? "symlink"
      : d.isDirectory()
        ? "dir"
        : "file";
    const entry: TreeEntry = {
      name: d.name,
      kind,
      type: kind === "dir" ? "dir" : "file",
    };
    const absChild = resolve(target, d.name);
    if (kind === "file") {
      try {
        const st = await fs.stat(absChild);
        entry.size = st.size;
      } catch {
        // Ignore stat failures — we still return the name.
      }
    } else if (kind === "symlink") {
      try {
        entry.symlinkTarget = await fs.readlink(absChild);
      } catch {
        // Broken / unreadable symlink — name only.
      }
    }
    entries.push(entry);
  }
  entries.sort((a, b) => {
    // Directories first, then symlinks, then files. Matches what users expect
    // and what the previous shape produced.
    if (a.kind !== b.kind) {
      const order = (k: TreeEntry["kind"]): number =>
        k === "dir" ? 0 : k === "symlink" ? 1 : 2;
      return order(a.kind) - order(b.kind);
    }
    return a.name.localeCompare(b.name);
  });
  const version = scope !== null && scope.model !== null
    ? scope.model.currentVersion()
    : PICKER_VERSION;
  return { resolved: target, entries, version };
}

export async function readFileAt(
  rawPath: unknown,
  scope: ActiveWorkspace,
  ifEtag?: string,
): Promise<
  | { resolved: string; etag: string; notModified: true }
  | {
      resolved: string;
      etag: string;
      contentBase64: string;
      encoding: "utf8" | "binary";
    }
> {
  // Order matters: scope check happens INSIDE resolveCallerPath, before
  // we stat/read. Doing IO first would (a) waste cycles on doomed reads
  // and (b) leak the difference between "outside workspace" and
  // "doesn't exist" through error messages.
  const target = await resolveCallerPath(rawPath, scope);
  let stat;
  try {
    stat = await fs.stat(target);
  } catch (err) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `cannot stat ${target}: ${(err as Error).message}`,
    );
  }
  if (!stat.isFile()) {
    throw new RpcError(RPC_ERR.invalidParams, `${target} is not a regular file`);
  }
  // ETag is `${mtime}-${size}`; we floor mtimeMs to integer because client
  // ETags round-trip through JSON as numbers without sub-millisecond fidelity.
  const etag = `${Math.floor(stat.mtimeMs)}-${stat.size}`;
  if (ifEtag !== undefined && ifEtag === etag) {
    return { resolved: target, etag, notModified: true };
  }
  if (stat.size > MAX_FILE_BYTES) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `file too large (${stat.size} bytes, limit ${MAX_FILE_BYTES})`,
      { size: stat.size, limit: MAX_FILE_BYTES },
    );
  }
  const buf = await fs.readFile(target);
  const encoding = isLikelyBinary(buf) ? "binary" : "utf8";
  return {
    resolved: target,
    etag,
    contentBase64: buf.toString("base64"),
    encoding,
  };
}

// Cheap heuristic: a NUL in the first 8 KiB ⇒ binary. Good enough to keep the
// viewer from trying to render PNGs as text. Real charset detection is out of
// scope.
function isLikelyBinary(buf: Buffer): boolean {
  const slice = buf.subarray(0, Math.min(buf.length, 8192));
  for (let i = 0; i < slice.length; i++) {
    if (slice[i] === 0) return true;
  }
  return false;
}
