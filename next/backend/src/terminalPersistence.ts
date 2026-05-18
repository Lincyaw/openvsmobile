// Persistence for the (terminalId → external multiplexer session) mapping.
//
// When a terminal is spawned through zellij, we record the zellij session
// name so future tooling can identify a session as backend-owned without
// re-deriving it from process state. The TerminalRegistry itself is
// process-resident and reset on restart; this DB column is the only place
// the link survives.
//
// v0 intentionally does NOT read these rows back at boot — a stuck reader
// is the kind of failure mode the user clarification flagged as over-
// engineering. We write to keep options open for a follow-up that surfaces
// "previously persistent sessions" without a protocol break.
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
export class TerminalPersistence {
  private readonly db: BetterSqliteDatabase;
  private readonly insertStmt: Database.Statement;
  private readonly deleteStmt: Database.Statement;

  constructor(opts: TerminalPersistenceOptions = {}) {
    const dbPath = opts.dbPath ?? defaultDbPath();
    mkdirSync(dirname(dbPath), { recursive: true });
    this.db = new Database(dbPath);
    this.db.pragma("journal_mode = WAL");
    this.initSchema();
    this.insertStmt = this.db.prepare(`
      INSERT OR REPLACE INTO terminals (
        id, workspace_root, cwd, cols, rows, external_session_id, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
    `);
    this.deleteStmt = this.db.prepare(`DELETE FROM terminals WHERE id = ?`);
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
  }

  /// Record a freshly-created terminal. `externalSessionId` is null when
  /// the terminal was spawned without a multiplexer (direct shell fallback);
  /// the row still exists so a future migration tool can see what was
  /// running at the moment of the last create.
  public recordCreate(row: {
    id: string;
    workspaceRoot: string;
    cwd: string;
    cols: number;
    rows: number;
    externalSessionId: string | null;
    createdAt: number;
  }): void {
    this.insertStmt.run(
      row.id,
      row.workspaceRoot,
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

  public close(): void {
    this.db.close();
  }
}
