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
import { loadState, saveState } from "./state.js";
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
};
let dismissedSet = /** @type {Set<string>} */ (new Set());

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
 * @param {{ log: (level: string, msg: string) => void }} ctx
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
        ui.text({
          id: "prcomp-review-body-heading",
          text: reviewSheetHeading(action, replyToAuthor),
          style: "title",
        }),
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
  reviewSubmitContext = {
    action: opts.action,
    ...(opts.replyToId !== undefined ? { replyToId: opts.replyToId } : {}),
  };
  // Each open clears any stale pending guard from a previous attempt.
  // The submit handler is the only path that flips `reviewSubmitPending
  // = true`; if we got back to "user is opening a fresh sheet", any
  // half-finished prior attempt either resolved or timed out at the
  // fetch layer (github.js has a 10s timeout).
  reviewSubmitPending = false;
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

  // Per-comment reply (swipe action OR row tap, both carry the same
  // eventId prefix). Look up the cached comment to seed the quote
  // prefill; if the comment isn't cached (race with PR switch), fall
  // back to an empty body — the user can still reply, they just don't
  // get the quote.
  if (typeof event.type === "string" && event.type.startsWith(conversationEvents.REPLY_PREFIX)) {
    const idStr = event.type.slice(conversationEvents.REPLY_PREFIX.length);
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
