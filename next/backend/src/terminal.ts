// PTY session manager scoped to a single workspace. Each ActiveWorkspace
// owns one TerminalRegistry. Output sinks receive the *terminal* session
// id; the surrounding layer adds the workspace id when emitting JSON-RPC
// notifications.
//
// Each session keeps a circular scrollback buffer (default 1 MiB, override
// via OPENVSMOBILE_SCROLLBACK_BYTES) so a reconnecting client can replay
// what it missed. Bytes that fall off the head are not recoverable; the
// running `seqEnd` counter and a `bytesDropped` field tell the client how
// much was lost, so the UI can paper over the gap honestly.

import { randomUUID } from "node:crypto";
import {
  spawn as ptySpawn,
  type IPty,
  type IPtyForkOptions,
} from "node-pty";
import { RpcError, RPC_ERR } from "./rpc.js";
import {
  isSessionIdSafe,
  killZellijSession,
  zellijSessionName,
  type ExecRunner,
  type MultiplexerInfo,
} from "./multiplexer.js";

/// Signature of the node-pty spawn function we depend on. Pulled into a
/// named type so tests can inject a fake PTY (no actual fork) and assert
/// on the exact (command, args) the registry chose for a given
/// multiplexer config — without requiring zellij or even a shell to be
/// present in the test sandbox.
export type PtySpawner = (
  command: string,
  args: string[],
  options: IPtyForkOptions,
) => IPty;

const DEFAULT_SCROLLBACK_BYTES = 1024 * 1024; // 1 MiB.

/// Read the scrollback cap from the environment. Validates as a positive
/// integer; anything missing or garbled falls back to the default and is
/// noted to stderr so misconfiguration doesn't fail silently.
function resolveScrollbackCap(): number {
  const raw = process.env.OPENVSMOBILE_SCROLLBACK_BYTES;
  if (raw === undefined || raw.trim() === "") return DEFAULT_SCROLLBACK_BYTES;
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) {
    console.error(
      `[openvsmobile-next] invalid OPENVSMOBILE_SCROLLBACK_BYTES=${raw}, ` +
        `falling back to ${DEFAULT_SCROLLBACK_BYTES}`,
    );
    return DEFAULT_SCROLLBACK_BYTES;
  }
  return n;
}

const SCROLLBACK_CAP = resolveScrollbackCap();

export interface TerminalSnapshot {
  id: string;
  cols: number;
  rows: number;
  cwd: string;
  createdAt: number;
}

export type TerminalDataSink = (
  sessionId: string,
  data: Buffer,
  seqEnd: number,
) => void;
export type TerminalExitSink = (sessionId: string, exitCode: number) => void;

/// Bounded circular byte buffer. Append always succeeds; if a write would
/// exceed the cap, the oldest bytes are dropped. O(1) amortized per chunk.
///
/// The buffer never grows beyond `cap` bytes. `seqEnd` (a monotonic counter
/// of total bytes ever appended) is tracked separately so callers can detect
/// wrap and align replayed bytes with live notifications.
class ScrollbackBuffer {
  private readonly cap: number;
  private readonly data: Buffer;
  // Number of bytes currently stored (≤ cap).
  private size = 0;
  // Total bytes ever appended since session start. Strictly monotonic.
  private seqEndCounter = 0;
  // Index of the oldest byte within `data`. Writes happen at `(start + size) % cap`.
  private start = 0;

  constructor(cap: number) {
    this.cap = cap;
    this.data = Buffer.alloc(cap);
  }

  public append(chunk: Buffer): number {
    this.seqEndCounter += chunk.length;
    if (chunk.length === 0) return this.seqEndCounter;
    if (chunk.length >= this.cap) {
      // The chunk alone overruns the buffer — keep only its tail.
      const tail = chunk.subarray(chunk.length - this.cap);
      tail.copy(this.data, 0);
      this.start = 0;
      this.size = this.cap;
      return this.seqEndCounter;
    }
    // How many bytes need to be evicted to make room?
    const free = this.cap - this.size;
    if (chunk.length > free) {
      const evict = chunk.length - free;
      this.start = (this.start + evict) % this.cap;
      this.size -= evict;
    }
    // Append in up to two segments due to wrap-around.
    const writeAt = (this.start + this.size) % this.cap;
    const firstSeg = Math.min(chunk.length, this.cap - writeAt);
    chunk.copy(this.data, writeAt, 0, firstSeg);
    if (firstSeg < chunk.length) {
      chunk.copy(this.data, 0, firstSeg, chunk.length);
    }
    this.size += chunk.length;
    return this.seqEndCounter;
  }

  /// Snapshot of up to `maxBytes` most-recent bytes plus the offset metadata
  /// the client needs to align with live notifications.
  public snapshot(maxBytes?: number): {
    bytes: Buffer;
    scrollbackOffsetEnd: number;
    bytesDropped: number;
    lengthBytes: number;
  } {
    const cap = this.cap;
    const wantBytes =
      maxBytes === undefined || maxBytes < 0
        ? this.size
        : Math.min(maxBytes, this.size);
    const startWithin =
      (this.start + (this.size - wantBytes)) % cap;
    const out = Buffer.alloc(wantBytes);
    const firstSeg = Math.min(wantBytes, cap - startWithin);
    this.data.copy(out, 0, startWithin, startWithin + firstSeg);
    if (firstSeg < wantBytes) {
      this.data.copy(out, firstSeg, 0, wantBytes - firstSeg);
    }
    return {
      bytes: out,
      scrollbackOffsetEnd: this.seqEndCounter,
      bytesDropped: this.seqEndCounter - wantBytes,
      lengthBytes: wantBytes,
    };
  }
}

/// Either a fully-attached terminal (PTY + scrollback live) or a hydrated
/// row from disk (metadata only, attach deferred). The `state` field is
/// the discriminator; everything else is the same shape so list/snapshot
/// callers don't need to branch on liveness. The state is intentionally
/// NOT surfaced over the wire — `terminal.list` returns identical JSON
/// for either kind, matching first principle #5 (per-resource subscription
/// in the protocol from day one; lazy spawn is a server-side optimization
/// invisible to clients).
interface Entry extends TerminalSnapshot {
  /// `live`     — PTY is attached, scrollback is collecting bytes.
  /// `hydrated` — DB row only; `pty` and `scrollback` are absent.
  state: "live" | "hydrated";
  pty: IPty | null;
  scrollback: ScrollbackBuffer | null;
  /// Zellij session name if this terminal was (or will be) spawned
  /// through zellij; null when we fell back to a direct shell. Dispose
  /// uses it to fire `zellij kill-session` so the multiplexer-side
  /// session goes away alongside the PTY — but only for `live` entries;
  /// a `hydrated` entry never had a client attached, so killing the
  /// session would defeat the whole point of persistence.
  externalSessionId: string | null;
}

/// Hook the registry calls on create/dispose/hydrate so a higher layer
/// can record terminal identity to durable storage. Optional — tests
/// and the transitional "no DB" path leave methods unimplemented.
///
/// `loadByWorkspaceRoot` powers the boot-time hydration path: when a
/// workspace opens, the registry asks the hook for every previously-
/// persisted row whose workspace_root matches, and reattaches them
/// lazily. Rows that don't have an `externalSessionId` (direct-shell
/// fallback) are filtered at the persistence layer.
export interface TerminalPersistenceHook {
  recordCreate(row: {
    id: string;
    workspaceRoot: string;
    cwd: string;
    cols: number;
    rows: number;
    externalSessionId: string | null;
    createdAt: number;
  }): void;
  recordDispose(id: string): void;
  loadByWorkspaceRoot(workspaceRoot: string): Array<{
    id: string;
    workspaceRoot: string;
    cwd: string;
    cols: number;
    rows: number;
    externalSessionId: string | null;
    createdAt: number;
  }>;
}

export interface TerminalRegistryOptions {
  /// Multiplexer probe result. When `kind === "zellij"`, `create()` wraps
  /// the shell in `zellij attach --create <name>`. When `kind === "none"`,
  /// `create()` spawns the user's shell directly (status quo). May be
  /// omitted entirely by callers that don't care (older tests).
  multiplexer?: MultiplexerInfo;
  /// Workspace root this registry belongs to. Persisted alongside each
  /// terminal so a future tool can group sessions by workspace without
  /// extra bookkeeping. Pass-through; never used for any access check.
  workspaceRoot?: string;
  /// Durable storage hook. Optional so the legacy two-arg constructor
  /// signature keeps working for tests that don't need persistence.
  persistence?: TerminalPersistenceHook;
  /// Test injection point for the zellij CLI (`kill-session`). Defaults
  /// to the real `execFile`-backed runner.
  execRunner?: ExecRunner;
  /// Test injection point for node-pty. Defaults to the real `spawn`
  /// from node-pty. Tests pass a fake that records arguments and returns
  /// a stub IPty so no actual process is forked.
  ptySpawner?: PtySpawner;
}

export class TerminalRegistry {
  private readonly sessions = new Map<string, Entry>();
  private shuttingDown = false;
  private readonly multiplexer: MultiplexerInfo;
  private readonly workspaceRoot: string;
  private readonly persistence: TerminalPersistenceHook | null;
  private readonly execRunner: ExecRunner | undefined;
  private readonly ptySpawner: PtySpawner;

  constructor(
    private readonly onData: TerminalDataSink,
    private readonly onExit: TerminalExitSink,
    options: TerminalRegistryOptions = {},
  ) {
    this.multiplexer = options.multiplexer ?? { kind: "none" };
    this.workspaceRoot = options.workspaceRoot ?? "";
    this.persistence = options.persistence ?? null;
    this.execRunner = options.execRunner;
    this.ptySpawner = options.ptySpawner ?? ptySpawn;
  }

  public create(cols: number, rows: number, cwd: string): TerminalSnapshot {
    if (!Number.isInteger(cols) || cols < 1) {
      throw new RpcError(RPC_ERR.invalidParams, "cols must be a positive int");
    }
    if (!Number.isInteger(rows) || rows < 1) {
      throw new RpcError(RPC_ERR.invalidParams, "rows must be a positive int");
    }
    // Mint the id first so it can flow into the session name we pass to
    // zellij. The id is already a UUID (no shell-meaningful chars), but
    // we revalidate explicitly so a future caller that supplies its own
    // ids cannot bypass the check by accident.
    const id = randomUUID();
    const useZellij =
      this.multiplexer.kind === "zellij" && isSessionIdSafe(id);
    const externalSessionId = useZellij ? zellijSessionName(id) : null;

    // Spawn either:
    //   zellij attach --create <name>     (persistent path)
    //   <user shell>                      (fallback)
    // node-pty owns the PTY master either way; what runs inside is
    // transparent to the rest of the registry.
    const { command, args } = useZellij
      ? {
          command: "zellij",
          // `attach --create <name>` is idempotent: attaches if the named
          // session exists, creates it (and then attaches) if not. That's
          // exactly the "resurrect across restart" behavior we want.
          args: ["attach", "--create", externalSessionId as string],
        }
      : { command: process.env.SHELL ?? "/bin/bash", args: [] };
    let pty: IPty;
    try {
      pty = this.ptySpawner(command, args, {
        name: "xterm-256color",
        cols,
        rows,
        cwd,
        env: process.env as { [key: string]: string },
      });
    } catch (err) {
      throw new RpcError(
        RPC_ERR.internal,
        `failed to spawn ${useZellij ? "zellij" : "shell"}: ` +
          `${(err as Error).message}`,
      );
    }
    const entry: Entry = {
      id,
      cols,
      rows,
      cwd,
      createdAt: Date.now(),
      state: "live",
      pty,
      scrollback: new ScrollbackBuffer(SCROLLBACK_CAP),
      externalSessionId,
    };
    this.sessions.set(id, entry);
    if (this.persistence !== null) {
      this.persistence.recordCreate({
        id,
        workspaceRoot: this.workspaceRoot,
        cwd,
        cols,
        rows,
        externalSessionId,
        createdAt: entry.createdAt,
      });
    }
    this.wirePtyListeners(entry);
    return snapshotOf(entry);
  }

  /// Read every persisted row for this registry's workspaceRoot and
  /// hydrate them. Called once per ActiveWorkspace at open time. The
  /// `excludeIds` set lets the surrounding WorkspaceRegistry skip ids
  /// it has already claimed for another registry — that's how two
  /// ActiveWorkspaces opened against the same root in one backend
  /// session avoid double-attaching to the same zellij client.
  /// Returns the list of newly-hydrated ids so the caller can extend
  /// its claim set.
  public hydrateFromPersistence(excludeIds: Set<string>): string[] {
    if (this.persistence === null) return [];
    const claimed: string[] = [];
    const rows = this.persistence.loadByWorkspaceRoot(this.workspaceRoot);
    for (const row of rows) {
      if (excludeIds.has(row.id)) continue;
      // Direct-shell rows (externalSessionId === null) can't be
      // resurrected; the persistence layer is supposed to filter them
      // out but we re-check to keep the runtime invariant tight.
      if (row.externalSessionId === null) continue;
      const snap = this.hydrate({
        id: row.id,
        cwd: row.cwd,
        cols: row.cols,
        rows: row.rows,
        externalSessionId: row.externalSessionId,
        createdAt: row.createdAt,
      });
      if (snap !== null) claimed.push(snap.id);
    }
    return claimed;
  }

  /// Hydrate a previously-persisted terminal into the in-memory map
  /// without spawning a PTY. Called once per row by WorkspaceRegistry
  /// at workspace.open time. The entry shows up in `list()` exactly
  /// like a live one, and the first write/resize/history call against
  /// it triggers the deferred zellij attach. Returns the snapshot the
  /// caller can use to track which ids were claimed.
  ///
  /// Idempotent: if a terminal with the same id is already in the map
  /// (e.g. a second ActiveWorkspace for the same root opened in the
  /// same backend session), the existing entry wins and this call is a
  /// no-op. That keeps two workspaces sharing one zellij session from
  /// each spawning their own client.
  public hydrate(row: {
    id: string;
    cwd: string;
    cols: number;
    rows: number;
    externalSessionId: string;
    createdAt: number;
  }): TerminalSnapshot | null {
    if (this.sessions.has(row.id)) return null;
    if (!isSessionIdSafe(row.id)) {
      // A row that wouldn't pass our own session-name safety check
      // can't be re-attached safely; drop it from disk so it doesn't
      // sit around forever, and skip hydration.
      if (this.persistence !== null) this.persistence.recordDispose(row.id);
      return null;
    }
    const entry: Entry = {
      id: row.id,
      cols: row.cols,
      rows: row.rows,
      cwd: row.cwd,
      createdAt: row.createdAt,
      state: "hydrated",
      pty: null,
      scrollback: null,
      externalSessionId: row.externalSessionId,
    };
    this.sessions.set(row.id, entry);
    return snapshotOf(entry);
  }

  /// Promote a `hydrated` entry to `live` by spawning the zellij client.
  /// Called from write/resize/history before they touch the PTY. On
  /// success the entry's `pty` / `scrollback` are populated and the
  /// state flips. On failure the entry is removed from the map AND the
  /// DB (the session is unreachable; persisting the row would loop the
  /// user through the same failure on next restart) and an exit-like
  /// notification fires so the app prunes its chip — matches first
  /// principle #2 (push tells the client *exactly* what happened).
  ///
  /// No-op for entries already `live`.
  private lazyAttachIfNeeded(entry: Entry): void {
    if (entry.state === "live") return;
    const externalSessionId = entry.externalSessionId;
    // Hydrated entries always carry a non-null externalSessionId — the
    // persistence layer filters out direct-shell rows before hydration —
    // but the runtime check keeps the type-narrowing honest and guards
    // against a future caller path that might construct a hydrated
    // entry by other means.
    if (externalSessionId === null) {
      this.evictAndExit(entry.id, -1);
      return;
    }
    let pty: IPty;
    try {
      pty = this.ptySpawner(
        "zellij",
        ["attach", "--create", externalSessionId],
        {
          name: "xterm-256color",
          cols: entry.cols,
          rows: entry.rows,
          cwd: entry.cwd,
          env: process.env as { [key: string]: string },
        },
      );
    } catch (err) {
      // zellij missing / spawn refused / cwd vanished — all collapse to
      // "this chip is dead." Surface to the app via exit fan-out and
      // drop persistence so we don't try again on next restart.
      console.error(
        `[openvsmobile-next] lazy attach failed for terminal ${entry.id}: ` +
          `${(err as Error).message}`,
      );
      this.evictAndExit(entry.id, -1);
      throw new RpcError(
        RPC_ERR.internal,
        `failed to attach to zellij session ${externalSessionId}: ` +
          `${(err as Error).message}`,
      );
    }
    entry.pty = pty;
    entry.scrollback = new ScrollbackBuffer(SCROLLBACK_CAP);
    entry.state = "live";
    this.wirePtyListeners(entry);
  }

  /// Wire the data + exit callbacks for a freshly-spawned PTY. Shared
  /// between `create` and `lazyAttachIfNeeded` so live entries and
  /// just-attached entries have identical observation semantics — same
  /// scrollback contract, same exit-cleanup path.
  private wirePtyListeners(entry: Entry): void {
    const pty = entry.pty;
    const scrollback = entry.scrollback;
    if (pty === null || scrollback === null) {
      // Defensive: wirePtyListeners is only called after a successful
      // spawn so this branch is unreachable. Throw rather than silently
      // ignore — a future refactor that breaks the invariant should
      // surface loudly in tests.
      throw new Error("wirePtyListeners called on a non-live entry");
    }
    const id = entry.id;
    pty.onData((d) => {
      const chunk = Buffer.from(d, "utf8");
      if (chunk.length === 0) {
        // node-pty very rarely produces empty data events; if it does,
        // ScrollbackBuffer.append is a no-op and seqEnd stays put. Don't
        // emit a wire notification — clients document seqEnd as strictly
        // monotonic on terminal.data, and an unchanged value would break
        // the dedupe contract.
        return;
      }
      // Buffer first, then fan out. Order matters: if a brand-new subscriber
      // calls terminal.history concurrently with this data callback, they
      // must not see a chunk in the live stream that isn't yet in scrollback.
      const seqEnd = scrollback.append(chunk);
      this.onData(id, chunk, seqEnd);
    });
    pty.onExit(({ exitCode }) => {
      // detachAll() flips shuttingDown before killing PTYs; the kill
      // triggers this callback asynchronously, and without the guard
      // we'd race and wipe the DB row that the shutdown path
      // deliberately preserved.
      if (this.shuttingDown) return;
      this.sessions.delete(id);
      if (this.persistence !== null) this.persistence.recordDispose(id);
      this.onExit(id, exitCode);
    });
  }

  /// Tear down a session (live or hydrated) and notify the app via the
  /// standard exit fan-out. Used by the lazy-attach failure path where
  /// there's no PTY exit to ride on.
  private evictAndExit(id: string, exitCode: number): void {
    this.sessions.delete(id);
    if (this.persistence !== null) this.persistence.recordDispose(id);
    this.onExit(id, exitCode);
  }

  public write(id: string, data: Buffer): void {
    const entry = this.requireSession(id);
    // First write against a hydrated entry is the canonical lazy-attach
    // trigger: the user typed a key, which means they're focused on
    // this chip and expect the buffer to follow. `lazyAttachIfNeeded`
    // throws on failure with the entry already evicted from the map.
    this.lazyAttachIfNeeded(entry);
    // entry.pty is non-null after a successful attach; the cast keeps
    // the type narrow without re-reading the field through `?.`.
    (entry.pty as IPty).write(data.toString("utf8"));
  }

  public resize(id: string, cols: number, rows: number): void {
    if (!Number.isInteger(cols) || cols < 1) {
      throw new RpcError(RPC_ERR.invalidParams, "cols must be a positive int");
    }
    if (!Number.isInteger(rows) || rows < 1) {
      throw new RpcError(RPC_ERR.invalidParams, "rows must be a positive int");
    }
    const entry = this.requireSession(id);
    // Resize is the second canonical lazy-attach trigger: the app
    // recomputes geometry on chip focus and pushes the new size before
    // the user can type. Attaching here means the zellij server
    // re-lays-out for the actual screen on the very first frame.
    this.lazyAttachIfNeeded(entry);
    try {
      (entry.pty as IPty).resize(cols, rows);
    } catch (err) {
      throw new RpcError(
        RPC_ERR.internal,
        `resize failed: ${(err as Error).message}`,
      );
    }
    entry.cols = cols;
    entry.rows = rows;
  }

  public dispose(id: string): void {
    const entry = this.sessions.get(id);
    if (!entry) return;
    // User tapping X on a chip is an explicit destroy intent for the
    // whole logical session — the chip *is* the user's mental model of
    // the zellij session. Both live and hydrated paths must kill the
    // server-side session, otherwise we leave a ghost only
    // `zellij delete-session` from the terminal can reclaim. Live path
    // also kills the local PTY to detach the client first.
    if (entry.state === "live" && entry.pty !== null) {
      try {
        entry.pty.kill();
      } catch {
        // Already gone; ignore.
      }
    }
    this.sessions.delete(id);
    if (this.persistence !== null) this.persistence.recordDispose(id);
    if (entry.externalSessionId !== null) {
      void killZellijSession(entry.externalSessionId, this.execRunner);
    }
  }

  public list(): TerminalSnapshot[] {
    return [...this.sessions.values()].map(snapshotOf);
  }

  public has(id: string): boolean {
    return this.sessions.has(id);
  }

  public disposeAll(): void {
    for (const id of [...this.sessions.keys()]) {
      this.dispose(id);
    }
  }

  /// Process-shutdown path: tear down PTY clients without touching the
  /// persistence DB or firing `zellij kill-session`. The whole point of
  /// the zellij wrapper is that a clean SIGTERM should NOT wipe the
  /// session — the zellij server stays running, the row stays on disk,
  /// and the next backend boot hydrates the chip right back. Used by
  /// `state.shutdownAll`; user-driven `workspace.close` and
  /// `terminal.dispose` still go through `dispose()` which DOES record
  /// the dispose and kill the zellij session, because those are
  /// explicit destroy intents.
  ///
  /// For direct-shell terminals (no externalSessionId) there's nothing
  /// to resurrect anyway, so we still kill the PTY but skip the DB
  /// touch — the row is meaningless and `loadByWorkspaceRoot` filters
  /// it out at hydrate time.
  public detachAll(): void {
    this.shuttingDown = true;
    for (const entry of this.sessions.values()) {
      if (entry.state === "live" && entry.pty !== null) {
        try {
          entry.pty.kill();
        } catch {
          // Already gone; ignore.
        }
      }
    }
    this.sessions.clear();
  }

  /// Snapshot of the scrollback buffer for `id`. Throws invalidParams if the
  /// session is unknown — the registry is the authority on liveness.
  ///
  /// `terminal.history` is the app's first action when the user switches
  /// to a chip, so it's also a canonical lazy-attach trigger: by the
  /// time the response returns we want the PTY live and the zellij
  /// reattach already painting bytes into the data stream. The history
  /// blob itself is empty for a freshly-attached terminal — zellij owns
  /// the buffer, not us — but the act of asking is what wakes the
  /// session up.
  public history(
    id: string,
    maxBytes?: number,
  ): {
    sessionId: string;
    scrollbackBase64: string;
    scrollbackOffsetEnd: number;
    bytesDropped: number;
    lengthBytes: number;
  } {
    const entry = this.requireSession(id);
    this.lazyAttachIfNeeded(entry);
    // After lazyAttachIfNeeded the entry is `live` and `scrollback` is
    // non-null; the cast keeps that fact in the types.
    const snap = (entry.scrollback as ScrollbackBuffer).snapshot(maxBytes);
    return {
      sessionId: id,
      scrollbackBase64: snap.bytes.toString("base64"),
      scrollbackOffsetEnd: snap.scrollbackOffsetEnd,
      bytesDropped: snap.bytesDropped,
      lengthBytes: snap.lengthBytes,
    };
  }

  private requireSession(id: string): Entry {
    if (typeof id !== "string" || id.length === 0) {
      throw new RpcError(RPC_ERR.invalidParams, "sessionId required");
    }
    const entry = this.sessions.get(id);
    if (!entry) {
      throw new RpcError(RPC_ERR.invalidParams, `no such session: ${id}`);
    }
    return entry;
  }
}

function snapshotOf(entry: Entry): TerminalSnapshot {
  return {
    id: entry.id,
    cols: entry.cols,
    rows: entry.rows,
    cwd: entry.cwd,
    createdAt: entry.createdAt,
  };
}

/// Exposed for tests / smoke scripts that want to confirm what cap is active.
export function scrollbackCapBytes(): number {
  return SCROLLBACK_CAP;
}
