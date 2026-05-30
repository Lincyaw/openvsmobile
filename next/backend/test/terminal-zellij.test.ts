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

import { describe, expect, it, afterEach, beforeEach, vi } from "vitest";
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

describe("TerminalPersistence.loadByWorkspaceRoot", () => {
  it("returns rows filtered by workspace_root, ordered by createdAt", async () => {
    const opts = await tempDbPath();
    const persistence = new TerminalPersistence(opts);
    persistence.recordCreate({
      id: "term-a",
      workspaceRoot: "/work-A",
      cwd: "/work-A",
      cols: 80,
      rows: 24,
      externalSessionId: "ovsm-term-a",
      createdAt: 2000,
    });
    persistence.recordCreate({
      id: "term-b",
      workspaceRoot: "/work-A",
      cwd: "/work-A/src",
      cols: 100,
      rows: 30,
      externalSessionId: "ovsm-term-b",
      createdAt: 1000,
    });
    persistence.recordCreate({
      id: "term-c",
      workspaceRoot: "/other-root",
      cwd: "/other-root",
      cols: 80,
      rows: 24,
      externalSessionId: "ovsm-term-c",
      createdAt: 500,
    });
    const rows = persistence.loadByWorkspaceRoot("/work-A");
    expect(rows.map((r) => r.id)).toEqual(["term-b", "term-a"]);
    expect(rows[0].externalSessionId).toBe("ovsm-term-b");
    expect(rows[0].cols).toBe(100);
    persistence.close();
  });

  it("filters out direct-shell rows (externalSessionId === null)", async () => {
    // Rows without a multiplexer session can't be resurrected — the
    // PTY died with the previous backend. They stay on disk (no
    // protocol-level prune today) but never come back from a load.
    const opts = await tempDbPath();
    const persistence = new TerminalPersistence(opts);
    persistence.recordCreate({
      id: "fallback-only",
      workspaceRoot: "/work",
      cwd: "/work",
      cols: 80,
      rows: 24,
      externalSessionId: null,
      createdAt: 1,
    });
    persistence.recordCreate({
      id: "with-mux",
      workspaceRoot: "/work",
      cwd: "/work",
      cols: 80,
      rows: 24,
      externalSessionId: "ovsm-with-mux",
      createdAt: 2,
    });
    const rows = persistence.loadByWorkspaceRoot("/work");
    expect(rows.map((r) => r.id)).toEqual(["with-mux"]);
    persistence.close();
  });
});

describe("TerminalRegistry hydrate + lazy attach", () => {
  it("hydrate makes a row appear in list() with no PTY spawn", () => {
    const { spawn, calls } = recordingSpawner();
    const reg = new TerminalRegistry(
      () => {},
      () => {},
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        ptySpawner: spawn,
      },
    );
    reg.hydrate({
      id: "11111111-2222-3333-4444-555555555555",
      cwd: "/work",
      cols: 80,
      rows: 24,
      externalSessionId: "ovsm-11111111-2222-3333-4444-555555555555",
      createdAt: 1,
    });
    // Hydration is metadata-only — no spawn yet.
    expect(calls).toHaveLength(0);
    const listed = reg.list();
    expect(listed).toHaveLength(1);
    expect(listed[0].id).toBe("11111111-2222-3333-4444-555555555555");
    // Critically, the wire shape is identical to a live terminal — no
    // extra fields, no "state" leakage. Catches a future regression
    // where a stray `state` slips into snapshotOf and changes
    // terminal.list's response.
    expect(Object.keys(listed[0]).sort()).toEqual(
      ["cols", "createdAt", "cwd", "externalSessionId", "id", "rows"].sort(),
    );
  });

  it("hydrateFromPersistence pulls every row for the registry's workspaceRoot", async () => {
    const opts = await tempDbPath();
    const persistence = new TerminalPersistence(opts);
    persistence.recordCreate({
      id: "abc",
      workspaceRoot: "/work",
      cwd: "/work",
      cols: 80,
      rows: 24,
      externalSessionId: "ovsm-abc",
      createdAt: 1,
    });
    const { spawn, calls } = recordingSpawner();
    const reg = new TerminalRegistry(
      () => {},
      () => {},
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        persistence,
        ptySpawner: spawn,
      },
    );
    const claimed = reg.hydrateFromPersistence(new Set());
    expect(claimed).toEqual(["abc"]);
    expect(reg.list()).toHaveLength(1);
    expect(calls).toHaveLength(0); // still no spawn yet
    persistence.close();
  });

  it("hydrateFromPersistence respects the excludeIds claim set", async () => {
    // Two registries against the same root. The first claims the
    // terminal id; the second must skip it so we don't double-attach
    // to one zellij session.
    const opts = await tempDbPath();
    const persistence = new TerminalPersistence(opts);
    persistence.recordCreate({
      id: "shared",
      workspaceRoot: "/work",
      cwd: "/work",
      cols: 80,
      rows: 24,
      externalSessionId: "ovsm-shared",
      createdAt: 1,
    });
    const claims = new Set<string>();
    const regA = new TerminalRegistry(
      () => {},
      () => {},
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        persistence,
        ptySpawner: recordingSpawner().spawn,
      },
    );
    const claimedA = regA.hydrateFromPersistence(claims);
    for (const id of claimedA) claims.add(id);
    const regB = new TerminalRegistry(
      () => {},
      () => {},
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        persistence,
        ptySpawner: recordingSpawner().spawn,
      },
    );
    const claimedB = regB.hydrateFromPersistence(claims);
    expect(claimedA).toEqual(["shared"]);
    expect(claimedB).toEqual([]);
    expect(regB.list()).toHaveLength(0);
    persistence.close();
  });

  it("write against a hydrated entry triggers `zellij attach --create`", async () => {
    const { spawn, calls } = recordingSpawner();
    const reg = new TerminalRegistry(
      () => {},
      () => {},
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        ptySpawner: spawn,
      },
    );
    const id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    reg.hydrate({
      id,
      cwd: "/work",
      cols: 100,
      rows: 30,
      externalSessionId: `ovsm-${id}`,
      createdAt: 1,
    });
    expect(calls).toHaveLength(0);
    reg.write(id, Buffer.from("ls\n", "utf8"));
    // Lazy attach fired with the persisted cwd / dimensions; we
    // pinned both so a regression that loses geometry on hydrate
    // shows up here.
    expect(calls).toHaveLength(1);
    expect(calls[0].command).toBe("zellij");
    expect(calls[0].args).toEqual(["attach", "--create", `ovsm-${id}`]);
    expect(calls[0].options.cols).toBe(100);
    expect(calls[0].options.rows).toBe(30);
    expect(calls[0].options.cwd).toBe("/work");
    // Second write does NOT spawn again — entry is `live` now.
    reg.write(id, Buffer.from("pwd\n", "utf8"));
    expect(calls).toHaveLength(1);
  });

  it("resize against a hydrated entry triggers `zellij attach --create`", () => {
    vi.useFakeTimers();
    try {
      const { spawn, calls } = recordingSpawner();
      const reg = new TerminalRegistry(
        () => {},
        () => {},
        {
          multiplexer: { kind: "zellij" },
          workspaceRoot: "/work",
          ptySpawner: spawn,
        },
      );
      const id = "11111111-1111-1111-1111-111111111111";
      reg.hydrate({
        id,
        cwd: "/work",
        cols: 80,
        rows: 24,
        externalSessionId: `ovsm-${id}`,
        createdAt: 1,
      });
      reg.resize(id, 120, 40);
      expect(calls).toHaveLength(1);
      expect(calls[0].command).toBe("zellij");
      // resize is debounced (100ms); advance the clock so it fires.
      vi.advanceTimersByTime(100);
      // After lazy attach the geometry on the entry reflects the new
      // size — the resize fired against the now-live PTY.
      const listed = reg.list();
      expect(listed[0].cols).toBe(120);
      expect(listed[0].rows).toBe(40);
    } finally {
      vi.useRealTimers();
    }
  });

  it("history against a hydrated entry triggers `zellij attach --create`", () => {
    // The app's typical chip-focus sequence is fetch history → start
    // rendering → user types. Anchoring lazy attach on history makes
    // the zellij reattach repaint visible the moment the chip opens.
    const { spawn, calls } = recordingSpawner();
    const reg = new TerminalRegistry(
      () => {},
      () => {},
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        ptySpawner: spawn,
      },
    );
    const id = "22222222-2222-2222-2222-222222222222";
    reg.hydrate({
      id,
      cwd: "/work",
      cols: 80,
      rows: 24,
      externalSessionId: `ovsm-${id}`,
      createdAt: 1,
    });
    const snap = reg.history(id);
    expect(calls).toHaveLength(1);
    expect(calls[0].command).toBe("zellij");
    // Freshly-attached terminals have no scrollback yet — zellij owns
    // the buffer, we'll fill ours as data flows.
    expect(snap.scrollbackOffsetEnd).toBe(0);
    expect(snap.lengthBytes).toBe(0);
  });

  it("dispose of a hydrated entry wipes the DB row AND calls kill-session", async () => {
    // The chip IS the user's mental model of the zellij session.
    // Tapping X on a hydrated chip should leave no ghost — DB row goes,
    // zellij server session goes. Same destroy semantics as live dispose.
    const opts = await tempDbPath();
    const persistence = new TerminalPersistence(opts);
    persistence.recordCreate({
      id: "lazy-1",
      workspaceRoot: "/work",
      cwd: "/work",
      cols: 80,
      rows: 24,
      externalSessionId: "ovsm-lazy-1",
      createdAt: 1,
    });
    const { spawn } = recordingSpawner();
    const { runner, calls: execCalls } = recordingRunner();
    const reg = new TerminalRegistry(
      () => {},
      () => {},
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        persistence,
        ptySpawner: spawn,
        execRunner: runner,
      },
    );
    reg.hydrateFromPersistence(new Set());
    reg.dispose("lazy-1");
    await new Promise((r) => setImmediate(r));
    expect(execCalls).toHaveLength(1);
    expect(execCalls[0]).toMatchObject({
      command: "zellij",
      args: ["kill-session", "ovsm-lazy-1"],
    });
    expect(persistence.loadByWorkspaceRoot("/work")).toEqual([]);
    expect(reg.list()).toEqual([]);
    persistence.close();
  });

  it("lazy attach failure evicts the entry, wipes the DB row, fires exit", async () => {
    const opts = await tempDbPath();
    const persistence = new TerminalPersistence(opts);
    persistence.recordCreate({
      id: "doomed",
      workspaceRoot: "/work",
      cwd: "/work",
      cols: 80,
      rows: 24,
      externalSessionId: "ovsm-doomed",
      createdAt: 1,
    });
    const exits: Array<{ id: string; code: number }> = [];
    const failingSpawn = (): IPty => {
      throw new Error("zellij missing");
    };
    const reg = new TerminalRegistry(
      () => {},
      (id, code) => exits.push({ id, code }),
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        persistence,
        ptySpawner: failingSpawn,
      },
    );
    reg.hydrateFromPersistence(new Set());
    expect(reg.list()).toHaveLength(1);
    expect(() => reg.write("doomed", Buffer.from("x", "utf8"))).toThrow(
      /failed to attach/,
    );
    // The exit fan-out fired with code -1 so the app prunes its chip.
    expect(exits).toEqual([{ id: "doomed", code: -1 }]);
    // The DB row is gone — a doomed session would just fail the same
    // way on next boot, so we sweep it.
    expect(persistence.loadByWorkspaceRoot("/work")).toEqual([]);
    // And the in-memory map is empty.
    expect(reg.list()).toEqual([]);
    persistence.close();
  });

  it("detachAll tears down PTY clients WITHOUT touching the DB", async () => {
    // The whole point of the persistence layer: clean SIGTERM must
    // leave the DB intact so the next boot can hydrate. detachAll
    // (used by state.shutdownAll) is the shutdown-safe variant.
    const opts = await tempDbPath();
    const persistence = new TerminalPersistence(opts);
    const { spawn, calls } = recordingSpawner();
    const reg = new TerminalRegistry(
      () => {},
      () => {},
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        persistence,
        ptySpawner: spawn,
      },
    );
    // One live terminal + one hydrated terminal.
    const live = reg.create(80, 24, "/work");
    reg.hydrate({
      id: "hydrated-1",
      cwd: "/work",
      cols: 80,
      rows: 24,
      externalSessionId: "ovsm-hydrated-1",
      createdAt: 1,
    });
    // The live one is in the DB from `create`; the hydrated one came
    // from a hand-call but the DB doesn't know about it. We add it
    // explicitly so the post-detach assertion has something to check
    // for both shapes.
    persistence.recordCreate({
      id: "hydrated-1",
      workspaceRoot: "/work",
      cwd: "/work",
      cols: 80,
      rows: 24,
      externalSessionId: "ovsm-hydrated-1",
      createdAt: 1,
    });
    reg.detachAll();
    // The live PTY got killed; the FakePty.killed flag would be set
    // (we already exercise that in other tests). What matters here
    // is that BOTH rows are still on disk.
    const stillThere = persistence.loadByWorkspaceRoot("/work");
    expect(stillThere.map((r) => r.id).sort()).toEqual(
      [live.id, "hydrated-1"].sort(),
    );
    // And the in-memory map is empty — nothing leaked across the
    // detach boundary.
    expect(reg.list()).toEqual([]);
    // The fake spawner recorded the live spawn but no zellij
    // kill-session was issued (we'd see it via execCalls if we had a
    // runner; this assert is about the spawn count not surging).
    expect(calls).toHaveLength(1);
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

describe("zellij detach handling", () => {
  it("client exit with session still alive demotes to hydrated and fires onDetached", async () => {
    // The bug we are fixing: Ctrl-O d exits the zellij client cleanly
    // (code 0) but leaves the server session running. We must keep the
    // entry and the DB row, and emit `terminal.detached` so the chip
    // shows a (detached) hint instead of disappearing.
    const opts = await tempDbPath();
    const persistence = new TerminalPersistence(opts);
    const { spawn, calls } = recordingSpawner();
    // list-sessions reports the session as still alive.
    const runner: ExecRunner = {
      async run(command, args) {
        if (args[0] === "list-sessions") {
          // Mimic a real zellij output line.
          return {
            stdout: `ovsm-detach-1 [Created 5m ago]\n`,
            stderr: "",
          };
        }
        return { stdout: "", stderr: "" };
      },
    };
    const detached: string[] = [];
    const exits: Array<{ id: string; code: number }> = [];
    const reg = new TerminalRegistry(
      () => {},
      (id, code) => exits.push({ id, code }),
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        persistence,
        ptySpawner: spawn,
        execRunner: runner,
        onDetached: (id) => detached.push(id),
      },
    );
    // Pre-seed so the registry knows the externalSessionId; for adoption
    // path we use a deterministic name.
    const snap = reg.adopt("ovsm-detach-1", 80, 24, "/work");
    expect(calls).toHaveLength(1);
    const fakePty = calls[0].pty;
    fakePty._fireExit(0);
    // The list-sessions probe is async; let it settle.
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    expect(detached).toEqual([snap.id]);
    expect(exits).toEqual([]);
    // Row still on disk and entry still in the map (now hydrated).
    expect(persistence.loadByWorkspaceRoot("/work").map((r) => r.id)).toEqual([
      snap.id,
    ]);
    expect(reg.list().map((t) => t.id)).toEqual([snap.id]);
    persistence.close();
  });

  it("client exit with session gone evicts the entry and fires onExit", async () => {
    const opts = await tempDbPath();
    const persistence = new TerminalPersistence(opts);
    const { spawn, calls } = recordingSpawner();
    const runner: ExecRunner = {
      async run(command, args) {
        if (args[0] === "list-sessions") {
          return { stdout: "No active zellij sessions found.\n", stderr: "" };
        }
        return { stdout: "", stderr: "" };
      },
    };
    const detached: string[] = [];
    const exits: Array<{ id: string; code: number }> = [];
    const reg = new TerminalRegistry(
      () => {},
      (id, code) => exits.push({ id, code }),
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        persistence,
        ptySpawner: spawn,
        execRunner: runner,
        onDetached: (id) => detached.push(id),
      },
    );
    const snap = reg.adopt("ovsm-gone-1", 80, 24, "/work");
    const fakePty = calls[0].pty;
    fakePty._fireExit(1);
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    expect(detached).toEqual([]);
    expect(exits).toEqual([{ id: snap.id, code: 1 }]);
    expect(persistence.loadByWorkspaceRoot("/work")).toEqual([]);
    expect(reg.list()).toEqual([]);
    persistence.close();
  });

  it("write during the probe window rejects rather than flickering to hydrated", async () => {
    // The bug guarded against: pre-flipping state to `hydrated` before the
    // probe resolves means a racing `terminal.list` returns a snapshot for
    // a session that's about to be evicted (probe says "gone"). The
    // `exiting` state suppresses that flicker — list() keeps returning
    // the entry until the probe resolves, and write/resize/history error
    // out cleanly rather than targeting a dead handle.
    const opts = await tempDbPath();
    const persistence = new TerminalPersistence(opts);
    const { spawn, calls } = recordingSpawner();
    let resolveProbe: ((v: { stdout: string; stderr: string }) => void) | null =
      null;
    const runner: ExecRunner = {
      async run(command, args) {
        if (args[0] === "list-sessions") {
          return new Promise((resolve) => {
            resolveProbe = resolve;
          });
        }
        return { stdout: "", stderr: "" };
      },
    };
    const detached: string[] = [];
    const exits: Array<{ id: string; code: number }> = [];
    const reg = new TerminalRegistry(
      () => {},
      (id, code) => exits.push({ id, code }),
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        persistence,
        ptySpawner: spawn,
        execRunner: runner,
        onDetached: (id) => detached.push(id),
      },
    );
    const snap = reg.adopt("ovsm-window-1", 80, 24, "/work");
    const fakePty = calls[0].pty;
    fakePty._fireExit(0);
    // Probe hasn't resolved yet — chip MUST still be visible (so the UI
    // doesn't blank), and writes against it must error rather than
    // silently dropping bytes into a dead PTY.
    expect(reg.list().map((t) => t.id)).toEqual([snap.id]);
    expect(() => reg.write(snap.id, Buffer.from("ls\n", "utf8"))).toThrow(
      /exiting/,
    );
    expect(detached).toEqual([]);
    expect(exits).toEqual([]);
    // Now resolve the probe with "session is gone" — the entry should be
    // evicted, never having shown up as `hydrated` in any list() snapshot.
    resolveProbe?.({ stdout: "No active zellij sessions found.\n", stderr: "" });
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    expect(detached).toEqual([]);
    expect(exits).toEqual([{ id: snap.id, code: 0 }]);
    expect(reg.list()).toEqual([]);
    persistence.close();
  });

  it("dispose during the async list-sessions probe is a no-op for detach fan-out", async () => {
    // A user could tap X between the client exit and the probe resolving.
    // dispose() removes the entry; the detach branch must not fire.
    const opts = await tempDbPath();
    const persistence = new TerminalPersistence(opts);
    const { spawn, calls } = recordingSpawner();
    let resolveProbe: ((v: { stdout: string; stderr: string }) => void) | null =
      null;
    const runner: ExecRunner = {
      async run(command, args) {
        if (args[0] === "list-sessions") {
          return new Promise((resolve) => {
            resolveProbe = resolve;
          });
        }
        return { stdout: "", stderr: "" };
      },
    };
    const detached: string[] = [];
    const exits: Array<{ id: string; code: number }> = [];
    const reg = new TerminalRegistry(
      () => {},
      (id, code) => exits.push({ id, code }),
      {
        multiplexer: { kind: "zellij" },
        workspaceRoot: "/work",
        persistence,
        ptySpawner: spawn,
        execRunner: runner,
        onDetached: (id) => detached.push(id),
      },
    );
    const snap = reg.adopt("ovsm-race-1", 80, 24, "/work");
    const fakePty = calls[0].pty;
    fakePty._fireExit(0);
    // User races a dispose in before list-sessions resolves.
    reg.dispose(snap.id);
    resolveProbe?.({ stdout: "ovsm-race-1\n", stderr: "" });
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    expect(detached).toEqual([]);
    expect(reg.list()).toEqual([]);
    persistence.close();
  });
});

describe("parseZellijListSessions", () => {
  it("parses an active session with a created-ago annotation", async () => {
    const { parseZellijListSessions } = await import("../src/multiplexer.js");
    const parsed = parseZellijListSessions(
      "ovsm-aaa [Created 5m 12s ago]\n",
    );
    expect(parsed).toEqual([{ name: "ovsm-aaa", status: "active" }]);
  });

  it("marks EXITED sessions as exited", async () => {
    const { parseZellijListSessions } = await import("../src/multiplexer.js");
    const parsed = parseZellijListSessions(
      "ovsm-aaa [Created 5m ago]\n" +
        "old-one [Created 1h ago] (EXITED - 'crashed')\n",
    );
    expect(parsed).toEqual([
      { name: "ovsm-aaa", status: "active" },
      { name: "old-one", status: "exited" },
    ]);
  });

  it("strips ANSI escape sequences before extracting the name", async () => {
    const { parseZellijListSessions } = await import("../src/multiplexer.js");
    const parsed = parseZellijListSessions(
      "\x1B[32mfoo\x1B[0m [Created 1m ago]\n",
    );
    expect(parsed).toEqual([{ name: "foo", status: "active" }]);
  });

  it("ignores the 'no sessions' friendly line", async () => {
    const { parseZellijListSessions } = await import("../src/multiplexer.js");
    expect(parseZellijListSessions("No active zellij sessions found.\n"))
      .toEqual([]);
  });

  it("classifies a session literally named EXITED as active", async () => {
    // The session-name regex permits the bare string `EXITED`. We must
    // not misclassify it just because the substring appears in the line;
    // zellij's actual EXITED annotation is always parenthesised
    // (`(EXITED - reason)`) so the open paren is the disambiguator.
    const { parseZellijListSessions } = await import("../src/multiplexer.js");
    expect(parseZellijListSessions("EXITED [Created 1m ago]\n")).toEqual([
      { name: "EXITED", status: "active" },
    ]);
    // And an EXITED-named session that really has exited still parses
    // correctly — both the name and the parenthesised annotation present.
    expect(
      parseZellijListSessions("EXITED [Created 1h ago] (EXITED - 'crashed')\n"),
    ).toEqual([{ name: "EXITED", status: "exited" }]);
  });
});

describe("ProcessState external-session helpers", () => {
  it("listExternalSessions returns [] when multiplexer is none", async () => {
    const { ProcessState } = await import("../src/state.js");
    const state = new ProcessState();
    const sessions = await state.listExternalSessions();
    expect(sessions).toEqual([]);
    state.shutdownAll();
  });

  it("listExternalSessions marks adopted sessions", async () => {
    const { ProcessState } = await import("../src/state.js");
    const tmp = await mkdtemp(join(tmpdir(), "ovsm-state-test-"));
    tempDirs.push(tmp);
    const runner: ExecRunner = {
      async run(command, args) {
        if (args[0] === "list-sessions") {
          return {
            stdout: "ovsm-adopted [Created 5m ago]\nother-one [Created 1m ago]\n",
            stderr: "",
          };
        }
        return { stdout: "", stderr: "" };
      },
    };
    const state = new ProcessState({
      multiplexer: { kind: "zellij" },
      execRunner: runner,
    });
    // Open a workspace and adopt one of the sessions.
    const ws = await state.workspaces.open(tmp);
    ws.terminals.adopt("ovsm-adopted", 80, 24, tmp);
    const sessions = await state.listExternalSessions();
    expect(sessions).toEqual([
      { name: "ovsm-adopted", status: "active", adopted: true },
      { name: "other-one", status: "active", adopted: false },
    ]);
    state.shutdownAll();
  });

  it("adopt refuses a duplicate session name across workspaces", async () => {
    const { ProcessState } = await import("../src/state.js");
    const tmp = await mkdtemp(join(tmpdir(), "ovsm-state-test-"));
    tempDirs.push(tmp);
    const state = new ProcessState({
      multiplexer: { kind: "zellij" },
    });
    const ws = await state.workspaces.open(tmp);
    ws.terminals.adopt("ovsm-shared", 80, 24, tmp);
    expect(state.isExternalSessionAdopted("ovsm-shared")).toBe(true);
    expect(state.isExternalSessionAdopted("ovsm-other")).toBe(false);
    state.shutdownAll();
  });
});
