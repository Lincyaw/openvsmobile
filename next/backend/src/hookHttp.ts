// Permissive sender endpoint — the paste-friendly counterpart to /notify.
// Three goals:
//
//   1. Make it cheap to wire third-party systems (Grafana, GitHub Actions,
//      iOS Shortcuts, monitoring scripts) into the notification surface
//      without writing JSON by hand.
//   2. Keep `source` authoritative-from-URL so a token's source-prefix
//      restriction cannot be bypassed by anything in the body.
//   3. Support both header-auth (`Authorization: Bearer …`) and path-
//      segment auth (`/hook/<id>.<secret>/…`) so the URL itself can be the
//      full credential for `GET`-only senders.
//
// Wire shape (see also docs/design/mobile-code-platform.md §4.5):
//
//   POST /hook/<id>.<secret>/<source>          path-segment auth
//   POST /hook/<source>                        Authorization header
//   GET  /hook/<id>.<secret>/<source>?title=…  GET form (query-string only)
//
// Accepted bodies:
//   - application/json                full Notification, sans `source`
//   - application/x-www-form-urlencoded   flat k=v, aliases applied
//   - text/plain (or missing CT)      whole body → notification body;
//                                     title derived from first non-empty
//                                     line unless ?title= overrides
//
// Idempotency: optional `Idempotency-Key` header (≤128 chars) — duplicate
// keys within 24h return the original notification id without re-publishing.

import type { IncomingMessage, ServerResponse } from "node:http";
import { RpcError } from "./rpc.js";
import type { NotificationHub, NotificationLevel } from "./notifications.js";
import type { TokenStore } from "./tokenStore.js";
import {
  AuthError,
  authenticateSender,
  enforcePublishLimits,
  writeAuthError,
  type AuthOutcome,
} from "./senderAuth.js";

const MAX_BODY_BYTES = 1 * 1024 * 1024;
const MAX_QUERY_BYTES = 8 * 1024;
const SOURCE_MAX_LEN = 64;
const SOURCE_PATTERN = /^[A-Za-z0-9._:-]+$/;
const IDEMPOTENCY_KEY_MAX = 128;
const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000;
const TITLE_MAX_LEN = 80;
const LEVEL_VALUES = new Set<NotificationLevel>([
  "info",
  "success",
  "warning",
  "error",
]);
/// Coercion table for the looser inputs (form + query). The canonical
/// `level` field is one of `info|success|warning|error`; common synonyms
/// from third-party systems are accepted and mapped here. Keep the table
/// flat — readers should be able to scan the legal inputs at a glance.
const LEVEL_ALIASES: Record<string, NotificationLevel> = {
  info: "info",
  success: "success",
  warning: "warning",
  error: "error",
  low: "info",
  high: "warning",
  critical: "error",
};

// ----- 1. Idempotency cache (in-memory, lazy expiry) -----

interface IdempotencyEntry {
  id: string;
  expiresAt: number;
}

class IdempotencyCache {
  private readonly entries = new Map<string, IdempotencyEntry>();

  get(key: string, now: number): string | null {
    const hit = this.entries.get(key);
    if (hit === undefined) return null;
    if (hit.expiresAt < now) {
      this.entries.delete(key);
      return null;
    }
    return hit.id;
  }

  put(key: string, id: string, now: number): void {
    this.entries.set(key, { id, expiresAt: now + IDEMPOTENCY_TTL_MS });
    // Opportunistic cleanup — cap unbounded growth without a timer.
    if (this.entries.size > 10_000) {
      for (const [k, v] of this.entries) {
        if (v.expiresAt < now) this.entries.delete(k);
      }
    }
  }
}

// ----- 2. URL parsing -----

interface HookUrl {
  /// If present, the `<id>.<secret>` path token, passed to the auth helper
  /// as a path-bound credential.
  pathToken: string | undefined;
  source: string;
  query: URLSearchParams;
}

/// Parse `/hook/[<id>.<secret>/]<source>[?qs]` and return its parts.
/// Returns null if the URL doesn't match this shape.
function parseHookUrl(rawUrl: string): HookUrl | null {
  // Use a dummy base — we only care about pathname + query.
  const u = new URL(rawUrl, "http://x");
  if (!u.pathname.startsWith("/hook/")) return null;
  const tail = u.pathname.slice("/hook/".length);
  if (tail.length === 0) return null;
  const parts = tail.split("/").filter((p) => p.length > 0);
  let pathToken: string | undefined;
  let source: string;
  if (parts.length === 1) {
    source = parts[0]!;
  } else if (parts.length === 2) {
    // First segment may be the `<id>.<secret>` credential. We don't
    // verify here — the auth helper does — but we *do* require a `.`
    // before treating it as a credential, otherwise it's ambiguous with
    // a multi-segment source (which we explicitly don't support).
    if (!parts[0]!.includes(".")) return null;
    pathToken = parts[0]!;
    source = parts[1]!;
  } else {
    return null;
  }
  source = decodeURIComponent(source);
  if (source.length === 0 || source.length > SOURCE_MAX_LEN) return null;
  if (!SOURCE_PATTERN.test(source)) return null;
  return { pathToken, source, query: u.searchParams };
}

// ----- 3. Field coercion -----

/// Apply the form/query alias table. Mutates and returns a partial
/// Notification suitable for handoff to `hub.publish`.
function applyAliases(
  raw: Record<string, string>,
  source: string,
): Record<string, unknown> {
  const out: Record<string, unknown> = { source };

  // Title — first alias to fire wins. Truncate silently rather than
  // rejecting; webhook senders frequently emit oversized subjects.
  const title =
    raw.title ?? raw.subject ?? raw.summary;
  if (typeof title === "string" && title.length > 0) {
    out.title = title.length > TITLE_MAX_LEN ? title.slice(0, TITLE_MAX_LEN) : title;
  }

  const body = raw.body ?? raw.message ?? raw.text ?? raw.description;
  if (typeof body === "string" && body.length > 0) out.body = body;

  const lvlRaw =
    (raw.level ?? raw.severity ?? raw.priority ?? "").toLowerCase();
  if (lvlRaw.length > 0) {
    const mapped = LEVEL_ALIASES[lvlRaw];
    if (mapped !== undefined) out.level = mapped;
    // Unknown level values are silently ignored — default fires below.
  }
  if (out.level === undefined) out.level = "info";

  const group = raw.groupKey ?? raw.group_key ?? raw.group ?? raw.dedup;
  if (typeof group === "string" && group.length > 0) out.groupKey = group;

  if (raw.important !== undefined) {
    const v = raw.important.toLowerCase();
    if (v === "1" || v === "true" || v === "yes") out.important = true;
  }
  if (raw.pinned !== undefined && out.important === undefined) {
    const v = raw.pinned.toLowerCase();
    if (v === "1" || v === "true" || v === "yes") out.important = true;
  }

  const ttlRaw = raw.ttl ?? raw.ttl_seconds;
  if (ttlRaw !== undefined) {
    const n = Number(ttlRaw);
    if (Number.isFinite(n) && n >= 0) out.ttl = n;
  }

  if (raw.supersedes !== undefined && raw.supersedes.length > 0) {
    out.supersedes = raw.supersedes;
  }

  // `url=` sugar — bare URL becomes an open-url action.
  if (typeof raw.url === "string" && raw.url.length > 0) {
    out.action = { kind: "open-url", url: raw.url };
  }

  return out;
}

function deriveTitleFromBody(body: string): string | null {
  for (const line of body.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed.length > 0) {
      return trimmed.length > TITLE_MAX_LEN
        ? trimmed.slice(0, TITLE_MAX_LEN)
        : trimmed;
    }
  }
  return null;
}

/// Validate that a JSON body conforms to the §4.5 shape modulo the
/// `source` invariant (must be absent — URL is authoritative).
function preflightJson(
  body: unknown,
): Record<string, unknown> {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new HookError(400, "json body must be an object");
  }
  const rec = body as Record<string, unknown>;
  if ("source" in rec) {
    throw new HookError(400, "source in body conflicts with URL");
  }
  // Defaulting: callers using JSON path get the same default level as the
  // form/query path, so `{"title":"…"}` is sufficient.
  if (rec.level === undefined) rec.level = "info";
  if (typeof rec.level === "string" && !LEVEL_VALUES.has(rec.level as NotificationLevel)) {
    const mapped = LEVEL_ALIASES[rec.level.toLowerCase()];
    if (mapped !== undefined) rec.level = mapped;
  }
  return rec;
}

class HookError extends Error {
  constructor(public readonly status: number, message: string) {
    super(message);
  }
}

// ----- 4. Body reader -----

interface BodyResult {
  bytes: number;
  text: string;
}

function readBody(req: IncomingMessage): Promise<BodyResult> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;
    let rejected = false;
    req.on("data", (chunk: Buffer) => {
      if (rejected) return;
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        rejected = true;
        chunks.length = 0;
        reject(new HookError(413, "payload too large"));
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (rejected) return;
      const text = Buffer.concat(chunks).toString("utf8");
      resolve({ bytes: total, text });
    });
    req.on("error", (err) => {
      if (!rejected) reject(err);
    });
  });
}

// ----- 5. Handler -----

export interface HookHttpDeps {
  expectedToken: string;
  hub: NotificationHub;
  tokenStore: TokenStore;
}

export class HookHandler {
  /// Single shared idempotency cache. Module-level singleton would also
  /// work; instance-scoped keeps tests hermetic.
  private readonly idem = new IdempotencyCache();

  constructor(private readonly deps: HookHttpDeps) {}

  async handle(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<boolean> {
    const url = req.url ?? "";
    if (!url.startsWith("/hook/")) return false;

    try {
      await this.dispatch(req, res, url);
    } catch (err) {
      if (err instanceof HookError) {
        res.statusCode = err.status;
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ error: err.message }));
        return true;
      }
      if (err instanceof AuthError) {
        writeAuthError(res, err);
        return true;
      }
      console.error("[hook] handler error:", err);
      if (!res.headersSent) {
        res.statusCode = 500;
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ error: "internal error" }));
      }
      return true;
    }
    return true;
  }

  private async dispatch(
    req: IncomingMessage,
    res: ServerResponse,
    url: string,
  ): Promise<void> {
    const method = req.method ?? "GET";
    if (method !== "POST" && method !== "GET") {
      throw new HookError(405, "method not allowed");
    }
    const parsed = parseHookUrl(url);
    if (parsed === null) throw new HookError(404, "not found");
    if (req.url !== undefined && req.url.length > MAX_QUERY_BYTES) {
      throw new HookError(414, "url too long");
    }

    let outcome: AuthOutcome;
    try {
      outcome = authenticateSender(req, {
        authToken: this.deps.expectedToken,
        tokenStore: this.deps.tokenStore,
        pathToken: parsed.pathToken,
      });
    } catch (err) {
      // Bubble up — wrapped to AuthError in dispatch caller.
      throw err;
    }

    // Idempotency key — applied across auth classes. Keyed on the raw
    // header alone (no per-token namespace) because key collisions across
    // tokens are vanishingly unlikely for ≤128-char keys and the
    // intended semantic is "same caller retrying same event".
    const idemHeader = req.headers["idempotency-key"];
    let idempotencyKey: string | null = null;
    if (typeof idemHeader === "string") {
      if (idemHeader.length > IDEMPOTENCY_KEY_MAX) {
        throw new HookError(400, "idempotency-key too long");
      }
      idempotencyKey = idemHeader;
      const cached = this.idem.get(idempotencyKey, Date.now());
      if (cached !== null) {
        // Replay — same response shape, no second publish.
        res.statusCode = 200;
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ id: cached, idempotent: true }));
        return;
      }
    }

    let input: Record<string, unknown>;
    if (method === "GET") {
      input = this.fromQuery(parsed.query, parsed.source);
    } else {
      input = await this.fromBody(req, parsed);
    }

    enforcePublishLimits(outcome, parsed.source, this.deps.tokenStore);

    let id: string;
    try {
      ({ id } = this.deps.hub.publish(input));
    } catch (err) {
      if (err instanceof RpcError) {
        throw new HookError(400, err.message);
      }
      throw err;
    }

    if (idempotencyKey !== null) {
      this.idem.put(idempotencyKey, id, Date.now());
    }

    // Audit log: token id (or "auth"), source, content-type, bytes-in.
    // The hub already logs the publish itself; we add the perimeter
    // shape so a misbehaving sender can be traced without dumping the
    // body.
    const tokenLabel =
      outcome.kind === "auth" ? "auth" : `pub:${outcome.record.id}`;
    console.error(
      `[hook] published id=${id} source=${parsed.source} token=${tokenLabel} method=${method}`,
    );

    res.statusCode = 200;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ id }));
  }

  private fromQuery(
    qs: URLSearchParams,
    source: string,
  ): Record<string, unknown> {
    const flat: Record<string, string> = {};
    for (const [k, v] of qs.entries()) flat[k] = v;
    const out = applyAliases(flat, source);
    if (out.title === undefined) {
      throw new HookError(400, "title required (no body to derive from)");
    }
    return out;
  }

  private async fromBody(
    req: IncomingMessage,
    parsed: HookUrl,
  ): Promise<Record<string, unknown>> {
    const ct = (req.headers["content-type"] ?? "").toLowerCase().split(";")[0]!.trim();
    const isJson = ct === "application/json";
    const isForm = ct === "application/x-www-form-urlencoded";
    const isPlain = ct === "text/plain" || ct === "";
    if (!isJson && !isForm && !isPlain) {
      throw new HookError(415, "unsupported content type");
    }
    const { text } = await readBody(req);

    if (isJson) {
      let body: unknown;
      try {
        body = JSON.parse(text);
      } catch {
        throw new HookError(400, "invalid json");
      }
      const rec = preflightJson(body);
      rec.source = parsed.source;
      return rec;
    }

    if (isForm) {
      const flat: Record<string, string> = {};
      for (const [k, v] of new URLSearchParams(text).entries()) flat[k] = v;
      // Query-string fallback for fields not in the form body. Lets a
      // sender mix the two (e.g. URL carries level, body carries text).
      for (const [k, v] of parsed.query.entries()) {
        if (!(k in flat)) flat[k] = v;
      }
      const out = applyAliases(flat, parsed.source);
      if (out.title === undefined) {
        throw new HookError(400, "title required");
      }
      return out;
    }

    // text/plain — body is the body; title from query or from first line.
    const flat: Record<string, string> = {};
    for (const [k, v] of parsed.query.entries()) flat[k] = v;
    const out = applyAliases(flat, parsed.source);
    if (text.length > 0) out.body = text;
    if (out.title === undefined) {
      const derived = text.length > 0 ? deriveTitleFromBody(text) : null;
      if (derived === null) {
        throw new HookError(400, "title required (empty body, no ?title=)");
      }
      out.title = derived;
    }
    return out;
  }
}
