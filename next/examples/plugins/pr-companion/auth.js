// PR Companion — auth resolver.
//
// Shells out to `gh auth token` on every activation to obtain a GitHub
// access token, then exchanges that token for the authenticated user's
// login via `GET https://api.github.com/user`. The token is never
// persisted: each plugin activation re-runs `gh auth token`, which is
// also the rotation story — when the user runs `gh auth refresh` or
// `gh auth login` again, the next activation just picks up the new
// value.
//
// The function returns a tagged-union shape so the caller can render
// the right placeholder banner without inspecting raw errors:
//
//   { status: "ok",            token, user: { login, avatarUrl } }
//   { status: "missing"        }                       // gh not installed
//   { status: "unauthed",      stderr }                // gh present, not logged in
//   { status: "tokenInvalid"   }                       // GitHub said 401
//   { status: "offline",       error }                 // fetch rejected
//
// IMPORTANT for callers: the `token` field is intentionally returned so
// Phase 2's `github.js` has something to authenticate with, but it MUST
// NOT be written to disk, logged, or otherwise persisted. The host
// re-resolves it on every activation — that is the rotation story; any
// caching would defeat it.

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const GH_TIMEOUT_MS = 5000;
const USER_AGENT = "openvsmobile-pr-companion/0.1";
const USER_URL = "https://api.github.com/user";

/**
 * Run `gh auth token` and (on success) fetch the authenticated user.
 *
 * @returns {Promise<
 *   | { status: "ok", token: string, user: { login: string, avatarUrl: string | null } }
 *   | { status: "missing" }
 *   | { status: "unauthed", stderr: string }
 *   | { status: "tokenInvalid" }
 *   | { status: "offline", error: Error }
 * >}
 */
export async function resolveGhAuth() {
  let token;
  try {
    const { stdout } = await execFileAsync("gh", ["auth", "token"], {
      timeout: GH_TIMEOUT_MS,
    });
    token = stdout.toString().trim();
    if (token.length === 0) {
      // `gh` exited 0 but produced no token — treat the same as
      // unauthed; the user needs to run `gh auth login`.
      return { status: "unauthed", stderr: "empty token from gh auth token" };
    }
  } catch (err) {
    // ENOENT → the `gh` binary is not on PATH.
    if (err && err.code === "ENOENT") {
      return { status: "missing" };
    }
    // Non-zero exit → the binary ran but said no. Surface the stderr so
    // the renderer can show something useful next to the hint.
    const stderr =
      (err && typeof err.stderr === "string" && err.stderr.trim()) ||
      (err && err.message) ||
      "gh auth token failed";
    return { status: "unauthed", stderr };
  }

  // We have a token. Exchange it for a username via /user.
  let res;
  try {
    res = await fetch(USER_URL, {
      headers: {
        Authorization: `token ${token}`,
        Accept: "application/vnd.github+json",
        "User-Agent": USER_AGENT,
      },
    });
  } catch (err) {
    return { status: "offline", error: err instanceof Error ? err : new Error(String(err)) };
  }

  if (res.status === 401) {
    return { status: "tokenInvalid" };
  }
  if (!res.ok) {
    // Anything else non-2xx (403 rate-limit, 5xx) is "offline-shaped"
    // for Phase 1 purposes — the user can't proceed but the token might
    // still be valid. Surface a synthetic Error so the banner copy
    // ("GitHub unreachable") at least includes the status code.
    return {
      status: "offline",
      error: new Error(`GitHub /user returned HTTP ${res.status}`),
    };
  }

  let body;
  try {
    body = await res.json();
  } catch (err) {
    return { status: "offline", error: err instanceof Error ? err : new Error(String(err)) };
  }

  const login = typeof body?.login === "string" ? body.login : "";
  const avatarUrl =
    typeof body?.avatar_url === "string" ? body.avatar_url : null;
  if (login.length === 0) {
    // 200 OK but no login field — treat as token-invalid; this should
    // never happen in practice but keeps the union exhaustive.
    return { status: "tokenInvalid" };
  }

  return {
    status: "ok",
    token,
    user: { login, avatarUrl },
  };
}
