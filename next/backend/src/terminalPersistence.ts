// Persistence for the (terminalId → external multiplexer session) mapping.
//
// When a terminal is spawned through zellij, we record the zellij session
// name so a future workspace.open against the same root can re-surface the
// session as a chip without re-spawning the PTY up front. The
// TerminalRegistry itself is process-resident and reset on restart; this
// DB is the only place the link survives.
//
// Reads happen at backend boot (global terminal hub) and, for the legacy
// workspace-scoped path used by tests, at workspace.open time. Hydrated rows
// become metadata-only entries ("not yet attached"). Spawning the zellij
// client is deferred to the first user-perceived interaction — see
// TerminalRegistry.lazyAttachIfNeeded.
//
// SQLite file path follows the same convention as notifications.db:
//   $OPENVSMOBILE_TERMINAL_DB  (override, used by tests)
//   ~/.local/state/openvsmobile-next/terminal-sessions.db  (default)

import Database from "better-sqlite3";
import type { Database as BetterSqliteDatabase } from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export interface TerminalPersistenceOptions {
  /// Override path. Tests inject a temp file so they don't clobber the
  /// user's real DB or fight with another concurrent test process.
  dbPath?: string;
}

function defaultDbPath(): string {
  const override = process.env.OPENVSMOBILE_TERMINAL_DB;
  if (override !== undefined && override.length > 0) return override;
  return join(
    homedir(),
    ".local",
    "state",
    "openvsmobile-next",
    "terminal-sessions.db",
  );
}

/// Thin wrapper around a single SQLite table. Sync API — better-sqlite3 is
/// synchronous, and these calls happen on terminal create / dispose only
/// (single-digit per session). The hot PTY data path never touches this.
/// Shape of a hydrated row handed back to the registry. Mirrors the
/// `recordCreate` argument so the registry's hydrate code path is a
/// straight pass-through.
export interface PersistedTerminal {
  id: string;
  title: string | null;
  workspaceRoot: string | null;
  cwd: string;
  cols: number;
  rows: number;
  externalSessionId: string | null;
  createdAt: number;
}

export class TerminalPersistence {
  private readonly db: BetterSqliteDatabase;
  private readonly insertStmt: Database.Statement;
  private readonly deleteStmt: Database.Statement;
  private readonly renameStmt: Database.Statement;
  private readonly loadByRootStmt: Database.Statement;
  private readonly loadAllStmt: Database.Statement;

  constructor(opts: TerminalPersistenceOptions = {}) {
    const dbPath = opts.dbPath ?? defaultDbPath();
    mkdirSync(dirname(dbPath), { recursive: true });
    this.db = new Database(dbPath);
    this.db.pragma("journal_mode = WAL");
    this.initSchema();
    this.insertStmt = this.db.prepare(`
      INSERT OR REPLACE INTO terminals (
        id, title, workspace_root, cwd, cols, rows, external_session_id, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `);
    this.deleteStmt = this.db.prepare(`DELETE FROM terminals WHERE id = ?`);
    this.renameStmt = this.db.prepare(`
      UPDATE terminals SET title = ? WHERE id = ?
    `);
    // Ordered by createdAt so chips reappear in the same left-to-right
    // order the user originally arranged them. The list is tiny in
    // practice (single-digit per workspace) so the index-free ORDER BY
    // is fine.
    this.loadByRootStmt = this.db.prepare(`
      SELECT id, title, workspace_root, cwd, cols, rows, external_session_id,
             created_at
      FROM terminals
      WHERE workspace_root = ?
      ORDER BY created_at ASC
    `);
    this.loadAllStmt = this.db.prepare(`
      SELECT id, title, workspace_root, cwd, cols, rows, external_session_id,
             created_at
      FROM terminals
      ORDER BY workspace_root ASC, created_at ASC
    `);
  }

  private initSchema(): void {
    // Base table. `external_session_id` is nullable: it's NULL for any row
    // written by a backend that found no multiplexer at boot, which is
    // also how an older schema's rows would have looked. Distinguishing
    // those two cases isn't useful in v0; both mean "we cannot resurrect
    // this session."
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS terminals (
        id                   TEXT PRIMARY KEY,
        title                TEXT,
        workspace_root       TEXT NOT NULL,
        cwd                  TEXT NOT NULL,
        cols                 INTEGER NOT NULL,
        rows                 INTEGER NOT NULL,
        external_session_id  TEXT,
        created_at           INTEGER NOT NULL
      );
    `);
    // Migration: if a previous backend version created the table without
    // `external_session_id`, add the column. SQLite reports missing
    // columns by listing what IS present, so we check that explicitly.
    // Safer than `ALTER TABLE … ADD COLUMN IF NOT EXISTS` which isn't
    // supported in the SQLite version better-sqlite3 ships.
    const cols = this.db
      .prepare(`PRAGMA table_info(terminals)`)
      .all() as Array<{ name: string }>;
    const hasExternal = cols.some((c) => c.name === "external_session_id");
    if (!hasExternal) {
      this.db.exec(`ALTER TABLE terminals ADD COLUMN external_session_id TEXT`);
    }
    const hasTitle = cols.some((c) => c.name === "title");
    if (!hasTitle) {
      this.db.exec(`ALTER TABLE terminals ADD COLUMN title TEXT`);
    }
  }

  /// Record a freshly-created terminal. `externalSessionId` is null when
  /// the terminal was spawned without a multiplexer (direct shell fallback);
  /// the row still exists so a future migration tool can see what was
  /// running at the moment of the last create.
  public recordCreate(row: {
    id: string;
    title: string | null;
    workspaceRoot: string | null;
    cwd: string;
    cols: number;
    rows: number;
    externalSessionId: string | null;
    createdAt: number;
  }): void {
    this.insertStmt.run(
      row.id,
      row.title,
      row.workspaceRoot ?? "",
      row.cwd,
      row.cols,
      row.rows,
      row.externalSessionId,
      row.createdAt,
    );
  }

  public recordDispose(id: string): void {
    this.deleteStmt.run(id);
  }

  public recordRename(id: string, title: string | null): void {
    this.renameStmt.run(title, id);
  }

  /// Read every persisted terminal whose `workspace_root` matches the
  /// freshly-opened workspace. Called from WorkspaceRegistry.open right
  /// after the ActiveWorkspace is constructed; the resulting rows are
  /// hydrated into the registry as metadata-only entries (no PTY yet).
  ///
  /// Rows whose `external_session_id` is NULL — i.e. terminals that were
  /// created on a backend without a multiplexer — cannot be resurrected
  /// and so are filtered out at read time. Keeping the rows in the table
  /// is harmless (they get overwritten when a new terminal with the same
  /// id is created, which never happens because ids are fresh UUIDs); a
  /// future sweep RPC can prune them, but the protocol doesn't need it
  /// today.
  public loadByWorkspaceRoot(workspaceRoot: string): PersistedTerminal[] {
    const rows = this.loadByRootStmt.all(workspaceRoot) as Array<{
      id: string;
      title: string | null;
      workspace_root: string;
      cwd: string;
      cols: number;
      rows: number;
      external_session_id: string | null;
      created_at: number;
    }>;
    return persistedRowsFromDb(rows);
  }

  /// Read every resurrectable persisted terminal across every workspace root.
  /// The process-global terminal registry uses this at backend boot so the
  /// Terminal tab can show sessions before any workspace is opened. Empty
  /// `workspace_root` is the on-disk representation for an intentionally
  /// unbound session and maps back to `workspaceRoot: null`.
  public loadAll(): PersistedTerminal[] {
    const rows = this.loadAllStmt.all() as Array<{
      id: string;
      title: string | null;
      workspace_root: string;
      cwd: string;
      cols: number;
      rows: number;
      external_session_id: string | null;
      created_at: number;
    }>;
    return persistedRowsFromDb(rows);
  }

  public close(): void {
    this.db.close();
  }
}

function persistedRowsFromDb(
  rows: Array<{
    id: string;
    title: string | null;
    workspace_root: string;
    cwd: string;
    cols: number;
    rows: number;
    external_session_id: string | null;
    created_at: number;
  }>,
): PersistedTerminal[] {
  const out: PersistedTerminal[] = [];
  for (const r of rows) {
    if (r.external_session_id === null) continue;
    out.push({
      id: r.id,
      title: r.title,
      workspaceRoot: r.workspace_root.length > 0 ? r.workspace_root : null,
      cwd: r.cwd,
      cols: r.cols,
      rows: r.rows,
      externalSessionId: r.external_session_id,
      createdAt: r.created_at,
    });
  }
  return out;
}
