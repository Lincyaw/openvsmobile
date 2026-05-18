// PR Companion — plugin entry (Phases 1 + 2 + 3).
//
// Phase 1 ships the shell (auth + workspace detection). Phase 2 ships
// the Inbox (GitHub Notifications fetch with ETag, three-tab filter,
// scope chip + switcher, swipe-to-dismiss with persistence). Phase 3
// ships the read-only PR detail panel (three-tab Conversation / Files
// / Checks-placeholder, in-memory LRU cache, 30s ETag polling). The
// partition between phases uses explicit `// === Phase N ===` markers
// so future merges (Phase 4 review actions, Phase 5 checks +
// background fan-out) stay mechanical.
//
// What this file owns:
//   * Module-level state for inbox + detail + cross-phase navigation.
//   * `onActivate` / `onWorkspaceActivated` / `onUiEvent` wiring.
//   * The 60s inbox poll loop; detail polling is owned by prDetail.js.
//   * Dispatching UI events to `handleInboxEvent` and
//     `handleDetailEvent`.
//
// What this file does NOT own:
//   * Inbox widget-tree / filter logic — see `render/inbox.js`.
//   * Detail widget-tree / fetch orchestration — see
//     `render/prDetail.js` and its `render/{conversationTab,filesTab,
//     _pure}.js` helpers.
//   * Persistence helpers — see `state.js`.
//   * GitHub HTTP client — see `github.js`.

import { execFile } from "node:child_process";
import { promisify } from "node:util";

import { createPlugin, ui } from "@openvsmobile/sdk";

import { resolveGhAuth } from "./auth.js";
import { createGithubClient } from "./github.js";
import { loadState, saveState, appendShownNotifId } from "./state.js";
// Phase 2 renderer + event handler.
import { renderInboxPanel, handleInboxEvent } from "./render/inbox.js";
// Phase 3 renderer + event handler + polling lifecycle.
// Phase 4 also pulls in setReviewError / getDetailComment so the
// review-actions dispatch in this file can mutate the review-error slot
// and read the cached comment body for reply-prefill without reaching
// into prDetail.js's module-level state.
import {
  renderDetailPanel,
  handleDetailEvent,
  stopDetailPolling,
  setReviewError,
  getDetailComment,
  // Phase 6 — read-only cache accessor used by the check-row tap path
  // to look up a CheckRun by index. prDetail.js already exposed this
  // via `__testing.getCache` for its own test harness; reusing the same
  // hook here keeps the dependency obvious (and avoids extending
  // prDetail.js's public surface, which Phase 6 must not touch).
  __testing as __prDetailTesting,
} from "./render/prDetail.js";
// Phase 4 — wire-event constants for the Comment button + reply prefix.
// Importing the constants instead of re-typing them means a rename in
// conversationTab.js cannot drift the dispatch silently.
import { conversationEvents } from "./render/conversationTab.js";
// Phase 4 — pure helpers shared with render/reviewSheets.test.js.
// Side-effectful pieces (showActionSheet / showBottomSheet, github POST
// orchestration) stay inline below.
import {
  reviewEvents,
  reviewSheetHeading,
  buildReplyQuotePrefill,
  mapPostError,
} from "./render/reviewSheets.js";
// Phase 6 — checks tap event prefix + log-sheet builder + fan-out helper.
import { CHECK_LOG_EVENT_PREFIX } from "./render/checksTab.js";
import { buildLogSheet } from "./render/logSheet.js";
import { computeNotifFanout } from "./render/notifFanout.js";

const execFileAsync = promisify(execFile);

const INBOX_PANEL = "inbox";
const DETAIL_PANEL = "detail";

const GIT_TIMEOUT_MS = 5000;
const INBOX_POLL_INTERVAL_MS = 60_000;

// User-Agent string passed to github.js. GitHub's API policy requires a
// non-empty User-Agent; using a plugin-stable identifier makes our calls
// distinguishable in their audit logs without leaking host identity.
const USER_AGENT = "openvsmobile-pr-companion/0.1";

// Regex per design doc § "Workspace model": SSH (`git@github.com:o/r`)
// and HTTPS (`https://github.com/o/r[.git]`) forms only. Anything else
// — gitlab.com, internal mirrors, no remote at all — falls through to
// the "(not a GitHub repo)" branch and the inbox banner explains why.
const GITHUB_REMOTE_RE =
  /^(?:git@github\.com:|https?:\/\/github\.com\/)([^/]+)\/([^/.]+?)(?:\.git)?$/;

/**
 * Parse a `git remote get-url origin` output into `{owner, repo}`, or
 * `null` if the remote isn't a GitHub URL we recognize.
 *
 * @param {string} remoteUrl
 * @returns {{ owner: string, repo: string } | null}
 */
export function parseGithubRemote(remoteUrl) {
  if (typeof remoteUrl !== "string") return null;
  const trimmed = remoteUrl.trim();
  if (trimmed.length === 0) return null;
  const m = GITHUB_REMOTE_RE.exec(trimmed);
  if (m === null) return null;
  return { owner: m[1], repo: m[2] };
}

/**
 * Spawn `git -C <root> remote get-url origin` and parse the result.
 * Returns `null` for any failure mode (no git, no remote, non-GitHub
 * remote). Phase 1 doesn't need to distinguish the three — they all
 * render the same "not a GitHub repo" placeholder.
 *
 * @param {string} root
 * @returns {Promise<{ owner: string, repo: string } | null>}
 */
async function detectRepoForRoot(root) {
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["-C", root, "remote", "get-url", "origin"],
      { timeout: GIT_TIMEOUT_MS },
    );
    return parseGithubRemote(stdout.toString());
  } catch {
    return null;
  }
}

// Per-workspace-id cache of the parsed repo. Keyed by `WorkspaceRef.id`
// (UUID, stable across reconnect), invalidated on every
// `onWorkspaceActivated` callback by simply overwriting the entry for
// the new workspace's id. We never grow this beyond a handful of
// entries in practice — workspaces are session-scoped — so an explicit
// eviction policy is unnecessary for Phase 1.
const repoByWorkspace = new Map();

// Latest snapshot used by render(); rewritten by hydrate() before every
// re-render. Holding these at module scope keeps render() pure on its
// inputs without threading a state object through every call site.
let currentAuth = null;
let currentWorkspace = null;
let currentRepo = null;

// ─────────────────────────────────────────────────────────────
// === Cross-phase: shared state ===
// ─────────────────────────────────────────────────────────────
// Phase 2 (Inbox) and Phase 3 (Detail) both read/write these slots.
//
// Contract:
//   * `currentDetailPr` is the PR currently displayed in the detail
//     panel, or `null` when no PR is open. Phase 2's Inbox tap path
//     sets this to a `{owner, repo, number}` and calls `render(ctx)`,
//     which re-renders both panels including detail.
//   * `previousDetailPr` is what the detail layer last rendered. The
//     detail render compares old vs new to know whether to reset its
//     internal tab/file state and restart its polling loop.
//   * `githubClient` is a per-activation client instance scoped to the
//     resolved token. It is `null` until auth resolves, and is
//     replaced (not mutated) on every activation so token rotation
//     just works.
/** @type {{ owner: string, repo: string, number: number } | null} */
let currentDetailPr = null;
/** @type {{ owner: string, repo: string, number: number } | null} */
let previousDetailPr = null;
/** @type {ReturnType<typeof createGithubClient> | null} */
let githubClient = null;

// ─────────────────────────────────────────────────────────────
// === Phase 2 (Inbox) state ===
// ─────────────────────────────────────────────────────────────

// Latest ctx captured at the top of every lifecycle hook — used by
// off-cycle save / log paths (e.g. saveState invocations triggered
// from a setInterval tick).
let currentCtx = /** @type {import("@openvsmobile/sdk").PluginContext | null} */ (
  null
);

// Persisted across plugin restarts; loaded once in onActivate.
let persistedState = {
  dismissedIds: /** @type {string[]} */ ([]),
  lastSeenAt: /** @type {string | null} */ (null),
  scopeByWorkspace: /** @type {Record<string, "thisRepo" | "allRepos">} */ ({}),
  shownNotifIds: /** @type {string[]} */ ([]),
};
let dismissedSet = /** @type {Set<string>} */ (new Set());
// === Phase 6 ===
// Mirror of persistedState.shownNotifIds used for O(1) lookup inside the
// 60s poll's fan-out diff. Stays in lockstep with the persisted array —
// every append goes through `markNotifShown` below so the two
// representations cannot drift.
let shownNotifSet = /** @type {Set<string>} */ (new Set());

// Mutable in-memory inbox slot. `notifications` is the most-recent
// successful fetch; subsequent 304s leave it intact so the user keeps
// seeing the last good list across transient outages.
const inboxState = {
  activeTab: /** @type {"review" | "mentioned" | "assigned"} */ ("review"),
  notifications: /** @type {import("./render/inbox.js").Notification[]} */ ([]),
  etag: /** @type {string | null} */ (null),
  lastModified: /** @type {string | null} */ (null),
  error: /** @type {{ kind: string, [k: string]: unknown } | null} */ (null),
  lastRefreshIso: /** @type {string | null} */ (null),
};

/** @type {NodeJS.Timeout | null} */
let inboxTimer = null;
// Single-slot in-flight guard. A workspace switch can fire a manual
// pollInbox while the 60s interval is mid-flight; without this guard
// the slow-then-fast race overwrites fresher state (and the etag) with
// stale data. Skipping the second call is correct here — the existing
// fetch will finish and update inboxState; the next 60s tick re-polls.
let pollInFlight = false;

/**
 * Resolve the scope value for the active workspace. Defaults to
 * `"thisRepo"` when the workspace maps to a GitHub repo, otherwise
 * forced to `"allRepos"`. Persisted override takes priority when
 * present.
 *
 * @returns {"thisRepo" | "allRepos"}
 */
function effectiveScope() {
  if (currentRepo === null) return "allRepos";
  if (currentWorkspace === null) return "allRepos";
  const persisted = persistedState.scopeByWorkspace[currentWorkspace.id];
  if (persisted === "thisRepo" || persisted === "allRepos") return persisted;
  return "thisRepo";
}

// ─────────────────────────────────────────────────────────────
// === Phase 3 (Detail) state ===
// ─────────────────────────────────────────────────────────────
// All Phase-3 module-level state lives inside render/prDetail.js
// (detailState + prDetailCache + detailTimer) — none of it leaks here
// beyond the cross-phase slots above. Keeps the merge surface minimal.

// ─────────────────────────────────────────────────────────────
// === Phase 4 (Review actions) state ===
// ─────────────────────────────────────────────────────────────
// Single-slot guard so a double-tap on Submit during a slow POST
// doesn't fire two writes. The bottom sheet has no native loading
// affordance and the SDK doesn't yet expose a plugin-driven dismissal
// path (TODO(v1) in @openvsmobile/sdk PluginContext.showBottomSheet),
// so the user is left to dismiss the sheet themselves on success — the
// next tap reopens a fresh one. See report (a) for the full UX gap.
let reviewSubmitPending = false;
// Body buffer for the open review/comment bottom sheet. Reset whenever
// a new sheet is opened; updated on every `changed` event from the
// textfield. Plain string so the submit handler can pass it straight
// through to github.js.
let reviewBodyBuffer = "";
// "Submit context" — what the next Submit tap should do. Picked up from
// the bottom sheet that opened it; the textfield + submit button live
// in the sheet's child tree and don't carry per-sheet metadata of their
// own. Cleared after a successful submit.
/** @type {{ action: 'approve' | 'request-changes' | 'comment' | 'reply', replyToId?: number } | null} */
let reviewSubmitContext = null;

// Wire-event constants are imported from render/reviewSheets.js so the
// test file and the dispatch share one source of truth. Aliased to
// SCREAMING_CASE locals only where the dispatch reads cleaner with
// short identifiers; otherwise we reference `reviewEvents.*` directly.
const NODE_REVIEW_BTN = reviewEvents.REVIEW_BTN_NODE;
const NODE_REVIEW_BODY_FIELD = reviewEvents.BODY_FIELD_NODE;
const NODE_REVIEW_SUBMIT_BTN = reviewEvents.SUBMIT_BTN_NODE;

/**
 * Persist `value` as the scope for the active workspace, then save.
 * No-op when there's no workspace to key on.
 *
 * @param {"thisRepo" | "allRepos"} value
 */
async function setScopeForCurrent(value) {
  if (currentWorkspace === null) return;
  persistedState.scopeByWorkspace[currentWorkspace.id] = value;
  await saveState(persistedState, currentCtx ?? undefined);
}

/**
 * Append `id` to the persisted dismissed list (and the in-memory Set
 * used for fast filter lookups), then save. Idempotent — adding an id
 * that's already dismissed is a no-op write.
 *
 * @param {string} id
 */
async function addDismissedId(id) {
  if (dismissedSet.has(id)) return;
  dismissedSet.add(id);
  persistedState.dismissedIds.push(id);
  await saveState(persistedState, currentCtx ?? undefined);
}

/**
 * Mark a batch of notification ids as "we've fanned this out as a
 * system notification" (or "we pre-populated this on cold start").
 * Keeps the in-memory Set in lockstep with the persisted array via
 * `appendShownNotifId` — that helper handles the soft cap eviction so
 * the file doesn't grow unboundedly.
 *
 * Caller passes the full list and we filter out already-known ids
 * locally; the in-memory Set is the cheap dedup gate. We save once at
 * the end rather than per-id so a poll with N new ids triggers a
 * single fs write.
 *
 * @param {string[]} ids
 */
async function markNotifShown(ids) {
  if (ids.length === 0) return;
  let changed = false;
  for (const id of ids) {
    if (shownNotifSet.has(id)) continue;
    shownNotifSet.add(id);
    appendShownNotifId(persistedState, id);
    changed = true;
  }
  if (!changed) return;
  // appendShownNotifId may have evicted from the head; rebuild the Set
  // from the post-eviction array so the two stay aligned. Cheap — the
  // array is capped at 500.
  shownNotifSet = new Set(persistedState.shownNotifIds);
  await saveState(persistedState, currentCtx ?? undefined);
}

/**
 * Poll the GitHub Notifications API and update inboxState in place.
 * Returns `true` when something visible changed (so the caller should
 * re-render), `false` when the call was a pure 304 with no banner
 * transition (re-rendering would be wasted reconciler work).
 *
 * Tolerates a null client (auth.status !== "ok"): no-op returns false.
 * Concurrent calls are coalesced: a second invocation while one is in
 * flight returns false immediately — the in-flight call's completion
 * will trigger a render on its own.
 *
 * Side-effect (Phase 6): on every successful poll (status === "ok") we
 * fan out genuinely-new notifications as system toasts via
 * `ctx.showNotification`. Cold-start no-spam: on the first poll after
 * activation `shownNotifSet` is empty (the persisted file is the
 * source of truth — option (a) per spec), so `computeNotifFanout`
 * pre-populates without firing. Subsequent polls only fire toasts for
 * ids not already in `shownNotifSet` and not in `dismissedSet`. The
 * await on `markNotifShown` keeps the rest of the poll's "did
 * anything change" return value untouched — the fanout doesn't gate
 * re-render, since the inbox tree itself updates from
 * `inboxState.notifications` regardless.
 *
 * @param {{ log: (level: string, msg: string) => void, showNotification?: (input: import("@openvsmobile/sdk").NotificationInput) => Promise<{ id: string }> }} ctx
 * @returns {Promise<boolean>}
 */
async function pollInbox(ctx) {
  if (githubClient === null) return false;
  if (pollInFlight) return false;
  pollInFlight = true;
  try {
    const hadError = inboxState.error !== null;
    const result = await githubClient.listNotifications({
      participating: true,
      sinceETag: inboxState.etag ?? undefined,
      sinceLastModified: inboxState.lastModified ?? undefined,
    });
    if (result.status === "ok") {
      inboxState.notifications = result.items;
      inboxState.etag = result.etag ?? null;
      inboxState.lastModified = result.lastModified ?? null;
      inboxState.error = null;
      inboxState.lastRefreshIso = new Date().toISOString();
      // === Phase 6: notification fan-out ===
      await fanOutNotifications(ctx, result.items);
      return true;
    }
    if (result.status === "notModified") {
      // 304 keeps the existing list; refresh the validators in case
      // the server rotated them, and clear any transient error
      // banner. Only flag changed when a banner just disappeared —
      // the "Last refreshed Xs ago" caption is empty-state-only and
      // staleness there is acceptable.
      inboxState.etag = result.etag ?? inboxState.etag;
      inboxState.error = null;
      inboxState.lastRefreshIso = new Date().toISOString();
      return hadError;
    }
    // All other branches map onto inboxBanner kinds in render/inbox.js.
    if (result.status === "unauthed") {
      inboxState.error = { kind: "unauthed" };
    } else if (result.status === "rateLimited") {
      inboxState.error = { kind: "rateLimited", resetAt: result.resetAt };
    } else if (result.status === "offline") {
      inboxState.error = { kind: "offline", error: result.error };
    } else if (result.status === "serverError") {
      inboxState.error = { kind: "serverError", code: result.code };
    } else {
      inboxState.error = { kind: "serverError", code: 0 };
    }
    ctx.log(
      "warn",
      `prcomp: notifications poll returned ${result.status}`,
    );
    return true;
  } finally {
    pollInFlight = false;
  }
}

/**
 * Phase 6: dispatch each genuinely-new notification to
 * `ctx.showNotification`, then persist the updated shownNotifIds.
 *
 * Errors from `ctx.showNotification` are logged and swallowed — a
 * failure to fan out one toast should not prevent the other toasts
 * (or the poll's render path) from progressing. The id is still
 * marked as shown even on toast-call failure: re-firing on every 60s
 * tick after a transient host error would be the worse behavior, and
 * the toast's 1-hour TTL is the upper-bound staleness budget here
 * anyway.
 *
 * @param {{ log: (level: string, msg: string) => void, showNotification?: (input: import("@openvsmobile/sdk").NotificationInput) => Promise<{ id: string }> }} ctx
 * @param {Array<import("./render/inbox.js").Notification>} notifications
 */
async function fanOutNotifications(ctx, notifications) {
  if (typeof ctx.showNotification !== "function") {
    // Older host or test harness without the Phase-6A SDK extension —
    // skip silently. The persisted shownNotifIds list still gets a
    // cold-start population so a later upgrade picks up where we left
    // off without spamming the inbox backlog.
    if (shownNotifSet.size === 0 && notifications.length > 0) {
      await markNotifShown(notifications.map((n) => n.id).filter((id) => typeof id === "string" && id.length > 0));
    }
    return;
  }
  const { toasts, idsToMark, coldStart } = computeNotifFanout({
    notifications,
    dismissedSet,
    shownSet: shownNotifSet,
  });
  if (coldStart && idsToMark.length > 0) {
    ctx.log(
      "info",
      `prcomp: cold-start fanout suppressed for ${idsToMark.length} pre-existing notification${idsToMark.length === 1 ? "" : "s"}`,
    );
  }
  // Fire each toast in arrival order. Sequential rather than
  // Promise.all because the host serializes notify.show anyway and
  // sequential makes the failure log trivial to correlate; the worst-
  // case is N small RPC round-trips on a poll that yielded N new ids,
  // which is bounded by the inbox's per_page cap (100) and in practice
  // is ≤ a handful per minute.
  for (const toast of toasts) {
    try {
      await ctx.showNotification(toast.input);
    } catch (err) {
      ctx.log(
        "warn",
        `prcomp: showNotification failed for ${toast.notifId}: ${err?.message ?? String(err)}`,
      );
    }
  }
  await markNotifShown(idsToMark);
}

/**
 * Phase 6: handle a tap on a check row in the Checks tab. Looks up the
 * CheckRun from the prDetail cache (the row carries an index, not the
 * run object — by design, so the wire payload stays small), fetches
 * the log via github.js, then opens a bottom sheet via logSheet.js.
 *
 * "Fetch first, then open" pattern: we await the log fetch before
 * calling showBottomSheet, matching Phase 4's review-sheet flow.
 * Avoids the spinner-then-content swap that re-calling showBottomSheet
 * mid-flight would require (the SDK has no plugin-driven dismiss path,
 * so we can't reliably close-and-reopen a sheet either). Worst case is
 * "tap → wait up to 10s (github.js's request timeout) → sheet
 * appears" — acceptable for an on-demand fetch; the row's caption
 * already told the user the check is real.
 *
 * @param {{ log: (level: string, msg: string) => void, showBottomSheet: (panelId: string, sheet: import("@openvsmobile/sdk").UiBottomSheet) => Promise<unknown> }} ctx
 * @param {number} idx
 * @returns {Promise<boolean>}
 */
async function handleChecksLogTap(ctx, idx) {
  if (!Number.isInteger(idx) || idx < 0) {
    ctx.log("warn", `prcomp: bad check-log tap index ${idx}`);
    return true;
  }
  if (currentDetailPr === null) {
    ctx.log("warn", "prcomp: check-log tap with no PR open");
    return true;
  }
  if (githubClient === null) {
    // No client — surface the unauthed banner directly without an
    // HTTP round-trip. The user is already seeing the inbox-side
    // auth banner; this just makes the check-log path consistent.
    await ctx.showBottomSheet(
      DETAIL_PANEL,
      buildLogSheet({
        run: {
          name: "Check log",
          status: "unknown",
          conclusion: null,
          startedAt: null,
          completedAt: null,
        },
        result: { status: "unauthed" },
      }),
    );
    return true;
  }
  const cached = getPrDetailCacheEntry(currentDetailPr);
  if (cached === null) {
    ctx.log("warn", "prcomp: check-log tap before detail cache populated");
    return true;
  }
  const runs = /** @type {Array<{ id: number, name: string, status: string, conclusion: string | null, startedAt: string | null, completedAt: string | null }> | null | undefined} */ (
    cached.checks
  );
  if (!Array.isArray(runs) || idx >= runs.length) {
    ctx.log("warn", `prcomp: check-log tap idx ${idx} out of range`);
    return true;
  }
  const run = runs[idx];
  if (!Number.isInteger(run.id) || run.id <= 0) {
    ctx.log("warn", `prcomp: check-log tap run ${run.name} has no usable id`);
    return true;
  }
  // Network round-trip happens here; github.js already enforces a 10s
  // timeout so a stuck request degrades to `status: "offline"` rather
  // than hanging the tap forever.
  const result = await githubClient.getCheckRunLog({
    owner: currentDetailPr.owner,
    repo: currentDetailPr.repo,
    runId: run.id,
  });
  await ctx.showBottomSheet(DETAIL_PANEL, buildLogSheet({ run, result }));
  return true;
}

/**
 * Read-only accessor into prDetail.js's private cache. Lives here as a
 * thin shim because prDetail.js is owned by Phase 5 and we don't want
 * to extend its public surface for this one access pattern — instead
 * we import its existing testing hook lazily so the dependency is
 * obvious in a grep.
 *
 * Returns null when the PR isn't cached (raced with a PR switch) or
 * when prDetail.js hasn't been activated yet (shouldn't happen — the
 * caller checks currentDetailPr first).
 *
 * @param {{ owner: string, repo: string, number: number }} pr
 */
function getPrDetailCacheEntry(pr) {
  const cache = /** @type {Map<string, unknown> | undefined} */ (
    __prDetailTesting?.getCache?.()
  );
  if (cache === undefined) return null;
  const key = `${pr.owner}/${pr.repo}#${pr.number}`;
  const entry = /** @type {{ checks: unknown } | undefined} */ (cache.get(key));
  return entry ?? null;
}

/**
 * Render the detail panel via render/prDetail.js. Tracks
 * `previousDetailPr` so the render layer can detect PR changes and
 * reset its internal tab/file state + restart its 30s polling loop
 * when needed.
 *
 * Wrapper exists so Phase 2's Inbox tap path has a single, stable
 * entry point: set `currentDetailPr = …` then call
 * `renderDetailPanelEntry(ctx)`.
 */
async function renderDetailPanelEntry(ctx) {
  const prev = previousDetailPr;
  previousDetailPr = currentDetailPr;
  await renderDetailPanel(ctx, {
    currentPr: currentDetailPr,
    previousPr: prev,
    github: githubClient,
  });
}

async function render(ctx) {
  ctx.renderPanel(
    INBOX_PANEL,
    renderInboxPanel(ctx, {
      auth: currentAuth ?? { status: "offline" },
      workspace: currentWorkspace,
      repo: currentRepo,
      scope: effectiveScope(),
      tab: inboxState.activeTab,
      notifications: inboxState.notifications,
      dismissedIds: dismissedSet,
      error: inboxState.error,
      lastRefreshIso: inboxState.lastRefreshIso,
    }),
  );
  await renderDetailPanelEntry(ctx);
}

async function hydrateWorkspace(workspace) {
  currentWorkspace = workspace;
  if (workspace === null) {
    currentRepo = null;
    return;
  }
  if (repoByWorkspace.has(workspace.id)) {
    currentRepo = repoByWorkspace.get(workspace.id);
    return;
  }
  const repo = await detectRepoForRoot(workspace.root);
  repoByWorkspace.set(workspace.id, repo);
  currentRepo = repo;
}

/**
 * Rebuild the GitHub client from the latest auth result. Called on
 * every activation; sets `githubClient` to `null` when auth is in any
 * non-ok state so callers (Phase 2 / 3 / 4 / 5) can short-circuit
 * cleanly. We never persist or rotate the client — replacing the
 * reference on each activation matches the auth-rotation story.
 */
function rebuildGithubClient() {
  if (currentAuth !== null && currentAuth.status === "ok") {
    githubClient = createGithubClient({
      token: currentAuth.token,
      userAgent: USER_AGENT,
    });
  } else {
    githubClient = null;
  }
}

// ─────────────────────────────────────────────────────────────
// === Phase 4: Review actions — sheet builders + dispatch ===
// ─────────────────────────────────────────────────────────────
// Kept here rather than in render/* because the bottom sheets are
// imperative (showBottomSheet) and the submit handler needs direct
// access to githubClient + currentDetailPr + the prDetail re-render
// entry point. Splitting these into a helper module would force a
// dependency-injection dance that's heavier than the body itself.

/**
 * Build the body bottom-sheet (textfield + submit) for any of the four
 * review/comment actions. Initial textfield value comes from
 * `reviewBodyBuffer` so the quote-prefill applied at sheet-open time
 * survives the round-trip into showBottomSheet.
 *
 * @param {'approve' | 'request-changes' | 'comment' | 'reply'} action
 * @param {string | null} replyToAuthor
 */
function buildReviewBodySheet(action, replyToAuthor) {
  const placeholder =
    action === "approve" || action === "request-changes"
      ? "Optional summary…"
      : "Write a comment…";
  return ui.bottomSheet({
    id: "prcomp-review-body-sheet",
    title: reviewSheetHeading(action, replyToAuthor),
    child: ui.column({
      id: "prcomp-review-body-col",
      gap: "md",
      children: [
        // Heading comes from the bottom-sheet's native `title` slot;
        // no inline ui.text dupe needed.
        ui.textField({
          id: NODE_REVIEW_BODY_FIELD,
          label: "Body",
          // Pass the seeded buffer so the reply quote-prefill survives.
          // Subsequent keystrokes drive `reviewBodyBuffer` directly via
          // the `changed` event handler — the value rendered here is
          // only the initial seed.
          value: reviewBodyBuffer,
          placeholder,
        }),
        ui.button({
          id: NODE_REVIEW_SUBMIT_BTN,
          label: "Submit",
          style: "primary",
        }),
      ],
    }),
  });
}

/**
 * Open the Review action sheet (Approve / Request changes / Comment
 * only). User pick lands back as a `detail-review-*` event on the
 * detail panel, which routes through `handlePhase4ReviewEvent`.
 *
 * @param {{ showActionSheet: (panelId: string, sheet: import("@openvsmobile/sdk").UiActionSheet) => Promise<unknown> }} ctx
 */
async function openReviewActionSheet(ctx) {
  await ctx.showActionSheet(DETAIL_PANEL, {
    id: "prcomp-detail-review-sheet",
    title: "Review",
    actions: [
      { label: "Approve", eventId: reviewEvents.PICK_APPROVE },
      { label: "Request changes", eventId: reviewEvents.PICK_REQUEST_CHANGES },
      { label: "Comment only", eventId: reviewEvents.PICK_COMMENT },
    ],
  });
}

/**
 * Pre-open hook: stash submit context, seed body buffer, then open the
 * body sheet. `prefillBody` is the quote-block for replies (empty
 * otherwise); `replyToAuthor` drives the heading text for the reply
 * case only.
 *
 * @param {{ showBottomSheet: (panelId: string, sheet: import("@openvsmobile/sdk").UiBottomSheet) => Promise<unknown> }} ctx
 * @param {{ action: 'approve' | 'request-changes' | 'comment' | 'reply', replyToId?: number, prefillBody?: string, replyToAuthor?: string | null }} opts
 */
async function openReviewBodySheet(ctx, opts) {
  reviewBodyBuffer = opts.prefillBody ?? "";
  // github.js writes don't carry an AbortSignal (only the reads do), so
  // a slow POST has no upper bound — an unconditional reset here would
  // let a double-tap-then-reopen sequence fire a second POST while the
  // first is still in flight. Only clear the guard when the prior
  // context already resolved (submitReviewBody's `finally` clears
  // reviewSubmitContext to null).
  if (reviewSubmitContext === null) {
    reviewSubmitPending = false;
  }
  reviewSubmitContext = {
    action: opts.action,
    ...(opts.replyToId !== undefined ? { replyToId: opts.replyToId } : {}),
  };
  await ctx.showBottomSheet(
    DETAIL_PANEL,
    buildReviewBodySheet(opts.action, opts.replyToAuthor ?? null),
  );
}

/**
 * Submit the body buffer against the currently-staged submit context.
 * Single entry point for all four action POSTs so the pending-guard +
 * error-mapping + re-fetch flow stays in one place.
 *
 * Pending-state UX: the bottom sheet has no host-side spinner and no
 * plugin-driven dismiss. We guard double-taps with
 * `reviewSubmitPending`; on success we leave the sheet open (the user
 * taps outside to close, and a fresh tap on Review/Comment opens a new
 * sheet with a cleared buffer). See report (a) for the SDK gap.
 *
 * @param {{ log: (level: string, msg: string) => void, renderPanel: (panelId: string, tree: unknown) => void }} ctx
 */
async function submitReviewBody(ctx) {
  if (reviewSubmitPending) return true;
  if (reviewSubmitContext === null) {
    ctx.log("warn", "prcomp: submit fired without an active review context");
    return true;
  }
  if (githubClient === null) {
    setReviewError({ kind: "unauthed", action: reviewSubmitContext.action });
    void renderDetailPanelEntry(ctx);
    return true;
  }
  if (currentDetailPr === null) {
    ctx.log("warn", "prcomp: submit fired with no PR open");
    return true;
  }

  reviewSubmitPending = true;
  // Clear the prior error so a successful submit doesn't leave a stale
  // banner up; if THIS submit fails we'll re-set it below.
  setReviewError(null);

  const ctxRef = reviewSubmitContext;
  const body = reviewBodyBuffer;
  const prRef = currentDetailPr;
  try {
    /** @type {{ status: string, code?: number }} */
    let result;
    if (ctxRef.action === "approve") {
      result = await githubClient.postReview({
        owner: prRef.owner,
        repo: prRef.repo,
        number: prRef.number,
        event: "APPROVE",
        body,
      });
    } else if (ctxRef.action === "request-changes") {
      result = await githubClient.postReview({
        owner: prRef.owner,
        repo: prRef.repo,
        number: prRef.number,
        event: "REQUEST_CHANGES",
        body,
      });
    } else if (ctxRef.action === "comment") {
      // Top-level PR comments need a non-empty body — GitHub rejects
      // empty issue-comment POSTs at the API layer. Surface as a
      // serverError-style banner without sending the round trip.
      if (typeof body !== "string" || body.trim().length === 0) {
        setReviewError({ kind: "serverError", action: "comment", code: 422 });
        void renderDetailPanelEntry(ctx);
        return true;
      }
      result = await githubClient.postPullComment({
        owner: prRef.owner,
        repo: prRef.repo,
        number: prRef.number,
        body,
      });
    } else {
      // reply
      if (typeof body !== "string" || body.trim().length === 0) {
        setReviewError({ kind: "serverError", action: "reply", code: 422 });
        void renderDetailPanelEntry(ctx);
        return true;
      }
      if (ctxRef.replyToId === undefined) {
        ctx.log("warn", "prcomp: reply submit with no replyToId");
        return true;
      }
      result = await githubClient.postPullCommentReply({
        owner: prRef.owner,
        repo: prRef.repo,
        number: prRef.number,
        replyToId: ctxRef.replyToId,
        body,
      });
    }

    if (result.status === "ok") {
      // Success path: clear submit context + buffer, kick a re-fetch so
      // the new review/comment shows up in the Conversation tab. The
      // sheet stays open (SDK gap — see report (a)); user taps outside
      // to dismiss.
      reviewSubmitContext = null;
      reviewBodyBuffer = "";
      void renderDetailPanelEntry(ctx);
      return true;
    }

    // Failure path: surface a banner that names the failing action.
    setReviewError({ ...mapPostError(result), action: ctxRef.action });
    void renderDetailPanelEntry(ctx);
    return true;
  } catch (err) {
    ctx.log(
      "error",
      `prcomp: review submit threw: ${err?.message ?? String(err)}`,
    );
    setReviewError({ kind: "unknown", action: ctxRef.action });
    void renderDetailPanelEntry(ctx);
    return true;
  } finally {
    reviewSubmitPending = false;
  }
}

/**
 * Dispatch entry point for every Phase 4 event that lands on the
 * detail panel id. Returns `true` when handled (so index.js's
 * onUiEvent can early-return), `false` when the event isn't one of
 * ours (the warn fall-through then logs it).
 *
 * @param {{ log: (level: string, msg: string) => void, renderPanel: (panelId: string, tree: unknown) => void, showActionSheet: (panelId: string, sheet: import("@openvsmobile/sdk").UiActionSheet) => Promise<unknown>, showBottomSheet: (panelId: string, sheet: import("@openvsmobile/sdk").UiBottomSheet) => Promise<unknown> }} ctx
 * @param {{ type: string, nodeId: string, payload?: unknown }} event
 */
async function handlePhase4ReviewEvent(ctx, event) {
  // Review button on the detail header.
  if (event.nodeId === NODE_REVIEW_BTN && event.type === "tap") {
    await openReviewActionSheet(ctx);
    return true;
  }

  // Action-sheet picks. Three eventIds all open the same body sheet,
  // just with different action context.
  if (event.type === reviewEvents.PICK_APPROVE) {
    await openReviewBodySheet(ctx, { action: "approve" });
    return true;
  }
  if (event.type === reviewEvents.PICK_REQUEST_CHANGES) {
    await openReviewBodySheet(ctx, { action: "request-changes" });
    return true;
  }
  if (event.type === reviewEvents.PICK_COMMENT) {
    await openReviewBodySheet(ctx, { action: "comment" });
    return true;
  }

  // Top-level Comment button on the Conversation tab.
  if (
    event.nodeId === conversationEvents.COMMENT_BUTTON_NODE &&
    event.type === "tap"
  ) {
    await openReviewBodySheet(ctx, { action: "comment" });
    return true;
  }

  // Per-comment reply button. Button widgets fire {type:'tap', nodeId},
  // so we match on the node id prefix (`prcomp-detail-conv-reply-btn-`).
  // Look up the cached comment to seed the quote prefill; if the
  // comment isn't cached (race with PR switch), fall back to an empty
  // body — the user can still reply, they just don't get the quote.
  if (
    event.type === "tap" &&
    typeof event.nodeId === "string" &&
    event.nodeId.startsWith("prcomp-detail-conv-reply-btn-")
  ) {
    const idStr = event.nodeId.slice("prcomp-detail-conv-reply-btn-".length);
    const commentId = Number(idStr);
    if (!Number.isInteger(commentId) || commentId <= 0) {
      ctx.log("warn", `prcomp: bad reply comment id ${idStr}`);
      return true;
    }
    const comment = getDetailComment(currentDetailPr, commentId);
    if (comment === null) {
      // No cached comment — open a bare reply sheet so the user can
      // still type. The original-author heading degrades to "Reply to
      // comment".
      await openReviewBodySheet(ctx, {
        action: "reply",
        replyToId: commentId,
        prefillBody: "",
        replyToAuthor: null,
      });
      return true;
    }
    await openReviewBodySheet(ctx, {
      action: "reply",
      replyToId: commentId,
      prefillBody: buildReplyQuotePrefill(comment),
      replyToAuthor: comment.user.login,
    });
    return true;
  }

  // TextField content changes — keep the body buffer in sync without
  // re-rendering on every keystroke (the bottom sheet's textfield owns
  // its own native focus/value state across renders).
  if (event.nodeId === NODE_REVIEW_BODY_FIELD && event.type === "changed") {
    const payload = /** @type {{ value?: unknown } | null | undefined} */ (event.payload);
    const value = payload !== null && payload !== undefined ? payload.value : undefined;
    reviewBodyBuffer = typeof value === "string" ? value : "";
    return true;
  }

  // Submit button.
  if (event.nodeId === NODE_REVIEW_SUBMIT_BTN && event.type === "tap") {
    return submitReviewBody(ctx);
  }

  return false;
}

// No `__testing` export from this module: importing index.js at test
// time would run `plugin.run()` at the bottom, which wires
// `process.stdin` listeners and tries to bring up the SDK runtime.
// Phase 4's testable pure helpers live in render/reviewSheets.js
// (event constants + reply-prefill + error mapping); the dispatch
// orchestration above is integration-only and exercised end-to-end by
// the plugin-host smoke tests once those cover Phase 4.

const plugin = createPlugin({
  async onActivate(ctx) {
    currentCtx = ctx;
    // Order: workspace first (so a slow git spawn doesn't block the
    // first paint behind /user latency), then auth, then state load,
    // then first render. The first render only happens after all
    // three are resolved — there is no useful interim state worth
    // painting before then.
    const workspace = await ctx.currentWorkspace();
    await hydrateWorkspace(workspace);
    currentAuth = await resolveGhAuth();

    // === Phase 2: persisted-state load ===
    persistedState = await loadState(ctx);
    dismissedSet = new Set(persistedState.dismissedIds);
    // === Phase 6: seed shown-notifications Set from disk ===
    // Empty Set ⇔ cold start, which `computeNotifFanout` reads as "do
    // not fire toasts on this poll, just remember the ids". State on
    // disk persists across plugin restarts, so a normal restart of an
    // active plugin will NOT cold-start — the previous run's
    // shownNotifIds carries over.
    shownNotifSet = new Set(persistedState.shownNotifIds);

    // === Cross-phase: GitHub client ===
    rebuildGithubClient();

    if (githubClient !== null) {
      // === Phase 2: inbox poll loop ===
      // First poll runs concurrently with the initial paint — the
      // paint reflects the empty list + the "no PRs" empty state, then
      // the next render after the fetch fills it in. Acceptable
      // because the empty state is brief and the alternative (await
      // pollInbox before first paint) holds the user behind a blank
      // panel for the full HTTP round trip.
      pollInbox(ctx)
        .then((changed) => {
          if (changed) void render(ctx);
        })
        .catch((err) => {
          ctx.log(
            "error",
            `prcomp: initial poll threw: ${err?.message ?? String(err)}`,
          );
        });
      // 60s foreground cadence. The unref() lets the process exit if
      // every other handle has drained (e.g. tests); the host's
      // long-lived stdin listener keeps the process alive in
      // production.
      inboxTimer = setInterval(() => {
        pollInbox(ctx)
          .then((changed) => {
            if (changed) void render(ctx);
          })
          .catch((err) => {
            ctx.log(
              "error",
              `prcomp: inbox poll threw: ${err?.message ?? String(err)}`,
            );
          });
      }, INBOX_POLL_INTERVAL_MS);
      inboxTimer.unref?.();
    }

    await render(ctx);
  },
  async onWorkspaceActivated(ctx, workspace) {
    currentCtx = ctx;
    // Invalidate the cached repo for the workspace we're entering — the
    // remote could have been re-pointed in the terminal between
    // activations. Cheap: one process spawn per workspace switch.
    if (workspace !== null) {
      repoByWorkspace.delete(workspace.id);
    }
    await hydrateWorkspace(workspace);
    await render(ctx);
    // Workspace switch = scope change in most cases. Kick a poll so
    // the user sees instant feedback for the new scope; the ETag
    // means the call is essentially free on the wire even when the
    // notification list is unchanged.
    //
    // Detail panel is workspace-agnostic in Phase 3 (the open PR is
    // pinned by id, not by workspace), so we don't tear it down on a
    // workspace switch.
    if (githubClient !== null) {
      pollInbox(ctx)
        .then((changed) => {
          if (changed) void render(ctx);
        })
        .catch((err) => {
          ctx.log(
            "error",
            `prcomp: post-switch poll threw: ${err?.message ?? String(err)}`,
          );
        });
    }
  },
  async onUiEvent(ctx, event) {
    currentCtx = ctx;
    // === Phase 2: Inbox events ===
    if (event.panelId === INBOX_PANEL) {
      await handleInboxEvent(ctx, event, {
        getInbox: () => inboxState,
        setActiveTab: (tabId) => {
          if (
            tabId === "review" ||
            tabId === "mentioned" ||
            tabId === "assigned"
          ) {
            inboxState.activeTab = tabId;
          }
        },
        getScope: effectiveScope,
        setScope: setScopeForCurrent,
        getRepo: () => currentRepo,
        getWorkspace: () => currentWorkspace,
        getAuth: () => currentAuth ?? { status: "offline" },
        getDismissedIds: () => dismissedSet,
        addDismissedId,
        openPrDetail: (ref) => {
          currentDetailPr = ref;
          void renderDetailPanelEntry(ctx);
        },
        pollInbox: () => pollInbox(ctx),
        rerender: () => {
          void render(ctx);
        },
      });
      return;
    }
    // === Phase 3: Detail events ===
    if (event.panelId === DETAIL_PANEL) {
      const handled = handleDetailEvent(ctx, event, {
        currentPr: currentDetailPr,
        github: githubClient,
      });
      if (handled === true) return;

      // === Phase 6: Checks-tab log bottom sheet ===
      // Sits BEFORE the Phase-4 review dispatch on purpose: the check-
      // log event prefix is distinct from any review-action event
      // (`detail-review-*` / button taps), so ordering is just style,
      // but matching here keeps the Phase-6 surface near the rest of
      // its Phase-6 wiring above (fanOutNotifications / handleChecksLogTap).
      if (
        typeof event.type === "string" &&
        event.type.startsWith(CHECK_LOG_EVENT_PREFIX)
      ) {
        const idxStr = event.type.slice(CHECK_LOG_EVENT_PREFIX.length);
        const idx = Number(idxStr);
        await handleChecksLogTap(ctx, idx);
        return;
      }
      // === end Phase 6 ===

      // === Phase 4: Review actions ===
      // Placed inside the Phase 3 panel block so the Phase 5 worker's
      // detail-side additions (Checks tab events) land cleanly above or
      // below this section without touching the dispatch we own. All
      // Phase 4 events ride the detail panel id because the bottom-
      // sheets we open also carry DETAIL_PANEL (host routes the
      // resulting onUiEvent back to the same panel id we passed to
      // showBottomSheet).
      const phase4Handled = await handlePhase4ReviewEvent(ctx, event);
      if (phase4Handled === true) return;
      // === end Phase 4: Review actions ===
    }

    // Fall-through: log unknown events so the wire path is observable
    // without pretending to handle anything.
    ctx.log(
      "warn",
      `prcomp: unhandled event ${event.panelId}/${event.type}`,
    );
  },
});

// When the host closes stdin the SDK lets the event loop drain. The
// inbox + detail polling intervals are `unref()`'d so they don't keep
// us alive, but a SIGTERM (or stdin EOF inside a tty) should also clear
// them explicitly so vitest / test harnesses don't see a dangling
// handle.
const shutdown = () => {
  if (inboxTimer !== null) {
    clearInterval(inboxTimer);
    inboxTimer = null;
  }
  stopDetailPolling();
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
process.stdin.once("end", shutdown);

plugin.run();
