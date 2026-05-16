// PTY session manager scoped to a single workspace. Each ActiveWorkspace
// owns one TerminalRegistry. Output sinks receive the *connection-level*
// sinks plus the workspace id is plumbed in by the calling code, so the
// registry itself stays workspace-agnostic.

import { randomUUID } from "node:crypto";
import { spawn as ptySpawn, type IPty } from "node-pty";
import { RpcError, RPC_ERR } from "./rpc.js";

export interface TerminalSnapshot {
  id: string;
  cols: number;
  rows: number;
  cwd: string;
  createdAt: number;
}

// Sinks fire with the *terminal* session id; the surrounding layer adds
// the workspace id when emitting JSON-RPC notifications.
export type TerminalDataSink = (sessionId: string, data: Buffer) => void;
export type TerminalExitSink = (sessionId: string, exitCode: number) => void;

interface Entry extends TerminalSnapshot {
  pty: IPty;
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
    };
    this.sessions.set(id, entry);

    pty.onData((d) => this.onData(id, Buffer.from(d, "utf8")));
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
