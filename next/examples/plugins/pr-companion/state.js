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
//   * `shownNotifIds`    — notification ids the plugin has already
//                          fanned out as a system notification via
//                          `ctx.showNotification`. Prevents a poll's
//                          worth of duplicates on every 60s tick (the
//                          inbox always re-includes still-unread items),
//                          and — crucially — gates the cold-start
//                          no-spam behavior in index.js: on first
//                          activation we pre-populate this list with
//                          the entire initial poll without firing any
//                          toasts, so subsequent polls only fan out
//                          genuinely-new ids. Soft-capped at 500
//                          entries (FIFO eviction); the oldest dropped
//                          id could re-fire if it reappears in the
//                          inbox, which is acceptable given the toast
//                          itself carries a 1-hour TTL.
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
 * @property {string[]} shownNotifIds
 */

/**
 * Soft cap on `shownNotifIds`. Once we cross this, the oldest entries
 * are dropped FIFO on every append. Sized to comfortably cover a few
 * weeks of an active reviewer's inbox without the file growing
 * unboundedly; the exact number is not load-bearing — see the module
 * header for the eviction-edge-case rationale.
 */
export const SHOWN_NOTIF_CAP = 500;

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
    shownNotifIds: [],
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
  if (Array.isArray(obj.shownNotifIds)) {
    // Same string-filter shape as dismissedIds; if the file ever grew
    // past the soft cap (e.g. an older build saved with no cap), trim
    // to the most-recent SHOWN_NOTIF_CAP entries so we don't carry
    // forever-growing files across upgrades.
    const filtered = obj.shownNotifIds
      .filter((id) => typeof id === "string" && id.length > 0)
      .map((id) => /** @type {string} */ (id));
    out.shownNotifIds =
      filtered.length > SHOWN_NOTIF_CAP
        ? filtered.slice(filtered.length - SHOWN_NOTIF_CAP)
        : filtered;
  }
  return out;
}

/**
 * Append `id` to `shownNotifIds` with FIFO eviction at SHOWN_NOTIF_CAP.
 * Mutates `state` in place and returns it for call-chaining. No-op when
 * `id` is already present — the in-memory Set in index.js short-circuits
 * the common case, but the in-place check here keeps the helper safe to
 * call without a separate dedup gate.
 *
 * @param {PersistedState} state
 * @param {string} id
 * @returns {PersistedState}
 */
export function appendShownNotifId(state, id) {
  if (typeof id !== "string" || id.length === 0) return state;
  // Cheap dedup against the tail — the common-case repeat is a
  // just-fanned id appearing again in the next 60s tick, so checking
  // the tail catches almost all redundant appends without an O(n) scan.
  if (state.shownNotifIds.length > 0) {
    if (state.shownNotifIds[state.shownNotifIds.length - 1] === id) {
      return state;
    }
  }
  // Full O(n) dedup for correctness — keeping a duplicate around would
  // burn a slot of the soft cap and slightly skew the FIFO order.
  const existingIdx = state.shownNotifIds.indexOf(id);
  if (existingIdx !== -1) {
    state.shownNotifIds.splice(existingIdx, 1);
  }
  state.shownNotifIds.push(id);
  while (state.shownNotifIds.length > SHOWN_NOTIF_CAP) {
    state.shownNotifIds.shift();
  }
  return state;
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
