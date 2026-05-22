// Shared auth + rate-limit + source-prefix enforcement for sender
// endpoints (`/notify`, `/hook`). Both endpoints accept either the single
// `auth` token from config.json OR a publish token (`<id>.<secret>`); both
// run the same downstream checks (source-prefix, rate-limit, touch
// last_used). Centralizing here keeps the two HTTP handlers parallel and
// makes future endpoints (e.g. a metrics ingest) wire in for free.
//
// See docs/design/mobile-code-platform.md §4.5.

import type { IncomingMessage, ServerResponse } from "node:http";
import {
  TokenError,
  type PublishTokenSummary,
  type TokenStore,
} from "./tokenStore.js";

export type AuthOutcome =
  | { kind: "auth" }
  | { kind: "publish"; record: PublishTokenSummary };

export class AuthError extends Error {
  constructor(
    public readonly status: number,
    public readonly body: { error: string },
    public readonly retryAfterSeconds?: number,
  ) {
    super(body.error);
  }
}

/// Pull the bearer secret from an `Authorization: Bearer <…>` header, OR
/// from a path-segment `<id>.<secret>` (the form used by /hook URLs).
/// `pathToken` is undefined for endpoints that don't accept path-segment
/// auth (such as /notify).
function extractCredential(
  req: IncomingMessage,
  pathToken: string | undefined,
): string | null {
  const header = req.headers["authorization"];
  if (typeof header === "string" && header.startsWith("Bearer ")) {
    const v = header.slice("Bearer ".length).trim();
    if (v.length > 0) return v;
  }
  if (pathToken !== undefined && pathToken.length > 0) return pathToken;
  return null;
}

/// Authenticate a sender. Returns either:
///   - `{ kind: "auth" }`  — the request used the auth token (full power)
///   - `{ kind: "publish", record }` — a valid publish token
///
/// Throws AuthError(401) on missing/invalid credential, AuthError(401)
/// when the token is structurally a publish token but unknown/revoked.
export function authenticateSender(
  req: IncomingMessage,
  opts: { authToken: string; tokenStore: TokenStore; pathToken?: string },
): AuthOutcome {
  const credential = extractCredential(req, opts.pathToken);
  if (credential === null) {
    throw new AuthError(401, { error: "unauthenticated" });
  }
  if (credential === opts.authToken) {
    return { kind: "auth" };
  }
  // Anything that isn't the auth token must be a publish token.
  try {
    const record = opts.tokenStore.lookup(credential);
    return { kind: "publish", record };
  } catch (err) {
    if (err instanceof TokenError) {
      // Bad format / unknown / revoked — all map to 401 from the
      // perimeter's perspective. Don't disclose which.
      throw new AuthError(401, { error: "unauthenticated" });
    }
    throw err;
  }
}

/// Enforce post-auth checks on a publish-token request: the supplied
/// `source` must satisfy the token's source prefix, and the per-token
/// rate limit must not be exhausted. Also touches last_used.
///
/// Auth-token requests skip every check (the auth token has full scope
/// and no rate limit). Returns silently on success, throws AuthError on
/// failure.
export function enforcePublishLimits(
  outcome: AuthOutcome,
  source: string,
  tokenStore: TokenStore,
): void {
  if (outcome.kind === "auth") return;
  try {
    tokenStore.checkSourceAllowed(outcome.record, source);
  } catch (err) {
    if (err instanceof TokenError && err.code === "source-denied") {
      throw new AuthError(403, { error: err.message });
    }
    throw err;
  }
  try {
    tokenStore.consumeRate(outcome.record);
  } catch (err) {
    if (err instanceof TokenError && err.code === "rate-limited") {
      const retry =
        (err as TokenError & { retryAfterSeconds?: number })
          .retryAfterSeconds ?? 1;
      throw new AuthError(429, { error: err.message }, retry);
    }
    throw err;
  }
  tokenStore.touch(outcome.record.id);
}

/// Helper: convert an AuthError to an HTTP response. Returns true once
/// the response has been written.
export function writeAuthError(res: ServerResponse, err: AuthError): true {
  res.statusCode = err.status;
  if (err.retryAfterSeconds !== undefined) {
    res.setHeader("retry-after", String(err.retryAfterSeconds));
  }
  if (err.status === 401) {
    // Per perimeter convention (matches existing /notify) — no body on 401.
    res.end();
    return true;
  }
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify(err.body));
  return true;
}
