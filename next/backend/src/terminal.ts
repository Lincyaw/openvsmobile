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

interface Entry extends TerminalSnapshot {
  pty: IPty;
  scrollback: ScrollbackBuffer;
  /// Zellij session name if this terminal was spawned through zellij;
  /// null when we fell back to a direct shell. Dispose uses it to fire
  /// `zellij kill-session` so the multiplexer-side session goes away
  /// alongside the PTY.
  externalSessionId: string | null;
}

/// Hook the registry calls on create/dispose so a higher layer can record
/// terminal identity to durable storage. Optional — tests and the
/// transitional "no DB" path leave both methods unimplemented.
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
      const seqEnd = entry.scrollback.append(chunk);
      this.onData(id, chunk, seqEnd);
    });
    pty.onExit(({ exitCode }) => {
      this.sessions.delete(id);
      if (this.persistence !== null) this.persistence.recordDispose(id);
      this.onExit(id, exitCode);
    });

    return snapshotOf(entry);
  }

  public write(id: string, data: Buffer): void {
    const entry = this.requireSession(id);
    entry.pty.write(data.toString("utf8"));
  }

  public resize(id: string, cols: number, rows: number): void {
    if (!Number.isInteger(cols) || cols < 1) {
      throw new RpcError(RPC_ERR.invalidParams, "cols must be a positive int");
    }
    if (!Number.isInteger(rows) || rows < 1) {
      throw new RpcError(RPC_ERR.invalidParams, "rows must be a positive int");
    }
    const entry = this.requireSession(id);
    try {
      entry.pty.resize(cols, rows);
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
    try {
      entry.pty.kill();
    } catch {
      // Already gone; ignore.
    }
    this.sessions.delete(id);
    if (this.persistence !== null) this.persistence.recordDispose(id);
    // Killing the PTY only detaches the zellij CLIENT — the zellij
    // SERVER side of this session keeps running and would linger as a
    // ghost until the user typed `zellij delete-session` manually. Fire
    // the explicit kill-session so the user-facing `dispose` actually
    // disposes. Best-effort: errors (session already gone, zellij
    // crashed) are logged inside `killZellijSession` and swallowed —
    // dispose must not fail because of a stale multiplexer.
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

  /// Snapshot of the scrollback buffer for `id`. Throws invalidParams if the
  /// session is unknown — the registry is the authority on liveness.
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
    const snap = entry.scrollback.snapshot(maxBytes);
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
