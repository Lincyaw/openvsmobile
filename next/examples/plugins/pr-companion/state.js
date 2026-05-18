// PR Companion — persisted state.
//
// Owns the on-disk JSON for the small slice of plugin state that must
// survive plugin restarts:
//
//   * `dismissedIds`     — notification ids the user swiped away in the
//                          inbox. GitHub will re-surface them with a
//                          fresh `updated_at` on its own schedule; until
//                          then we hide them.
//   * `lastSeenAt`       — ISO timestamp the user last opened the inbox
//                          panel. Drives the "X new since you last
//                          looked" badge (Phase 5 feature; persisted now
//                          so the field exists when we light it up).
//   * `scopeByWorkspace` — per-workspace-id toggle between "thisRepo"
//                          and "allRepos". A user can keep workspace A
//                          scoped to its own repo while B browses
//                          everything; the key is the workspace's
//                          stable UUID per design doc.
//
// Token is INTENTIONALLY NOT stored here. Auth lives in `gh auth token`,
// re-read on every activation — see auth.js header.
//
// Writes are atomic: we materialize the new JSON into `<file>.tmp`
// inside the target directory (so the rename is on the same fs and
// therefore atomic), then `rename(.tmp → final)`. Concurrent saves race
// on the temp filename — for a single-user single-process plugin that's
// fine, but if it ever becomes a problem we'd switch to a per-write
// random suffix. Failure to load / save is logged and swallowed; the
// plugin keeps running on defaults so a corrupt or unreadable state
// file never bricks the inbox.

import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const STATE_DIR = join(homedir(), ".openvsmobile", "pr-companion");
const STATE_PATH = join(STATE_DIR, "state.json");
const STATE_TMP_PATH = `${STATE_PATH}.tmp`;

/**
 * @typedef {Object} PersistedState
 * @property {string[]} dismissedIds
 * @property {string | null} lastSeenAt
 * @property {Record<string, "thisRepo" | "allRepos">} scopeByWorkspace
 */

/**
 * Default-shaped persisted state, returned when no file exists yet or
 * when the on-disk JSON is corrupt. Callers may mutate the returned
 * object freely — it's a fresh allocation every call.
 *
 * @returns {PersistedState}
 */
export function defaultState() {
  return {
    dismissedIds: [],
    lastSeenAt: null,
    scopeByWorkspace: {},
  };
}

/**
 * Coerce a parsed JSON value into a well-shaped PersistedState. Any
 * field that fails shape validation is reset to its default — we never
 * throw on user-touched JSON, since "delete pr-companion's state file
 * to reset" is a perfectly reasonable user recovery move and we'd
 * rather absorb a partial file than crash on first re-run.
 *
 * @param {unknown} raw
 * @returns {PersistedState}
 */
function normalize(raw) {
  const out = defaultState();
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    return out;
  }
  const obj = /** @type {Record<string, unknown>} */ (raw);
  if (Array.isArray(obj.dismissedIds)) {
    out.dismissedIds = obj.dismissedIds
      .filter((id) => typeof id === "string" && id.length > 0)
      .map((id) => /** @type {string} */ (id));
  }
  if (typeof obj.lastSeenAt === "string" && obj.lastSeenAt.length > 0) {
    out.lastSeenAt = obj.lastSeenAt;
  }
  if (
    obj.scopeByWorkspace !== null &&
    typeof obj.scopeByWorkspace === "object" &&
    !Array.isArray(obj.scopeByWorkspace)
  ) {
    const entries = /** @type {Record<string, unknown>} */ (
      obj.scopeByWorkspace
    );
    for (const [wsId, value] of Object.entries(entries)) {
      if (value === "thisRepo" || value === "allRepos") {
        out.scopeByWorkspace[wsId] = value;
      }
    }
  }
  return out;
}

/**
 * Load the persisted state from disk. Returns defaults on any failure
 * — first-run ENOENT, malformed JSON, permission error. `ctx` is
 * optional so the function stays callable from tests without a fake
 * context; when provided we log non-ENOENT failures so a broken state
 * file is visible in the host log.
 *
 * @param {{ log?: (level: string, msg: string) => void }} [ctx]
 * @returns {Promise<PersistedState>}
 */
export async function loadState(ctx) {
  let raw;
  try {
    raw = await readFile(STATE_PATH, "utf8");
  } catch (err) {
    if (err && /** @type {NodeJS.ErrnoException} */ (err).code === "ENOENT") {
      return defaultState();
    }
    ctx?.log?.(
      "warn",
      `pr-companion: state load failed (${err?.message ?? String(err)}); using defaults`,
    );
    return defaultState();
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    ctx?.log?.(
      "warn",
      `pr-companion: state file is not valid JSON (${err?.message ?? String(err)}); using defaults`,
    );
    return defaultState();
  }
  return normalize(parsed);
}

/**
 * Persist state to disk atomically. mkdir → writeFile(.tmp) → rename.
 * Logs and swallows on failure — a transient write error must not
 * crash the plugin (design doc: "Failure to save: warn via ctx.log;
 * don't crash the plugin").
 *
 * @param {PersistedState} state
 * @param {{ log?: (level: string, msg: string) => void }} [ctx]
 * @returns {Promise<void>}
 */
export async function saveState(state, ctx) {
  try {
    await mkdir(dirname(STATE_PATH), { recursive: true });
    // Pretty-print: this file is small (one entry per dismissed id plus
    // one entry per workspace) and the user may want to hand-edit /
    // inspect it. The two-space indent matches the rest of the repo.
    const json = JSON.stringify(state, null, 2);
    await writeFile(STATE_TMP_PATH, json, "utf8");
    await rename(STATE_TMP_PATH, STATE_PATH);
  } catch (err) {
    ctx?.log?.(
      "warn",
      `pr-companion: state save failed (${err?.message ?? String(err)})`,
    );
  }
}

/**
 * Exposed for unit tests — lets the test point the state file at a
 * temp directory by reading these in lieu of recomputing the paths.
 */
export const _paths = {
  dir: STATE_DIR,
  file: STATE_PATH,
  tmp: STATE_TMP_PATH,
};
