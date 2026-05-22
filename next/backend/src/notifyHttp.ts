// HTTP `POST /notify` endpoint. Mounted on the same http.Server that hosts
// /rpc and /healthz — we never open a second port (one transport, one
// security perimeter).
//
// Wire shape:
//   POST /notify
//   Authorization: Bearer <token>            # auth token OR publish token
//   Content-Type: application/json
//   Body: Notification minus server-assigned fields
//   → 200 { id }
//   → 400 { error } on schema violation
//   → 401 (no body) on auth fail
//   → 403 { error } when a publish token's source-prefix forbids the source
//   → 413 on oversized body
//   → 429 { error } on rate-limit exhaustion (with Retry-After)
//   → 500 { error } on unexpected server error
//
// See docs/design/mobile-code-platform.md §4.5.

import type { IncomingMessage, ServerResponse } from "node:http";
import { RpcError } from "./rpc.js";
import type { NotificationHub } from "./notifications.js";
import type { TokenStore } from "./tokenStore.js";
import {
  AuthError,
  authenticateSender,
  enforcePublishLimits,
  writeAuthError,
} from "./senderAuth.js";

/// Hard cap on POST /notify body size — 1 MiB. Body validation already caps
/// the markdown body at 16 KB, but the full payload (including widget JSON)
/// gets a wider ceiling so plugins can ship rich panels.
const MAX_BODY_BYTES = 1 * 1024 * 1024;

export interface NotifyHttpDeps {
  /// The single auth-class bearer token from config.json.
  expectedToken: string;
  hub: NotificationHub;
  tokenStore: TokenStore;
}

/// Returns true if the request was handled (response sent). The caller wires
/// this into the http.Server request handler before the existing /healthz +
/// 404 fallthrough.
export async function handleNotifyHttp(
  req: IncomingMessage,
  res: ServerResponse,
  deps: NotifyHttpDeps,
): Promise<boolean> {
  if (req.url !== "/notify") return false;
  if (req.method !== "POST") {
    res.statusCode = 405;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ error: "method not allowed" }));
    return true;
  }
  let outcome;
  try {
    outcome = authenticateSender(req, {
      authToken: deps.expectedToken,
      tokenStore: deps.tokenStore,
    });
  } catch (err) {
    if (err instanceof AuthError) return writeAuthError(res, err);
    throw err;
  }
  let raw: string;
  try {
    raw = await readBody(req);
  } catch (err) {
    if (err instanceof BodyTooLargeError) {
      res.statusCode = 413;
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ error: "payload too large" }));
      return true;
    }
    res.statusCode = 400;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ error: "could not read body" }));
    return true;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    res.statusCode = 400;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ error: "invalid json" }));
    return true;
  }
  // Pull `source` for the post-auth source-prefix check. We do this before
  // hub.publish (which also validates) so a token-scope violation surfaces
  // as 403, not as 400-after-validation. Cheap path: only the source field
  // matters here; full schema validation still runs in publish.
  const source =
    typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>).source
      : undefined;
  if (typeof source !== "string") {
    res.statusCode = 400;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ error: "source required" }));
    return true;
  }
  try {
    enforcePublishLimits(outcome, source, deps.tokenStore);
  } catch (err) {
    if (err instanceof AuthError) return writeAuthError(res, err);
    throw err;
  }
  try {
    const { id } = deps.hub.publish(parsed);
    res.statusCode = 200;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ id }));
  } catch (err) {
    if (err instanceof RpcError) {
      res.statusCode = 400;
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ error: err.message }));
      return true;
    }
    // Generic 500 body — don't echo `err.message`, which can leak internal
    // state (paths, secrets in a stack-stringified error, etc.). The real
    // error is logged by the index.ts request-level catch via console.error.
    console.error("[notify] publish failed:", err);
    res.statusCode = 500;
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ error: "internal error" }));
  }
  return true;
}

class BodyTooLargeError extends Error {}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;
    let rejected = false;
    req.on("data", (chunk: Buffer) => {
      if (rejected) return;
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        rejected = true;
        // Don't push more data into memory; let the request finish so the
        // response (413) can be delivered cleanly. Destroying the socket
        // here would race the response write and surface as ECONNRESET on
        // the client.
        chunks.length = 0;
        reject(new BodyTooLargeError("body too large"));
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (rejected) return;
      resolve(Buffer.concat(chunks).toString("utf8"));
    });
    req.on("error", (err) => {
      if (!rejected) reject(err);
    });
  });
}
