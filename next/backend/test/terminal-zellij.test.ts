// Coverage for the zellij-backed persistent terminal path.
//
// What we are pinning down:
//   * When the multiplexer probe reports `kind: "none"`, terminal.create
//     still succeeds — backend MUST work on hosts without zellij.
//   * When the probe reports `kind: "zellij"`, the spawn we hand to
//     node-pty is exactly `zellij attach --create ovsm-<id>` — that's
//     the whole reason the sessions survive a backend restart.
//   * Dispose calls `zellij kill-session <name>` so the multiplexer
//     server-side session goes away with the PTY.
//   * The DB migration (adding `external_session_id` to a pre-existing
//     `terminals` table without it) runs cleanly.
//
// We never invoke real zellij. The TerminalRegistry exposes injection
// points (`ptySpawner`, `execRunner`) the production wiring doesn't
// use; this test file is the only consumer.

import { describe, expect, it, afterEach, beforeEach } from "vitest";
import type { IPty, IPtyForkOptions } from "node-pty";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Database from "better-sqlite3";
import { TerminalRegistry } from "../src/terminal.js";
import {
  TerminalPersistence,
  type TerminalPersistenceOptions,
} from "../src/terminalPersistence.js";
import type { ExecRunner, MultiplexerInfo } from "../src/multiplexer.js";

/// Minimal stub for an IPty. Only the methods TerminalRegistry actually
/// calls are implemented; the rest throw so a future code path that
/// starts using them surfaces loudly in test.
class FakePty implements Partial<IPty> {
  public readonly pid = 4242;
  public readonly cols = 80;
  public readonly rows = 24;
  public readonly process = "fake";
  public readonly handleFlowControl = false;
  /// Listeners registered through `onData` / `onExit`. We never fire
  /// them in these tests — the registry's create path doesn't depend on
  /// observed data, and dispose runs synchronously without waiting for
  /// onExit to fire.
  private dataCb: ((data: string) => void) | null = null;
  private exitCb:
    | ((e: { exitCode: number; signal?: number }) => void)
    | null = null;
  public killed = false;

  // The IPty surface is fully typed; we cast on assignment in the spawner.
  public onData(cb: (data: string) => void): { dispose: () => void } {
    this.dataCb = cb;
    return { dispose: () => (this.dataCb = null) };
  }
  public onExit(
    cb: (e: { exitCode: number; signal?: number }) => void,
  ): { dispose: () => void } {
    this.exitCb = cb;
    return { dispose: () => (this.exitCb = null) };
  }
  public write(_data: string): void {}
  public resize(_cols: number, _rows: number): void {}
  public kill(_signal?: string): void {
    this.killed = true;
  }
  public pause(): void {}
  public resume(): void {}
  public clear(): void {}
  /// Test-only escape hatch — silences the "unused private" warning on
  /// the callbacks and lets a future expansion exercise them if needed.
  public _fireExit(code: number): void {
    this.exitCb?.({ exitCode: code });
    this.dataCb?.("");
  }
}

interface SpawnedCall {
  command: string;
  args: string[];
  options: IPtyForkOptions;
  pty: FakePty;
}

/// Recording PTY spawner. Captures every call's command + args + options
/// so individual tests can assert "this terminal was launched with these
/// exact arguments". Always returns a fresh `FakePty` (no real fork).
function recordingSpawner(): {
  spawn: (
    command: string,
    args: string[],
    options: IPtyForkOptions,
  ) => IPty;
  calls: SpawnedCall[];
} {
  const calls: SpawnedCall[] = [];
  const spawn = (
    command: string,
    args: string[],
    options: IPtyForkOptions,
  ): IPty => {
    const pty = new FakePty();
    calls.push({ command, args, options, pty });
    return pty as unknown as IPty;
  };
  return { spawn, calls };
}

interface ExecCall {
  command: string;
  args: readonly string[];
}

/// Recording exec runner. Captures every `zellij <subcommand>` invocation
/// and returns an immediately-resolved empty stdout. Tests that want to
/// simulate a kill-session failure pass `failOn` to flip a specific
/// subcommand into a rejection.
function recordingRunner(opts: { failOn?: string } = {}): {
  runner: ExecRunner;
  calls: ExecCall[];
} {
  const calls: ExecCall[] = [];
  const runner: ExecRunner = {
    async run(command, args) {
      calls.push({ command, args });
      if (opts.failOn !== undefined && args.includes(opts.failOn)) {
        const err = new Error("simulated failure") as Error & {
          code?: number;
        };
        err.code = 1;
        throw err;
      }
      return { stdout: "", stderr: "" };
    },
  };
  return { runner, calls };
}

let tempDirs: string[] = [];

beforeEach(() => {
  tempDirs = [];
});

afterEach(async () => {
  for (const d of tempDirs) {
    await rm(d, { recursive: true, force: true });
  }
  tempDirs = [];
});

async function tempDbPath(): Promise<TerminalPersistenceOptions> {
  const d = await mkdtemp(join(tmpdir(), "ovsm-term-db-"));
  tempDirs.push(d);
  return { dbPath: join(d, "terminal-sessions.db") };
}

describe("TerminalRegistry zellij integration", () => {
  it("falls back to a direct shell spawn when no multiplexer is available", () => {
    const { spawn, calls } = recordingSpawner();
    const reg = new TerminalRegistry(
      () => {},
      () => {},
      {
        multiplexer: { kind: "none" },
        workspaceRoot: "/work",
        ptySpawner: spawn,
      },
    );
    const snap = reg.create(80, 24, "/work");
    expect(calls).toHaveLength(1);
    // Direct-shell path runs the user's $SHELL (or /bin/bash) with no
    // multiplexer wrapper. We don't pin the exact binary because the
    // test host's $SHELL varies; what matters is that it's NOT zellij.
    expect(calls[0].command).not.toBe("zellij");
    expect(calls[0].args).toEqual([]);
    expect(snap.id).toMatch(/^[0-9a-f-]{36}$/);
  });

  it("spawns `zellij attach --create ovsm-<id>` when zellij is available", () => {
    const { spawn, calls } = recordingSpawner();
    const reg = new TerminalRegistry(
      () => {},
      () => {},
      {
        multiplexer: { kind: "zellij", version: "zellij 0.44.1" },
        workspaceRoot: "/work",
        ptySpawner: spawn,
      },
    );
    const snap = reg.create(120, 40, "/work");
    expect(calls).toHaveLength(1);
    expect(calls[0].command).toBe("zellij");
    // The session name is the terminal id with the `ovsm-` prefix; the
    // prefix is what lets a human (or a future cleanup tool) identify
    // our sessions in `zellij list-sessions` output.
    expect(calls[0].args).toEqual([
      "attach",
      "--create",
      `ovsm-${snap.id}`,
    ]);
    // The fork options still carry the requested cwd / dimensions —
    // zellij needs the right size up front to lay out panes.
    expect(calls[0].options.cwd).toBe("/work");
    expect(calls[0].options.cols).toBe(120);
    expect(calls[0].options.rows).toBe(40);
  });

  it("dispose kills the PTY and invokes `zellij kill-session <name>`", async () => {
    const { spawn } = recordingSpawner();
    const { runner, calls: execCalls } = recordingRunner();
    const reg = new TerminalRegistry(
      () => {},
      () => {},
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        ptySpawner: spawn,
        execRunner: runner,
      },
    );
    const snap = reg.create(80, 24, "/work");
    reg.dispose(snap.id);
    // killZellijSession is async-fire-and-forget; let it settle.
    await new Promise((r) => setImmediate(r));
    const killCall = execCalls.find((c) => c.args[0] === "kill-session");
    expect(killCall).toBeDefined();
    expect(killCall?.command).toBe("zellij");
    expect(killCall?.args).toEqual(["kill-session", `ovsm-${snap.id}`]);
  });

  it("dispose does not throw when `zellij kill-session` fails", async () => {
    // A common harmless case in practice: zellij already exited /
    // session was deleted manually. The registry must not propagate the
    // CLI error into the dispose RPC's failure path.
    const { spawn } = recordingSpawner();
    const { runner } = recordingRunner({ failOn: "kill-session" });
    const reg = new TerminalRegistry(
      () => {},
      () => {},
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        ptySpawner: spawn,
        execRunner: runner,
      },
    );
    const snap = reg.create(80, 24, "/work");
    expect(() => reg.dispose(snap.id)).not.toThrow();
    // Let the rejected promise from killZellijSession settle before the
    // test ends so vitest doesn't see an unhandled rejection later.
    await new Promise((r) => setImmediate(r));
  });

  it("does NOT call kill-session for direct-shell terminals", async () => {
    const { spawn } = recordingSpawner();
    const { runner, calls: execCalls } = recordingRunner();
    const reg = new TerminalRegistry(
      () => {},
      () => {},
      {
        multiplexer: { kind: "none" },
        workspaceRoot: "/work",
        ptySpawner: spawn,
        execRunner: runner,
      },
    );
    const snap = reg.create(80, 24, "/work");
    reg.dispose(snap.id);
    await new Promise((r) => setImmediate(r));
    // No zellij subcommand should have been issued — the terminal was
    // never wrapped in a multiplexer, so there's nothing on the zellij
    // side to clean up.
    expect(execCalls).toHaveLength(0);
  });
});

describe("TerminalPersistence", () => {
  it("records a freshly-created terminal with its external session id", async () => {
    const opts = await tempDbPath();
    const persistence = new TerminalPersistence(opts);
    persistence.recordCreate({
      id: "term-1",
      workspaceRoot: "/work",
      cwd: "/work/src",
      cols: 80,
      rows: 24,
      externalSessionId: "ovsm-term-1",
      createdAt: 1700000000000,
    });
    const db = new Database(opts.dbPath as string);
    const row = db
      .prepare(
        `SELECT id, workspace_root, cwd, cols, rows, external_session_id,
                created_at
         FROM terminals WHERE id = ?`,
      )
      .get("term-1") as
      | {
          id: string;
          workspace_root: string;
          cwd: string;
          cols: number;
          rows: number;
          external_session_id: string | null;
          created_at: number;
        }
      | undefined;
    expect(row).toBeDefined();
    expect(row?.external_session_id).toBe("ovsm-term-1");
    expect(row?.workspace_root).toBe("/work");
    db.close();
    persistence.close();
  });

  it("recordDispose removes the row", async () => {
    const opts = await tempDbPath();
    const persistence = new TerminalPersistence(opts);
    persistence.recordCreate({
      id: "term-x",
      workspaceRoot: "/work",
      cwd: "/work",
      cols: 80,
      rows: 24,
      externalSessionId: null,
      createdAt: 1,
    });
    persistence.recordDispose("term-x");
    const db = new Database(opts.dbPath as string);
    const count = db
      .prepare(`SELECT COUNT(*) AS c FROM terminals`)
      .get() as { c: number };
    expect(count.c).toBe(0);
    db.close();
    persistence.close();
  });

  it("migrates a pre-existing table that lacks `external_session_id`", async () => {
    // Simulate an older backend's schema by hand-creating the table
    // without the new column; opening a fresh TerminalPersistence
    // against that DB must ALTER TABLE the column in, not throw.
    const opts = await tempDbPath();
    const dbPath = opts.dbPath as string;
    const db = new Database(dbPath);
    db.exec(`
      CREATE TABLE terminals (
        id             TEXT PRIMARY KEY,
        workspace_root TEXT NOT NULL,
        cwd            TEXT NOT NULL,
        cols           INTEGER NOT NULL,
        rows           INTEGER NOT NULL,
        created_at     INTEGER NOT NULL
      );
    `);
    db.prepare(
      `INSERT INTO terminals (id, workspace_root, cwd, cols, rows, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).run("legacy-1", "/work", "/work", 80, 24, 1);
    db.close();

    const persistence = new TerminalPersistence(opts);
    // After migration the legacy row is still there, with NULL in the
    // new column — exactly what the design intends ("we cannot
    // resurrect this session" is indistinguishable from "this was a
    // fallback-mode row").
    const db2 = new Database(dbPath);
    const row = db2
      .prepare(
        `SELECT id, external_session_id FROM terminals WHERE id = ?`,
      )
      .get("legacy-1") as
      | { id: string; external_session_id: string | null }
      | undefined;
    expect(row).toBeDefined();
    expect(row?.external_session_id).toBeNull();
    // And new inserts that DO set the column work — the migration
    // produced a usable schema, not a half-migrated one.
    persistence.recordCreate({
      id: "fresh-1",
      workspaceRoot: "/work",
      cwd: "/work",
      cols: 80,
      rows: 24,
      externalSessionId: "ovsm-fresh-1",
      createdAt: 2,
    });
    const fresh = db2
      .prepare(`SELECT external_session_id FROM terminals WHERE id = ?`)
      .get("fresh-1") as { external_session_id: string | null } | undefined;
    expect(fresh?.external_session_id).toBe("ovsm-fresh-1");
    db2.close();
    persistence.close();
  });
});

describe("probeMultiplexer", () => {
  it("returns `none` when zellij is not installed (ENOENT)", async () => {
    const { probeMultiplexer } = await import("../src/multiplexer.js");
    const runner: ExecRunner = {
      async run() {
        const err = new Error("ENOENT") as NodeJS.ErrnoException;
        err.code = "ENOENT";
        throw err;
      },
    };
    const info = await probeMultiplexer(runner);
    expect(info.kind).toBe("none");
  });

  it("returns `zellij` with the trimmed version when the probe succeeds", async () => {
    const { probeMultiplexer } = await import("../src/multiplexer.js");
    const runner: ExecRunner = {
      async run() {
        return { stdout: "zellij 0.44.1\n", stderr: "" };
      },
    };
    const info = (await probeMultiplexer(runner)) as MultiplexerInfo;
    expect(info.kind).toBe("zellij");
    if (info.kind === "zellij") {
      expect(info.version).toBe("zellij 0.44.1");
    }
  });
});
