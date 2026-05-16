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
import { spawn as ptySpawn, type IPty } from "node-pty";
import { RpcError, RPC_ERR } from "./rpc.js";

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
}

export class TerminalRegistry {
  private readonly sessions = new Map<string, Entry>();

  constructor(
    private readonly onData: TerminalDataSink,
    private readonly onExit: TerminalExitSink,
  ) {}

  public create(cols: number, rows: number, cwd: string): TerminalSnapshot {
    if (!Number.isInteger(cols) || cols < 1) {
      throw new RpcError(RPC_ERR.invalidParams, "cols must be a positive int");
    }
    if (!Number.isInteger(rows) || rows < 1) {
      throw new RpcError(RPC_ERR.invalidParams, "rows must be a positive int");
    }
    const shell = process.env.SHELL || "/bin/bash";
    let pty: IPty;
    try {
      pty = ptySpawn(shell, [], {
        name: "xterm-256color",
        cols,
        rows,
        cwd,
        env: process.env as { [key: string]: string },
      });
    } catch (err) {
      throw new RpcError(
        RPC_ERR.internal,
        `failed to spawn shell: ${(err as Error).message}`,
      );
    }
    const id = randomUUID();
    const entry: Entry = {
      id,
      cols,
      rows,
      cwd,
      createdAt: Date.now(),
      pty,
      scrollback: new ScrollbackBuffer(SCROLLBACK_CAP),
    };
    this.sessions.set(id, entry);

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
