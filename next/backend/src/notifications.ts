// Notification system — schema validation, SQLite persistence, event-driven GC.
//
// This module owns the data model for §4.5 of the design doc:
//   * Sender API surface (POST /notify, validated here; HTTP framing lives
//     in notifyHttp.ts so this file stays transport-agnostic).
//   * SQLite-backed history (better-sqlite3, synchronous).
//   * Supersedes-chain bookkeeping.
//   * TTL GC sweep — opportunistic, driven by `notification.list` calls and
//     by insert counts; no recurring timers (conventions §1).
//
// Anything that *transports* a notification — WebSocket fan-out, JSON-RPC
// dispatch — is in `state.ts` / `rpc.ts`. This file is pure persistence + a
// thin in-process pub/sub so the HTTP and RPC layers can both feed it.
//
// See docs/design/mobile-code-platform.md §4.5.

import Database from "better-sqlite3";
import type { Database as BetterSqliteDatabase } from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import { RpcError, RPC_ERR } from "./rpc.js";

// ----- 1. Constants -----

/// Title length cap from §4.5 ("≤80 chars").
const TITLE_MAX_LEN = 80;
/// Body cap. Spec phrasing was "recommended"; tightened to hard cap because
/// oversized JSON in SQLite slows queries — bump if real plugins need more.
const BODY_MAX_BYTES = 16 * 1024;
/// Source string cap. Free-form, but a 4 KB tag is almost certainly a bug.
const SOURCE_MAX_LEN = 256;
/// Default TTL — 7 days — from §4.5.
const DEFAULT_TTL_SECONDS = 7 * 24 * 60 * 60;
/// Minimum interval between opportunistic GC sweeps triggered by
/// `notification.list`. A backend handling steady traffic still gets at most
/// one sweep per hour; a quiet backend gets none, which is fine (nothing
/// expires if nothing is being inserted or queried).
const GC_MIN_INTERVAL_MS = 60 * 60 * 1000;
/// Insert-count cadence for the second sweep trigger. Every Nth successful
/// insert runs a sweep after the row is persisted. 100 was picked so a
/// chatty plugin (1/sec) gets a sweep every ~2 minutes; a normal one (a
/// few per hour) is bounded by GC_MIN_INTERVAL_MS via `list` calls.
const GC_INSERT_PERIOD = 100;
/// Current schema version recorded in `schema_meta`. Bumped only on a
/// migration; v0 sits at 1 forever.
const SCHEMA_VERSION = 1;

const LEVELS = new Set<NotificationLevel>(["info", "success", "warning", "error"]);

// ----- 2. Types -----

export type NotificationLevel = "info" | "success" | "warning" | "error";

export interface NotificationField {
  key: string;
  value: string;
}

export interface NotificationLink {
  title: string;
  url: string;
}

export type NotificationAction =
  | { kind: "open-url"; url: string }
  | { kind: "copy"; text: string }
  | { kind: "open-workspace"; workspaceId: string };

/// The wire-shape Notification — what fan-out emits, what `notification.list`
/// returns, what the foreground service POSTs back to the client UI. Matches
/// design §4.5 verbatim. `widget` is opaque JSON in v0 (renderer is PR-D).
export interface Notification {
  id: string;
  source: string;
  level: NotificationLevel;
  title: string;
  body?: string;
  fields?: NotificationField[];
  links?: NotificationLink[];
  action?: NotificationAction;
  groupKey?: string;
  supersedes?: string;
  supersededBy?: string;
  important?: boolean;
  ttl?: number;
  ttlUntil?: number | null;
  timestamp: number;
  widget?: unknown;
  readBy?: string[];
}

/// Inbound payload — everything the sender can supply. `id`, `timestamp`,
/// `ttlUntil`, `supersededBy`, `readBy` are server-assigned and are silently
/// ignored if the client tries to set them (matches design "minus server-
/// assigned fields").
export interface NotificationInput {
  source: string;
  level: NotificationLevel;
  title: string;
  body?: string;
  fields?: NotificationField[];
  links?: NotificationLink[];
  action?: NotificationAction;
  groupKey?: string;
  supersedes?: string;
  important?: boolean;
  ttl?: number;
  timestamp?: number;
  widget?: unknown;
}

// ----- 3. Validation -----

function fail(msg: string): never {
  throw new RpcError(RPC_ERR.invalidParams, msg);
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function validateAction(raw: unknown): NotificationAction | undefined {
  if (raw === undefined || raw === null) return undefined;
  if (!isPlainObject(raw)) fail("action must be an object");
  const kind = raw.kind;
  if (kind === "open-url") {
    if (typeof raw.url !== "string" || raw.url.length === 0) {
      fail("action.url required for open-url");
    }
    return { kind: "open-url", url: raw.url };
  }
  if (kind === "copy") {
    if (typeof raw.text !== "string") fail("action.text required for copy");
    return { kind: "copy", text: raw.text };
  }
  if (kind === "open-workspace") {
    if (typeof raw.workspaceId !== "string" || raw.workspaceId.length === 0) {
      fail("action.workspaceId required for open-workspace");
    }
    return { kind: "open-workspace", workspaceId: raw.workspaceId };
  }
  fail("action.kind must be open-url | copy | open-workspace");
}

function validateFields(raw: unknown): NotificationField[] | undefined {
  if (raw === undefined || raw === null) return undefined;
  if (!Array.isArray(raw)) fail("fields must be an array");
  const out: NotificationField[] = [];
  for (const item of raw) {
    if (!isPlainObject(item)) fail("fields[] entries must be objects");
    if (typeof item.key !== "string" || item.key.length === 0) {
      fail("fields[].key required");
    }
    if (typeof item.value !== "string") fail("fields[].value required");
    out.push({ key: item.key, value: item.value });
  }
  return out;
}

function validateLinks(raw: unknown): NotificationLink[] | undefined {
  if (raw === undefined || raw === null) return undefined;
  if (!Array.isArray(raw)) fail("links must be an array");
  const out: NotificationLink[] = [];
  for (const item of raw) {
    if (!isPlainObject(item)) fail("links[] entries must be objects");
    if (typeof item.title !== "string" || item.title.length === 0) {
      fail("links[].title required");
    }
    if (typeof item.url !== "string" || item.url.length === 0) {
      fail("links[].url required");
    }
    out.push({ title: item.title, url: item.url });
  }
  return out;
}

/// Validate + normalize a raw inbound payload. Throws RpcError (with code
/// `invalidParams`) on schema violations — the HTTP layer maps that to 400,
/// the RPC layer surfaces it as the standard JSON-RPC error frame.
export function validateNotificationInput(raw: unknown): NotificationInput {
  if (!isPlainObject(raw)) fail("payload must be an object");

  if (typeof raw.source !== "string" || raw.source.length === 0) {
    fail("source required");
  }
  if (raw.source.length > SOURCE_MAX_LEN) {
    fail(`source exceeds ${SOURCE_MAX_LEN} chars`);
  }

  if (typeof raw.level !== "string" || !LEVELS.has(raw.level as NotificationLevel)) {
    fail("level must be one of info|success|warning|error");
  }

  if (typeof raw.title !== "string" || raw.title.length === 0) {
    fail("title required");
  }
  if (raw.title.length > TITLE_MAX_LEN) {
    fail(`title exceeds ${TITLE_MAX_LEN} chars`);
  }

  let body: string | undefined;
  if (raw.body !== undefined && raw.body !== null) {
    if (typeof raw.body !== "string") fail("body must be a string");
    if (Buffer.byteLength(raw.body, "utf8") > BODY_MAX_BYTES) {
      fail(`body exceeds ${BODY_MAX_BYTES} bytes`);
    }
    body = raw.body;
  }

  const fields = validateFields(raw.fields);
  const links = validateLinks(raw.links);
  const action = validateAction(raw.action);

  let groupKey: string | undefined;
  if (raw.groupKey !== undefined && raw.groupKey !== null) {
    if (typeof raw.groupKey !== "string" || raw.groupKey.length === 0) {
      fail("groupKey must be a non-empty string");
    }
    groupKey = raw.groupKey;
  }

  let supersedes: string | undefined;
  if (raw.supersedes !== undefined && raw.supersedes !== null) {
    if (typeof raw.supersedes !== "string" || raw.supersedes.length === 0) {
      fail("supersedes must be a non-empty string");
    }
    supersedes = raw.supersedes;
  }

  let important: boolean | undefined;
  if (raw.important !== undefined && raw.important !== null) {
    if (typeof raw.important !== "boolean") fail("important must be boolean");
    important = raw.important;
  }

  let ttl: number | undefined;
  if (raw.ttl !== undefined && raw.ttl !== null) {
    if (typeof raw.ttl !== "number" || !Number.isFinite(raw.ttl) || raw.ttl < 0) {
      fail("ttl must be a non-negative number (seconds)");
    }
    ttl = raw.ttl;
  }

  let timestamp: number | undefined;
  if (raw.timestamp !== undefined && raw.timestamp !== null) {
    if (
      typeof raw.timestamp !== "number" ||
      !Number.isFinite(raw.timestamp) ||
      raw.timestamp < 0
    ) {
      fail("timestamp must be a non-negative number (epoch ms)");
    }
    timestamp = raw.timestamp;
  }

  // `widget` is opaque in v0; renderer lives in PR-D. We accept any JSON
  // value so the sender can prepare it now, but we don't validate shape.
  const widget = raw.widget;

  const out: NotificationInput = {
    source: raw.source,
    level: raw.level as NotificationLevel,
    title: raw.title,
  };
  if (body !== undefined) out.body = body;
  if (fields !== undefined) out.fields = fields;
  if (links !== undefined) out.links = links;
  if (action !== undefined) out.action = action;
  if (groupKey !== undefined) out.groupKey = groupKey;
  if (supersedes !== undefined) out.supersedes = supersedes;
  if (important !== undefined) out.important = important;
  if (ttl !== undefined) out.ttl = ttl;
  if (timestamp !== undefined) out.timestamp = timestamp;
  if (widget !== undefined) out.widget = widget;
  return out;
}

// ----- 4. SQLite store -----

interface DbRow {
  id: string;
  source: string;
  level: string;
  title: string;
  body: string | null;
  payload: string | null;
  group_key: string | null;
  supersedes: string | null;
  superseded_by: string | null;
  important: number;
  timestamp: number;
  ttl_until: number | null;
  read_by: string | null;
  created_at: number;
}

/// Fields stashed in the `payload` JSON blob. Keeping them out of dedicated
/// columns means future schema bumps are cheap; we never query them server-
/// side (clients filter), only round-trip them on read.
interface PayloadBlob {
  fields?: NotificationField[];
  links?: NotificationLink[];
  action?: NotificationAction;
  widget?: unknown;
}

function defaultDbPath(): string {
  const override = process.env.OPENVSMOBILE_NOTIFICATIONS_DB;
  if (override && override.length > 0) return override;
  return join(
    homedir(),
    ".local",
    "state",
    "openvsmobile-next",
    "notifications.db",
  );
}

export interface InsertOptions {
  /// Override the path used for storing the database. Tests pass a temp dir;
  /// production reads $OPENVSMOBILE_NOTIFICATIONS_DB or falls back to
  /// ~/.local/state/openvsmobile-next/notifications.db.
  dbPath?: string;
}

export interface ListQuery {
  since?: number;
  limit: number;
  source?: string;
  /// Default true. When false, the row is excluded if the caller's
  /// `deviceId` is already in the row's `read_by` array (i.e. read by THIS
  /// device). Requires `deviceId` to be set; otherwise the filter is a
  /// no-op (we have nothing to compare against).
  includeRead?: boolean;
  /// Identifies the caller for the `includeRead` filter. The RPC layer
  /// passes `ctx.subscriber.notificationDeviceId`. Undefined when the
  /// caller never set one (legacy clients pre-`client.deviceId`).
  deviceId?: string;
  /// If false (default), rows whose `supersededBy` is non-null are hidden —
  /// they are history pointers, not active notifications.
  includeSuperseded?: boolean;
}

export interface InsertResult {
  notification: Notification;
  /// If the insert had a `supersedes` field and the prior row existed, this
  /// is its id. The hub uses this to emit `notification.superseded` before
  /// `notification.show`.
  supersededOldId: string | null;
}

/// Persistence + a small set of mutators. No transport, no broadcast — the
/// hub wires those.
export class NotificationStore {
  private readonly db: BetterSqliteDatabase;
  private readonly insertStmt: Database.Statement;
  private readonly markSupersededStmt: Database.Statement;
  private readonly selectByIdStmt: Database.Statement;
  private readonly updateReadByStmt: Database.Statement;
  private readonly updateImportantStmt: Database.Statement;
  private readonly updateTtlUntilStmt: Database.Statement;
  private readonly deleteByIdStmt: Database.Statement;
  private readonly selectExpiredStmt: Database.Statement;
  private readonly deleteExpiredStmt: Database.Statement;
  /// Counts successful inserts since process start. Used by the hub to
  /// decide when to fire an opportunistic GC sweep (every Nth insert).
  /// Not persisted — a process restart is a fine moment to defer the next
  /// sweep until the count rebuilds.
  public insertCounter = 0;

  constructor(opts: InsertOptions = {}) {
    const dbPath = opts.dbPath ?? defaultDbPath();
    mkdirSync(dirname(dbPath), { recursive: true });
    this.db = new Database(dbPath);
    this.db.pragma("journal_mode = WAL");
    this.db.pragma("foreign_keys = ON");
    this.initSchema();

    this.insertStmt = this.db.prepare(`
      INSERT INTO notifications (
        id, source, level, title, body, payload, group_key,
        supersedes, superseded_by, important, timestamp, ttl_until,
        read_by, created_at
      ) VALUES (
        @id, @source, @level, @title, @body, @payload, @group_key,
        @supersedes, @superseded_by, @important, @timestamp, @ttl_until,
        @read_by, @created_at
      )
    `);
    this.markSupersededStmt = this.db.prepare(`
      UPDATE notifications SET superseded_by = ? WHERE id = ?
    `);
    this.selectByIdStmt = this.db.prepare(`
      SELECT * FROM notifications WHERE id = ?
    `);
    this.updateReadByStmt = this.db.prepare(`
      UPDATE notifications SET read_by = ? WHERE id = ?
    `);
    this.updateImportantStmt = this.db.prepare(`
      UPDATE notifications SET important = ? WHERE id = ?
    `);
    this.updateTtlUntilStmt = this.db.prepare(`
      UPDATE notifications SET ttl_until = ? WHERE id = ?
    `);
    this.deleteByIdStmt = this.db.prepare(`
      DELETE FROM notifications WHERE id = ?
    `);
    // GC condition: expired AND not pinned AND not part of a supersedes-
    // chain head (we keep history rows indefinitely so "show history" works).
    this.selectExpiredStmt = this.db.prepare(`
      SELECT id FROM notifications
      WHERE ttl_until IS NOT NULL
        AND ttl_until < ?
        AND important = 0
        AND superseded_by IS NULL
    `);
    this.deleteExpiredStmt = this.db.prepare(`
      DELETE FROM notifications
      WHERE ttl_until IS NOT NULL
        AND ttl_until < ?
        AND important = 0
        AND superseded_by IS NULL
    `);
  }

  private initSchema(): void {
    // schema_meta gives us somewhere to bump a version when migrations land.
    // In v0 we just record SCHEMA_VERSION=1.
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS schema_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS notifications (
        id            TEXT PRIMARY KEY,
        source        TEXT NOT NULL,
        level         TEXT NOT NULL,
        title         TEXT NOT NULL,
        body          TEXT,
        payload       TEXT,
        group_key     TEXT,
        supersedes    TEXT,
        superseded_by TEXT,
        important     INTEGER DEFAULT 0,
        timestamp     INTEGER NOT NULL,
        ttl_until     INTEGER,
        read_by       TEXT,
        created_at    INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_notifs_ts        ON notifications(timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_notifs_source_ts ON notifications(source, timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_notifs_group     ON notifications(group_key);
    `);
    const setVersion = this.db.prepare(
      `INSERT OR REPLACE INTO schema_meta (key, value) VALUES ('version', ?)`,
    );
    setVersion.run(String(SCHEMA_VERSION));
  }

  /// Insert a validated notification. Server-assigned fields (id, timestamp,
  /// ttl_until, created_at) are filled here. If `input.supersedes` references
  /// an existing row, that row's `superseded_by` is updated transactionally.
  public insert(input: NotificationInput): InsertResult {
    const id = randomUUID();
    const now = Date.now();
    const timestamp = input.timestamp ?? now;
    const important = input.important === true ? 1 : 0;
    // §4.5 contract: "default 7 days; important wins". An important
    // notification with no explicit ttl is pinned (ttl_until = null). An
    // important notification with an explicit ttl is honored (sender knows
    // best). A non-important notification gets DEFAULT_TTL_SECONDS unless
    // overridden.
    let ttlUntil: number | null;
    if (input.ttl !== undefined) {
      ttlUntil = timestamp + input.ttl * 1000;
    } else if (important === 1) {
      ttlUntil = null;
    } else {
      ttlUntil = timestamp + DEFAULT_TTL_SECONDS * 1000;
    }

    const payload: PayloadBlob = {};
    if (input.fields !== undefined) payload.fields = input.fields;
    if (input.links !== undefined) payload.links = input.links;
    if (input.action !== undefined) payload.action = input.action;
    if (input.widget !== undefined) payload.widget = input.widget;
    const payloadJson =
      Object.keys(payload).length > 0 ? JSON.stringify(payload) : null;

    let supersededOldId: string | null = null;
    const insertTx = this.db.transaction(() => {
      if (input.supersedes !== undefined) {
        const prior = this.selectByIdStmt.get(input.supersedes) as
          | DbRow
          | undefined;
        if (prior !== undefined) {
          this.markSupersededStmt.run(id, input.supersedes);
          supersededOldId = input.supersedes;
        }
      }
      this.insertStmt.run({
        id,
        source: input.source,
        level: input.level,
        title: input.title,
        body: input.body ?? null,
        payload: payloadJson,
        group_key: input.groupKey ?? null,
        supersedes: input.supersedes ?? null,
        superseded_by: null,
        important,
        timestamp,
        ttl_until: ttlUntil,
        read_by: null,
        created_at: now,
      });
    });
    insertTx();
    this.insertCounter++;

    const notification: Notification = rowToNotification({
      id,
      source: input.source,
      level: input.level,
      title: input.title,
      body: input.body ?? null,
      payload: payloadJson,
      group_key: input.groupKey ?? null,
      supersedes: input.supersedes ?? null,
      superseded_by: null,
      important,
      timestamp,
      ttl_until: ttlUntil,
      read_by: null,
      created_at: now,
    });
    return { notification, supersededOldId };
  }

  public get(id: string): Notification | null {
    const row = this.selectByIdStmt.get(id) as DbRow | undefined;
    if (row === undefined) return null;
    return rowToNotification(row);
  }

  public list(query: ListQuery): { items: Notification[]; cursor?: number } {
    const clauses: string[] = [];
    const args: Array<string | number> = [];
    if (typeof query.since === "number") {
      clauses.push("timestamp < ?");
      args.push(query.since);
    }
    if (typeof query.source === "string") {
      clauses.push("source = ?");
      args.push(query.source);
    }
    if (query.includeSuperseded !== true) {
      clauses.push("superseded_by IS NULL");
    }
    // includeRead defaults to true. When the caller supplies a deviceId AND
    // sets includeRead=false, hide rows whose `read_by` array contains that
    // device. SQLite's json_each lets us probe the array without dragging
    // the JSON column out into JS for every row. Rows with read_by IS NULL
    // (no reads yet) never match the exclusion subquery, so they stay.
    if (query.includeRead === false && typeof query.deviceId === "string") {
      clauses.push(
        `(read_by IS NULL OR NOT EXISTS (
          SELECT 1 FROM json_each(notifications.read_by) WHERE json_each.value = ?
        ))`,
      );
      args.push(query.deviceId);
    }
    const where = clauses.length > 0 ? `WHERE ${clauses.join(" AND ")}` : "";
    const sql = `
      SELECT * FROM notifications
      ${where}
      ORDER BY timestamp DESC
      LIMIT ?
    `;
    args.push(query.limit);
    const rows = this.db.prepare(sql).all(...args) as DbRow[];
    const items = rows.map(rowToNotification);
    const cursor =
      items.length === query.limit && items.length > 0
        ? items[items.length - 1]!.timestamp
        : undefined;
    return cursor === undefined ? { items } : { items, cursor };
  }

  /// Add `deviceId` to the row's `read_by` JSON array. Returns the ids that
  /// were actually changed (a row already containing the device id is a
  /// no-op and excluded from the result). The hub uses the returned set to
  /// decide whether to broadcast.
  public markRead(ids: string[], deviceId: string): string[] {
    const changed: string[] = [];
    const tx = this.db.transaction(() => {
      for (const id of ids) {
        const row = this.selectByIdStmt.get(id) as DbRow | undefined;
        if (row === undefined) continue;
        const readers = parseReadBy(row.read_by);
        if (readers.includes(deviceId)) continue;
        readers.push(deviceId);
        this.updateReadByStmt.run(JSON.stringify(readers), id);
        changed.push(id);
      }
    });
    tx();
    return changed;
  }

  /// Toggle the `important` flag. Promote → clear `ttl_until` (GC won't
  /// touch the row). Demote always re-anchors TTL at `now + DEFAULT_TTL_MS`,
  /// because promote wipes the original. If you need to preserve exact
  /// original windows, snapshot into a sidecar column on promote — deferred
  /// to v1.
  public markImportant(id: string, important: boolean): boolean {
    const row = this.selectByIdStmt.get(id) as DbRow | undefined;
    if (row === undefined) return false;
    const tx = this.db.transaction(() => {
      this.updateImportantStmt.run(important ? 1 : 0, id);
      if (important) {
        this.updateTtlUntilStmt.run(null, id);
      } else {
        this.updateTtlUntilStmt.run(
          Date.now() + DEFAULT_TTL_SECONDS * 1000,
          id,
        );
      }
    });
    tx();
    return true;
  }

  public delete(ids: string[]): string[] {
    const deleted: string[] = [];
    const tx = this.db.transaction(() => {
      for (const id of ids) {
        const row = this.selectByIdStmt.get(id) as DbRow | undefined;
        if (row === undefined) continue;
        this.deleteByIdStmt.run(id);
        deleted.push(id);
      }
    });
    tx();
    return deleted;
  }

  /// Run one GC sweep. Returns the ids that were deleted so the caller can
  /// broadcast `notification.deleted`. Select-then-delete in one transaction
  /// so a concurrent insert in the same DB doesn't get caught mid-sweep.
  public gcExpired(nowMs: number = Date.now()): string[] {
    const ids: string[] = [];
    const tx = this.db.transaction(() => {
      const rows = this.selectExpiredStmt.all(nowMs) as Array<{ id: string }>;
      for (const r of rows) ids.push(r.id);
      this.deleteExpiredStmt.run(nowMs);
    });
    tx();
    return ids;
  }

  public close(): void {
    this.db.close();
  }
}

function parseReadBy(raw: string | null): string[] {
  if (raw === null || raw.length === 0) return [];
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((s): s is string => typeof s === "string");
  } catch {
    return [];
  }
}

function rowToNotification(row: DbRow): Notification {
  const out: Notification = {
    id: row.id,
    source: row.source,
    level: row.level as NotificationLevel,
    title: row.title,
    timestamp: row.timestamp,
  };
  if (row.body !== null) out.body = row.body;
  if (row.group_key !== null) out.groupKey = row.group_key;
  if (row.supersedes !== null) out.supersedes = row.supersedes;
  if (row.superseded_by !== null) out.supersededBy = row.superseded_by;
  if (row.important === 1) out.important = true;
  if (row.ttl_until !== null) out.ttlUntil = row.ttl_until;
  const readers = parseReadBy(row.read_by);
  if (readers.length > 0) out.readBy = readers;
  if (row.payload !== null) {
    try {
      const blob = JSON.parse(row.payload) as PayloadBlob;
      if (blob.fields !== undefined) out.fields = blob.fields;
      if (blob.links !== undefined) out.links = blob.links;
      if (blob.action !== undefined) out.action = blob.action;
      if (blob.widget !== undefined) out.widget = blob.widget;
    } catch {
      // Corrupt payload blob → drop the optional fields silently. The row's
      // core data (title/body/level) is still useful.
    }
  }
  return out;
}

// ----- 5. Hub (in-process pub/sub between HTTP/RPC layers and fan-out) -----

export interface NotificationFanOut {
  show: (notification: Notification) => void;
  superseded: (oldId: string, newId: string) => void;
  readChanged: (ids: string[], readByDevice: string, ts: number) => void;
  deleted: (ids: string[]) => void;
}

/// Glue between the persistence layer and the WebSocket fan-out target. The
/// HTTP `/notify` endpoint and the `notification.*` RPC handlers both go
/// through this object; the WS fan-out helper is set by `ProcessState`.
///
/// GC is event-driven (conventions §1 — no recurring timers): a sweep runs
/// at most once per GC_MIN_INTERVAL_MS when `list` is called, and again
/// every GC_INSERT_PERIOD successful inserts. A backend that is neither
/// queried nor written to performs no sweep, which is correct: nothing is
/// changing.
export class NotificationHub {
  private readonly store: NotificationStore;
  private fanOut: NotificationFanOut | null = null;
  /// Wall-clock time of the last sweep; 0 means "never". Compared against
  /// `now - GC_MIN_INTERVAL_MS` in `maybeSweepOnList`.
  private lastSweepMs = 0;
  /// Single-flight guard: when `runGcOnce` is already executing (e.g. via a
  /// reentrant insert callback), skip overlapping calls instead of stacking.
  /// `gcExpired` is itself a SQLite transaction so the data layer is safe;
  /// this flag is about not duplicating fan-out broadcasts.
  private sweeping = false;

  constructor(store: NotificationStore) {
    this.store = store;
  }

  public attachFanOut(fanOut: NotificationFanOut): void {
    this.fanOut = fanOut;
  }

  /// Validate-and-persist a sender payload. Broadcasts `superseded` (if
  /// applicable) then `show`. Returns the assigned id so the HTTP endpoint
  /// can echo it back. Every GC_INSERT_PERIOD successful inserts triggers
  /// an opportunistic sweep after the row is persisted.
  public publish(rawPayload: unknown): { id: string } {
    const input = validateNotificationInput(rawPayload);
    const { notification, supersededOldId } = this.store.insert(input);
    if (this.fanOut !== null) {
      if (supersededOldId !== null) {
        this.fanOut.superseded(supersededOldId, notification.id);
      }
      this.fanOut.show(notification);
    }
    if (this.store.insertCounter % GC_INSERT_PERIOD === 0) {
      this.runGcOnceSafe();
    }
    return { id: notification.id };
  }

  public list(query: ListQuery): { items: Notification[]; cursor?: number } {
    this.maybeSweepOnList();
    return this.store.list(query);
  }

  public markRead(ids: string[], deviceId: string): void {
    const changed = this.store.markRead(ids, deviceId);
    if (changed.length > 0 && this.fanOut !== null) {
      this.fanOut.readChanged(changed, deviceId, Date.now());
    }
  }

  public markImportant(id: string, important: boolean): boolean {
    return this.store.markImportant(id, important);
  }

  public delete(ids: string[]): void {
    const deleted = this.store.delete(ids);
    if (deleted.length > 0 && this.fanOut !== null) {
      this.fanOut.deleted(deleted);
    }
  }

  /// Run a single GC pass. Exposed so tests can drive it deterministically
  /// (the production path is event-driven; tests still want a knob).
  /// Bypasses the single-flight guard — callers are responsible for
  /// serialization.
  public runGcOnce(nowMs?: number): string[] {
    const deleted = this.store.gcExpired(nowMs);
    this.lastSweepMs = nowMs ?? Date.now();
    if (deleted.length > 0 && this.fanOut !== null) {
      this.fanOut.deleted(deleted);
    }
    return deleted;
  }

  public close(): void {
    this.store.close();
  }

  /// Sweep on `notification.list` — rate-limited to once per
  /// GC_MIN_INTERVAL_MS so a flood of list calls doesn't hammer SQLite.
  /// Single-flighted so overlapping calls don't sweep twice.
  private maybeSweepOnList(): void {
    const now = Date.now();
    if (this.lastSweepMs !== 0 && now - this.lastSweepMs < GC_MIN_INTERVAL_MS) {
      return;
    }
    this.runGcOnceSafe(now);
  }

  /// Single-flight wrapper around `runGcOnce`. Used by both opportunistic
  /// trigger paths (insert-count + list-call). Swallows errors after
  /// logging — GC failure must never crash the backend.
  private runGcOnceSafe(nowMs?: number): void {
    if (this.sweeping) return;
    this.sweeping = true;
    try {
      this.runGcOnce(nowMs);
    } catch (err) {
      console.error("[notifications] gc sweep failed:", err);
    } finally {
      this.sweeping = false;
    }
  }
}
