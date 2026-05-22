// Publish-token store. Implements §4.5 "Auth and publish tokens" of the
// design doc.
//
// The single bearer in `config.json` (the *auth* token, see `config.ts`)
// continues to authenticate everything. Publish tokens are a second token
// class that authenticates *only* the sender endpoints (`/notify`, `/hook`),
// can be source-prefix-scoped, rate-limited, and revoked individually.
//
// Wire form: publish tokens always appear on the wire as `<id>.<secret>`
// (with a literal `.`), distinguishing them from the dotless auth token.
// Endpoints accept either:
//   - `Authorization: Bearer <id>.<secret>`  (any sender endpoint)
//   - path segment `/hook/<id>.<secret>/...` (paste-friendly URL form,
//     consumed by hookHttp.ts)
//
// Only `sha256(secret)` is persisted. Mint returns the plaintext secret
// exactly once; a lost token must be revoked and re-issued.

import Database from "better-sqlite3";
import type { Database as BetterSqliteDatabase } from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { createHash, randomBytes } from "node:crypto";

// ----- 1. Constants -----

const DEFAULT_RATE_PER_MIN = 60;
const DEFAULT_RATE_PER_HOUR = 600;
const LABEL_MAX_LEN = 80;
const SOURCE_PREFIX_MAX_LEN = 128;
/// Token id is 6 random bytes hex => 12 chars. Collision-resistant enough
/// for a single-user setup; short enough to land cleanly in URLs and logs.
const ID_BYTES = 6;
const ID_HEX_LEN = ID_BYTES * 2;
/// Secret is 32 bytes hex => 64 chars. Sized for offline brute-force
/// resistance even if `secret_hash` ever leaks.
const SECRET_BYTES = 32;
const SECRET_HEX_LEN = SECRET_BYTES * 2;
/// Debounce window for `last_used_at` writes — at most one disk write per
/// token per minute. Eliminates the row-write on every publish.
const LAST_USED_DEBOUNCE_MS = 60 * 1000;
/// Allowed chars for source prefix. Same charset the design doc requires
/// for the path-segment `<source>` so prefix-vs-source comparison can never
/// pivot on encoding rules.
const SOURCE_PREFIX_PATTERN = /^[A-Za-z0-9._:-]+$/;

// ----- 2. Types -----

export interface PublishTokenRecord {
  id: string;
  /// Plain-text secret. Only present on `mint()` results; never returned by
  /// `list()` / `lookup()`.
  secret?: string;
  label: string;
  /// null = no source restriction.
  sourcePrefix: string | null;
  rateLimitPerMin: number;
  rateLimitPerHour: number;
  createdAt: number;
  lastUsedAt: number | null;
  revokedAt: number | null;
}

/// Same as `PublishTokenRecord` minus `secret`, for `list()` consumers.
export type PublishTokenSummary = Omit<PublishTokenRecord, "secret">;

export interface MintOptions {
  label: string;
  sourcePrefix?: string;
  rateLimitPerMin?: number;
  rateLimitPerHour?: number;
}

export interface MintResult {
  id: string;
  /// `<id>.<secret>` — the full wire form. Display this to the user; we
  /// can't reconstruct it later.
  token: string;
}

export interface LookupResult {
  record: PublishTokenSummary;
}

export type RateLimitOutcome =
  | { ok: true; remainingMin: number; remainingHour: number }
  | { ok: false; retryAfterSeconds: number };

interface DbRow {
  id: string;
  secret_hash: string;
  label: string;
  source_prefix: string | null;
  rate_limit_per_min: number;
  rate_limit_per_hour: number;
  created_at: number;
  last_used_at: number | null;
  revoked_at: number | null;
}

// ----- 3. Helpers -----

export class TokenError extends Error {
  /// `code` maps onto the HTTP / RPC layer:
  ///   - `bad-format`   → 401 (malformed wire token; treat as unauthenticated)
  ///   - `unknown`      → 401 (no row, or hash mismatch)
  ///   - `revoked`      → 401
  ///   - `source-denied`→ 403 (token is valid but `source` outside prefix)
  ///   - `rate-limited` → 429
  ///   - `invalid-args` → 400 (mint/relabel argument violation)
  constructor(
    public readonly code:
      | "bad-format"
      | "unknown"
      | "revoked"
      | "source-denied"
      | "rate-limited"
      | "invalid-args",
    message: string,
  ) {
    super(message);
  }
}

function sha256Hex(s: string): string {
  return createHash("sha256").update(s, "utf8").digest("hex");
}

function defaultDbPath(): string {
  const override = process.env.OPENVSMOBILE_TOKENS_DB;
  if (override && override.length > 0) return override;
  // Under vitest, fall back to an in-process temp file so callers that
  // don't supply a path (most of the non-token-focused suites) don't
  // contaminate the user's real config directory. Production callers
  // either pass `dbPath` explicitly or hit the real homedir path below.
  if (process.env.VITEST === "true" || process.env.NODE_ENV === "test") {
    return join(
      tmpdir(),
      `ovsm-tokens-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}.db`,
    );
  }
  return join(homedir(), ".config", "openvsmobile-next", "tokens.db");
}

/// Parse `<id>.<secret>`. Returns null if the input doesn't conform; the
/// caller treats null as "not a publish token" (the auth token has no `.`).
export function parsePublishToken(
  wire: string,
): { id: string; secret: string } | null {
  if (wire.length !== ID_HEX_LEN + 1 + SECRET_HEX_LEN) return null;
  if (wire[ID_HEX_LEN] !== ".") return null;
  const id = wire.slice(0, ID_HEX_LEN);
  const secret = wire.slice(ID_HEX_LEN + 1);
  if (!/^[a-f0-9]+$/.test(id) || !/^[a-f0-9]+$/.test(secret)) return null;
  return { id, secret };
}

/// Source-prefix match. `null` prefix means "any source allowed". A
/// non-null prefix matches iff `source === prefix` OR
/// `source.startsWith(prefix + ":")` — the colon boundary prevents
/// `claude-code` from matching `claude-code-rogue`.
export function sourceMatchesPrefix(
  prefix: string | null,
  source: string,
): boolean {
  if (prefix === null) return true;
  if (source === prefix) return true;
  if (source.startsWith(prefix + ":")) return true;
  return false;
}

// ----- 4. Rate limiter -----

interface BucketState {
  minuteWindow: number;
  minuteCount: number;
  hourWindow: number;
  hourCount: number;
}

/// Per-token leaky-bucket-by-window. Reset on each new window. State is
/// in-memory only — surviving a restart as "burst reset" is acceptable
/// (the alternative is touching disk on every publish).
class RateLimiter {
  private readonly buckets = new Map<string, BucketState>();

  consume(
    tokenId: string,
    perMin: number,
    perHour: number,
    now: number,
  ): RateLimitOutcome {
    const minuteWindow = Math.floor(now / 60_000);
    const hourWindow = Math.floor(now / 3_600_000);
    let b = this.buckets.get(tokenId);
    if (b === undefined) {
      b = { minuteWindow, minuteCount: 0, hourWindow, hourCount: 0 };
      this.buckets.set(tokenId, b);
    }
    if (b.minuteWindow !== minuteWindow) {
      b.minuteWindow = minuteWindow;
      b.minuteCount = 0;
    }
    if (b.hourWindow !== hourWindow) {
      b.hourWindow = hourWindow;
      b.hourCount = 0;
    }
    if (b.minuteCount >= perMin) {
      // Round up — clients should not retry until the next window starts.
      const retry = 60 - Math.floor((now % 60_000) / 1000);
      return { ok: false, retryAfterSeconds: retry };
    }
    if (b.hourCount >= perHour) {
      const retry = 3600 - Math.floor((now % 3_600_000) / 1000);
      return { ok: false, retryAfterSeconds: retry };
    }
    b.minuteCount += 1;
    b.hourCount += 1;
    return {
      ok: true,
      remainingMin: perMin - b.minuteCount,
      remainingHour: perHour - b.hourCount,
    };
  }

  forget(tokenId: string): void {
    this.buckets.delete(tokenId);
  }
}

// ----- 5. Store -----

export interface TokenStoreOptions {
  dbPath?: string;
  /// Optional clock injection for tests.
  now?: () => number;
}

export class TokenStore {
  private readonly db: BetterSqliteDatabase;
  private readonly now: () => number;
  private readonly rateLimiter = new RateLimiter();
  /// In-memory mirror of every non-revoked token. Refreshed on every
  /// mutation. `lookup()` reads from this; the DB is the audit log + the
  /// source of truth across restarts.
  private cache = new Map<string, PublishTokenSummary & { secretHash: string }>();
  /// In-memory tracker for `last_used_at` debounce. Maps token id → epoch
  /// ms of the most-recent persisted write.
  private readonly lastUsedWrites = new Map<string, number>();

  private readonly insertStmt: Database.Statement;
  private readonly selectActiveStmt: Database.Statement;
  private readonly selectAllStmt: Database.Statement;
  private readonly revokeStmt: Database.Statement;
  private readonly relabelStmt: Database.Statement;
  private readonly touchStmt: Database.Statement;

  constructor(opts: TokenStoreOptions = {}) {
    const dbPath = opts.dbPath ?? defaultDbPath();
    mkdirSync(dirname(dbPath), { recursive: true });
    this.db = new Database(dbPath);
    this.db.pragma("journal_mode = WAL");
    this.now = opts.now ?? (() => Date.now());

    this.db.exec(`
      CREATE TABLE IF NOT EXISTS publish_tokens (
        id                  TEXT PRIMARY KEY,
        secret_hash         TEXT NOT NULL,
        label               TEXT NOT NULL,
        source_prefix       TEXT,
        rate_limit_per_min  INTEGER NOT NULL DEFAULT ${DEFAULT_RATE_PER_MIN},
        rate_limit_per_hour INTEGER NOT NULL DEFAULT ${DEFAULT_RATE_PER_HOUR},
        created_at          INTEGER NOT NULL,
        last_used_at        INTEGER,
        revoked_at          INTEGER
      );
      CREATE INDEX IF NOT EXISTS idx_pub_tok_revoked ON publish_tokens(revoked_at);
    `);

    this.insertStmt = this.db.prepare(`
      INSERT INTO publish_tokens (
        id, secret_hash, label, source_prefix,
        rate_limit_per_min, rate_limit_per_hour,
        created_at, last_used_at, revoked_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL)
    `);
    this.selectActiveStmt = this.db.prepare(`
      SELECT * FROM publish_tokens WHERE revoked_at IS NULL
    `);
    this.selectAllStmt = this.db.prepare(`
      SELECT * FROM publish_tokens ORDER BY created_at DESC
    `);
    this.revokeStmt = this.db.prepare(`
      UPDATE publish_tokens SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL
    `);
    this.relabelStmt = this.db.prepare(`
      UPDATE publish_tokens SET label = ? WHERE id = ? AND revoked_at IS NULL
    `);
    this.touchStmt = this.db.prepare(`
      UPDATE publish_tokens SET last_used_at = ? WHERE id = ?
    `);

    this.reloadCache();
  }

  private reloadCache(): void {
    const rows = this.selectActiveStmt.all() as DbRow[];
    const next = new Map<string, PublishTokenSummary & { secretHash: string }>();
    for (const r of rows) {
      next.set(r.id, {
        id: r.id,
        secretHash: r.secret_hash,
        label: r.label,
        sourcePrefix: r.source_prefix,
        rateLimitPerMin: r.rate_limit_per_min,
        rateLimitPerHour: r.rate_limit_per_hour,
        createdAt: r.created_at,
        lastUsedAt: r.last_used_at,
        revokedAt: r.revoked_at,
      });
    }
    this.cache = next;
  }

  /// Create a new token. Returns the *plaintext* `<id>.<secret>` once. The
  /// caller must show it to the user and discard it — we have no way to
  /// recover it.
  mint(opts: MintOptions): MintResult {
    if (typeof opts.label !== "string" || opts.label.length === 0) {
      throw new TokenError("invalid-args", "label required");
    }
    if (opts.label.length > LABEL_MAX_LEN) {
      throw new TokenError(
        "invalid-args",
        `label exceeds ${LABEL_MAX_LEN} chars`,
      );
    }
    let sourcePrefix: string | null = null;
    if (opts.sourcePrefix !== undefined && opts.sourcePrefix !== null) {
      if (
        typeof opts.sourcePrefix !== "string" ||
        opts.sourcePrefix.length === 0
      ) {
        throw new TokenError("invalid-args", "sourcePrefix must be non-empty");
      }
      if (opts.sourcePrefix.length > SOURCE_PREFIX_MAX_LEN) {
        throw new TokenError(
          "invalid-args",
          `sourcePrefix exceeds ${SOURCE_PREFIX_MAX_LEN} chars`,
        );
      }
      if (!SOURCE_PREFIX_PATTERN.test(opts.sourcePrefix)) {
        throw new TokenError(
          "invalid-args",
          "sourcePrefix must match [A-Za-z0-9._:-]+",
        );
      }
      sourcePrefix = opts.sourcePrefix;
    }
    const perMin = opts.rateLimitPerMin ?? DEFAULT_RATE_PER_MIN;
    const perHour = opts.rateLimitPerHour ?? DEFAULT_RATE_PER_HOUR;
    if (!Number.isInteger(perMin) || perMin < 1 || perMin > 100_000) {
      throw new TokenError("invalid-args", "rateLimitPerMin out of range");
    }
    if (!Number.isInteger(perHour) || perHour < 1 || perHour > 10_000_000) {
      throw new TokenError("invalid-args", "rateLimitPerHour out of range");
    }
    if (perHour < perMin) {
      throw new TokenError(
        "invalid-args",
        "rateLimitPerHour must be ≥ rateLimitPerMin",
      );
    }

    // Retry on the astronomical chance of an id collision. Should never fire.
    for (let attempt = 0; attempt < 5; attempt++) {
      const id = randomBytes(ID_BYTES).toString("hex");
      if (this.cache.has(id)) continue;
      const secret = randomBytes(SECRET_BYTES).toString("hex");
      const hash = sha256Hex(secret);
      try {
        this.insertStmt.run(
          id,
          hash,
          opts.label,
          sourcePrefix,
          perMin,
          perHour,
          this.now(),
        );
      } catch (err) {
        // UNIQUE constraint on id — retry
        if (String(err).includes("UNIQUE")) continue;
        throw err;
      }
      this.reloadCache();
      return { id, token: `${id}.${secret}` };
    }
    throw new Error("could not allocate unique token id after 5 attempts");
  }

  /// Validate a wire token (`<id>.<secret>`) and return the matching record.
  /// Throws `TokenError` with `bad-format` / `unknown` / `revoked`. Does
  /// **not** consume rate limit and does **not** touch `last_used_at` —
  /// those are separate calls so the caller can layer the checks (auth →
  /// source-prefix → rate-limit) without paying for them on rejects.
  lookup(wire: string): PublishTokenSummary {
    const parsed = parsePublishToken(wire);
    if (parsed === null) {
      throw new TokenError("bad-format", "not a publish token");
    }
    const entry = this.cache.get(parsed.id);
    if (entry === undefined) {
      // Either the id never existed or it was revoked. Don't tell the
      // caller which — both are 401 from the perimeter's perspective.
      throw new TokenError("unknown", "unknown token");
    }
    const want = sha256Hex(parsed.secret);
    if (!constantTimeEqual(want, entry.secretHash)) {
      throw new TokenError("unknown", "unknown token");
    }
    // Don't leak the hash to callers.
    const { secretHash: _h, ...summary } = entry;
    void _h;
    return summary;
  }

  /// Enforce source-prefix scope. Throws `TokenError("source-denied")` if
  /// `record.sourcePrefix` is non-null and `source` does not match.
  checkSourceAllowed(record: PublishTokenSummary, source: string): void {
    if (!sourceMatchesPrefix(record.sourcePrefix, source)) {
      throw new TokenError(
        "source-denied",
        `source "${source}" not permitted by token`,
      );
    }
  }

  /// Consume one rate-limit credit. Throws `TokenError("rate-limited")`
  /// with `retryAfterSeconds` stashed on the error.
  consumeRate(record: PublishTokenSummary): RateLimitOutcome {
    const outcome = this.rateLimiter.consume(
      record.id,
      record.rateLimitPerMin,
      record.rateLimitPerHour,
      this.now(),
    );
    if (!outcome.ok) {
      const err = new TokenError(
        "rate-limited",
        `rate limit exceeded (retry in ${outcome.retryAfterSeconds}s)`,
      );
      // Attach retry hint for the HTTP layer.
      (err as TokenError & { retryAfterSeconds?: number }).retryAfterSeconds =
        outcome.retryAfterSeconds;
      throw err;
    }
    return outcome;
  }

  /// Update `last_used_at` for `tokenId`, debounced so disk writes happen
  /// at most once per `LAST_USED_DEBOUNCE_MS` per token. Safe to call on
  /// the hot path.
  touch(tokenId: string): void {
    const now = this.now();
    const lastWrite = this.lastUsedWrites.get(tokenId) ?? 0;
    if (now - lastWrite < LAST_USED_DEBOUNCE_MS) return;
    this.lastUsedWrites.set(tokenId, now);
    this.touchStmt.run(now, tokenId);
    // Cache stays in sync — the lastUsedAt value users see may lag by up
    // to the debounce window, which is the entire point.
    const entry = this.cache.get(tokenId);
    if (entry !== undefined) entry.lastUsedAt = now;
  }

  /// Return summary records. Includes revoked tokens when
  /// `includeRevoked=true` (for audit views). Secrets are never returned.
  list(opts: { includeRevoked?: boolean } = {}): PublishTokenSummary[] {
    const rows = (
      opts.includeRevoked === true
        ? (this.selectAllStmt.all() as DbRow[])
        : (this.selectActiveStmt.all() as DbRow[])
    ).map(
      (r): PublishTokenSummary => ({
        id: r.id,
        label: r.label,
        sourcePrefix: r.source_prefix,
        rateLimitPerMin: r.rate_limit_per_min,
        rateLimitPerHour: r.rate_limit_per_hour,
        createdAt: r.created_at,
        lastUsedAt: r.last_used_at,
        revokedAt: r.revoked_at,
      }),
    );
    return rows;
  }

  /// Idempotent revoke. Returns true if a row was actually revoked by
  /// this call; false if it was already revoked or never existed.
  revoke(id: string): boolean {
    const result = this.revokeStmt.run(this.now(), id);
    const changed = result.changes > 0;
    if (changed) {
      this.cache.delete(id);
      this.rateLimiter.forget(id);
      this.lastUsedWrites.delete(id);
    }
    return changed;
  }

  /// Change the human label. Returns true on success, false on
  /// missing / revoked.
  relabel(id: string, label: string): boolean {
    if (typeof label !== "string" || label.length === 0) {
      throw new TokenError("invalid-args", "label required");
    }
    if (label.length > LABEL_MAX_LEN) {
      throw new TokenError(
        "invalid-args",
        `label exceeds ${LABEL_MAX_LEN} chars`,
      );
    }
    const result = this.relabelStmt.run(label, id);
    if (result.changes === 0) return false;
    const entry = this.cache.get(id);
    if (entry !== undefined) entry.label = label;
    return true;
  }

  close(): void {
    this.db.close();
  }
}

/// Constant-time string equality for hex strings. Prevents a timing oracle
/// on `secret_hash` lookup even though our threat model (single-user)
/// doesn't strictly require it.
function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}
