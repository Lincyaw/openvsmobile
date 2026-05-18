// PR Companion — PR detail panel (Phase 3, read-only).
//
// Single fixed panel id (`detail` — see design doc "Resolved design
// choices" #2). The "which PR is open" question is internal plugin
// state. Phase 2's Inbox tab triggers a new PR open by setting the
// shared `currentDetailPr` (in index.js) then calling
// `renderDetailPanel(ctx, deps)` which we own.
//
// What ships here:
//   * Three-tab structure (Conversation / Files / Checks). Conversation
//     and Files tabs are fully rendered (see render/conversationTab.js
//     and render/filesTab.js). The Checks tab is a Phase 5 placeholder
//     — we intentionally do NOT fetch check-runs.
//   * In-memory LRU cache of `{pr, files, comments, etagPr, etagFiles,
//     etagComments, lastFetchAt}` keyed by `owner/repo#number`. Cap 20.
//     Stale-while-revalidate semantics: hit the cache for first paint,
//     refetch in the background, re-render on success.
//   * 30s polling while a PR is open. Stops when the PR is closed or
//     the plugin shuts down.
//   * Partial-failure rendering: if any of getPull / listPullFiles /
//     listPullComments fails, the others still render their tabs;
//     only the failing tab degrades to a caption.
//
// What does NOT ship here (Phase 4+):
//   * "Review" / "Comment" buttons.
//   * Inline file-comment UI / review thread replies.
//   * Checks tab content.
//   * Notification fan-out.
//
// Cross-phase contract: this module reads `currentDetailPr` from the
// dep bag injected by index.js. Phase 2 will set / clear it from the
// Inbox-tap path; the merge point in index.js threads it through
// `getCurrentDetailPr()` so neither phase has to import a mutable from
// the other.

import { ui } from "@openvsmobile/sdk";

import { buildConversationTabBody } from "./conversationTab.js";
import { buildFilesTabBody } from "./filesTab.js";
// === Phase 5 additions ===
import { renderChecksTab } from "./checksTab.js";
// === end Phase 5 additions ===

const DETAIL_PANEL = "detail";

// Module-level detail state. Reset by `resetDetailState` whenever the
// open PR changes. Held here rather than in index.js so the merge with
// Phase 2 stays mechanical (Phase 2 owns its own state slot).
const DEFAULT_DETAIL_STATE = Object.freeze({
  /** @type {"conversation" | "files" | "checks"} */
  currentTab: "conversation",
  /** @type {string | null} */
  openFile: null,
  /** @type {{ kind: string } | null} */
  error: null,
  /** @type {boolean} */
  loading: false,
  // === Phase 5 additions ===
  // Per-tab error slot now also tracks the Checks leg; checkRuns
  // starts null so the tab can distinguish "haven't fetched yet" from
  // "fetched and got an empty list" (the latter renders the empty
  // state caption).
  /** @type {{ pr?: { kind: string }, files?: { kind: string }, comments?: { kind: string }, checks?: { kind: string } }} */
  perTabError: {},
  /** @type {Array<{ id: number, name: string, status: string, conclusion: string | null, startedAt: string | null, completedAt: string | null }> | null} */
  checkRuns: null,
  // === end Phase 5 additions ===
});

/** @type {ReturnType<typeof makeDetailState>} */
let detailState = makeDetailState();

function makeDetailState() {
  return {
    currentTab: DEFAULT_DETAIL_STATE.currentTab,
    openFile: DEFAULT_DETAIL_STATE.openFile,
    error: DEFAULT_DETAIL_STATE.error,
    loading: DEFAULT_DETAIL_STATE.loading,
    /** @type {{ pr?: { kind: string }, files?: { kind: string }, comments?: { kind: string }, checks?: { kind: string } }} */
    perTabError: {},
    // === Phase 5 additions ===
    /** @type {Array<{ id: number, name: string, status: string, conclusion: string | null, startedAt: string | null, completedAt: string | null }> | null} */
    checkRuns: null,
    // === end Phase 5 additions ===
    // === Phase 4 additions ===
    // Slot for review/comment POST failures. Distinct from `error` (which
    // tracks fetch failures from the 30s poll) so a transient write
    // failure doesn't get masked by a successful subsequent read, and a
    // stuck read failure doesn't pretend the write also failed. Banner
    // sits above the fetch-error banner; cleared by setReviewError(null)
    // on retry or successful POST.
    /** @type {{ kind: string, action?: string, code?: number } | null} */
    reviewError: null,
  };
}

// LRU cache. Map iteration order is insertion order; we refresh entries
// by delete-then-set on every cache hit/set so the oldest entry is
// always the first one in iteration. Cap is 20 (design doc §"Data
// model & caching").
const CACHE_CAP = 20;
// === Phase 5 additions ===
// Cache shape gains `checks` + `etagChecks`. Both stay null when the
// PR has no headSha yet (chicken-and-egg: listCheckRuns is per-ref and
// the ref comes from the PR fetch) — see fetchAndRender below.
// === end Phase 5 additions ===
/** @type {Map<string, { pr: unknown, files: unknown, comments: unknown, checks: unknown, etagPr: string | null, etagFiles: string | null, etagComments: string | null, etagChecks: string | null, lastFetchAt: number }>} */
const prDetailCache = new Map();

function cacheKey(currentPr) {
  return `${currentPr.owner}/${currentPr.repo}#${currentPr.number}`;
}

function cacheGet(currentPr) {
  const key = cacheKey(currentPr);
  if (!prDetailCache.has(key)) return null;
  const entry = prDetailCache.get(key);
  // Refresh LRU position.
  prDetailCache.delete(key);
  prDetailCache.set(key, entry);
  return entry;
}

function cacheSet(currentPr, entry) {
  const key = cacheKey(currentPr);
  if (prDetailCache.has(key)) prDetailCache.delete(key);
  prDetailCache.set(key, entry);
  while (prDetailCache.size > CACHE_CAP) {
    // Drop oldest. `keys().next().value` on a Map yields the
    // first-inserted (post-refresh-aware) key.
    const oldestKey = prDetailCache.keys().next().value;
    if (oldestKey === undefined) break;
    prDetailCache.delete(oldestKey);
  }
}

// Polling. One interval per process; restart on currentPr change.
/** @type {ReturnType<typeof setInterval> | null} */
let detailTimer = null;

const POLL_INTERVAL_MS = 30_000;

// Generation counter used to guard against stale-render races: when the
// user taps PR1 then quickly switches to PR2 before PR1's fetch
// resolves, PR1's tail (`pushPanel` + detailState writes) must not
// clobber PR2's rendered state. Each fetchAndRender invocation captures
// `++detailGen` and bails after every await if the global has moved on.
let detailGen = 0;

/**
 * Compute the status badge text for the header. GitHub's `state` is
 * either "open" or "closed"; `merged` and `draft` are separate
 * booleans. The design doc shows four labels.
 *
 * @param {{ state: string, draft: boolean, merged: boolean }} pr
 */
function statusBadgeText(pr) {
  if (pr.merged === true) return "merged";
  if (pr.state === "closed") return "closed";
  if (pr.draft === true) return "draft";
  return "open";
}

/**
 * Map status text → AccentToken. Picked from the union the host
 * validates against (`brand|info|success|warning|danger|muted`).
 *
 * @param {string} status
 */
function statusBadgeAccent(status) {
  switch (status) {
    case "merged":
      return "brand";
    case "closed":
      return "danger";
    case "draft":
      return "muted";
    default:
      return "success";
  }
}

/**
 * Translate the structured error returned by github.js into a banner
 * description. `null` → no banner.
 *
 * @param {{ kind: string, resetAt?: Date, code?: number } | null} error
 */
function buildBanner(error) {
  if (error === null) return null;
  switch (error.kind) {
    case "unauthed":
      return ui.banner({
        id: "prcomp-detail-banner",
        title: "GitHub token revoked",
        body: "Re-auth via `gh auth login` in the terminal.",
        accent: "danger",
      });
    case "offline":
      return ui.banner({
        id: "prcomp-detail-banner",
        title: "Offline",
        body: "Showing cached PR data.",
        accent: "info",
      });
    case "rateLimited": {
      const reset =
        error.resetAt instanceof Date
          ? error.resetAt.toISOString().slice(11, 16) // HH:MM UTC
          : "soon";
      return ui.banner({
        id: "prcomp-detail-banner",
        title: "Rate-limited",
        body: `GitHub rate-limited until ${reset}.`,
        accent: "warning",
      });
    }
    case "serverError":
      return ui.banner({
        id: "prcomp-detail-banner",
        title: "GitHub error",
        body: typeof error.code === "number" ? `HTTP ${error.code}.` : "Unknown error.",
        accent: "danger",
      });
    default:
      return null;
  }
}

/**
 * Empty-state placeholder. Same shape as the Phase 1 stub so the panel
 * doesn't visually change when the user has no PR open.
 */
function buildEmpty() {
  return ui.section({
    id: "prcomp-detail-section",
    title: "PR Detail",
    children: [
      ui.text({
        id: "prcomp-detail-placeholder",
        text: "Open a PR from the Inbox tab.",
      }),
    ],
  });
}

/**
 * Header card: avatar, title, owner/repo · #N · by @login, status badge.
 *
 * @param {{ owner: string, repo: string, number: number }} currentPr
 * @param {{ title: string, user: { login: string, avatarUrl: string }, state: string, draft: boolean, merged: boolean }} pr
 */
function buildHeader(currentPr, pr) {
  const status = statusBadgeText(pr);
  return ui.section({
    id: "prcomp-detail-header",
    variant: "card",
    children: [
      ui.row({
        id: "prcomp-detail-header-row",
        gap: "sm",
        children: [
          ui.avatar({
            id: "prcomp-detail-header-avatar",
            src: pr.user.avatarUrl,
          }),
          ui.column({
            id: "prcomp-detail-header-text",
            gap: "xs",
            children: [
              ui.text({
                id: "prcomp-detail-header-title",
                text: pr.title,
                style: "title",
              }),
              ui.text({
                id: "prcomp-detail-header-subtitle",
                text: `${currentPr.owner}/${currentPr.repo} · #${currentPr.number} · by @${pr.user.login}`,
                style: "caption",
              }),
            ],
          }),
          ui.badge({
            id: "prcomp-detail-header-status",
            text: status,
            accent: statusBadgeAccent(status),
          }),
        ],
      }),
      // --- Phase 4: Review button row ---
      // Single primary button; tapping fires `{type:'tap', nodeId:
      // 'prcomp-detail-review-btn'}` (UiButton has no onTapEvent slot —
      // dispatch is by node id, matching the inbox scope-switch pattern).
      // index.js's Phase-4 dispatch opens an action sheet from here.
      ui.row({
        id: "prcomp-detail-header-actions",
        gap: "sm",
        children: [
          ui.button({
            id: "prcomp-detail-review-btn",
            label: "Review…",
            style: "primary",
          }),
        ],
      }),
      // --- end Phase 4: Review button row ---
    ],
  });
}

/**
 * Body for the active tab. The full tree always includes one of the
 * three; we never re-shape the panel structure based on which tab is
 * active so the renderer can preserve focus/scroll per nodeId.
 *
 * @param {ReturnType<typeof makeDetailState>} state
 * @param {{ pr: unknown, files: unknown, comments: unknown, checks?: unknown } | null} data
 */
function buildTabBody(state, data) {
  const pr = /** @type {{ body: string } | null} */ (data?.pr ?? null);
  const files = /** @type {Array<{ filename: string, additions: number, deletions: number, patch: string | null }> | null} */ (data?.files ?? null);
  const comments = /** @type {Array<{
    id: number,
    user: { login: string, avatarUrl: string },
    body: string,
    createdAt: string,
    path: string | null,
    inReplyToId: number | null,
  }> | null} */ (data?.comments ?? null);

  switch (state.currentTab) {
    case "files":
      return buildFilesTabBody({
        files,
        openFile: state.openFile,
        error: state.perTabError.files ?? null,
      });
    case "checks": {
      // === Phase 5 additions ===
      // Prefer data (cache) over detailState so cached check-runs
      // render instantly on a re-open; the in-flight fetch will then
      // overwrite via detailState on the next pushPanel.
      const cachedChecks = /** @type {Array<{ id: number, name: string, status: string, conclusion: string | null, startedAt: string | null, completedAt: string | null }> | null | undefined} */ (data?.checks);
      const checkRuns =
        cachedChecks !== undefined && cachedChecks !== null
          ? cachedChecks
          : state.checkRuns;
      return renderChecksTab({
        pr,
        checkRuns,
        error: state.perTabError.checks ?? null,
      });
      // === end Phase 5 additions ===
    }
    case "conversation":
    default:
      return buildConversationTabBody({
        pr: /** @type {{ body: string } | null} */ (pr),
        comments,
        error: state.perTabError.comments ?? null,
      });
  }
}

/**
 * Assemble the full panel tree.
 *
 * @param {{ owner: string, repo: string, number: number } | null} currentPr
 * @param {ReturnType<typeof makeDetailState>} state
 * @param {{ pr: unknown, files: unknown, comments: unknown, checks?: unknown } | null} data
 */
export function buildDetailPanelTree(currentPr, state, data) {
  if (currentPr === null) {
    return buildEmpty();
  }
  if (state.loading === true && data === null) {
    // First fetch in flight, no cache. Show a spinner. Subsequent
    // refetches reuse the existing data and skip this branch.
    return ui.column({
      id: "prcomp-detail-root",
      gap: "md",
      children: [
        ui.spinner({
          id: "prcomp-detail-spinner",
          label: "Loading PR…",
        }),
      ],
    });
  }

  /** @type {import("@openvsmobile/sdk").UiNode[]} */
  const children = [];

  // === Phase 4 additions ===
  // Review/comment POST error banner sits above the fetch-error banner
  // so a write failure is the first thing the user sees on their next
  // render. Self-dismisses on the next successful POST (or on a retry).
  const reviewBanner = buildReviewErrorBanner(state.reviewError);
  if (reviewBanner !== null) children.push(reviewBanner);
  // === end Phase 4 additions ===

  const banner = buildBanner(state.error);
  if (banner !== null) children.push(banner);

  if (data !== null && data.pr !== null) {
    children.push(buildHeader(currentPr, /** @type {{ title: string, user: { login: string, avatarUrl: string }, state: string, draft: boolean, merged: boolean }} */ (data.pr)));
  } else if (state.perTabError.pr !== undefined) {
    // Header fetch failed AND no cached header to fall back on. Render
    // a minimal slug-style header so the user still has context.
    children.push(
      ui.section({
        id: "prcomp-detail-header",
        variant: "card",
        children: [
          ui.text({
            id: "prcomp-detail-header-fallback",
            text: `${currentPr.owner}/${currentPr.repo} #${currentPr.number}`,
            style: "title",
          }),
          ui.text({
            id: "prcomp-detail-header-fallback-sub",
            text: `Failed to load PR header (${state.perTabError.pr.kind}).`,
            style: "caption",
          }),
        ],
      }),
    );
  }

  children.push(
    ui.tabBar({
      id: "prcomp-detail-tabs",
      tabs: [
        { id: "conversation", label: "Conversation" },
        { id: "files", label: "Files" },
        { id: "checks", label: "Checks" },
      ],
      activeId: state.currentTab,
      onChangeEvent: "detail-tab-changed",
    }),
    ui.section({
      id: "prcomp-detail-body",
      children: [buildTabBody(state, data)],
    }),
  );

  return ui.column({
    id: "prcomp-detail-root",
    gap: "md",
    children,
  });
}

/**
 * Render the detail panel using current state + cache. Pure write — no
 * fetching, no state mutation beyond the host push.
 *
 * @param {{
 *   renderPanel: (panelId: string, tree: unknown) => void,
 * }} ctx
 * @param {{ owner: string, repo: string, number: number } | null} currentPr
 */
function pushPanel(ctx, currentPr) {
  const data =
    currentPr === null
      ? null
      : (() => {
          const e = prDetailCache.get(cacheKey(currentPr));
          return e === undefined
            ? null
            // === Phase 5 additions: include `checks` slot ===
            : { pr: e.pr, files: e.files, comments: e.comments, checks: e.checks };
            // === end Phase 5 additions ===
        })();
  ctx.renderPanel(DETAIL_PANEL, buildDetailPanelTree(currentPr, detailState, data));
}

/**
 * Reset detailState back to defaults. Called whenever the open PR
 * changes (so a re-opened PR doesn't inherit the previous PR's tab /
 * openFile state).
 */
function resetDetailState() {
  detailState = makeDetailState();
}

/**
 * Run all three GitHub reads in parallel, set the cache + per-tab
 * errors, and re-render. Tolerates partial failure: one rejected leg
 * does NOT prevent the others from rendering.
 *
 * @param {{
 *   renderPanel: (panelId: string, tree: unknown) => void,
 *   log: (level: string, msg: string) => void,
 * }} ctx
 * @param {{ owner: string, repo: string, number: number }} currentPr
 * @param {{
 *   getPull: (params: { owner: string, repo: string, number: number, etag?: string }) => Promise<any>,
 *   listPullFiles: (params: { owner: string, repo: string, number: number, etag?: string }) => Promise<any>,
 *   listPullComments: (params: { owner: string, repo: string, number: number, etag?: string }) => Promise<any>,
 *   listCheckRuns: (params: { owner: string, repo: string, ref: string, etag?: string }) => Promise<any>,
 * }} github
 */
async function fetchAndRender(ctx, currentPr, github) {
  const myGen = ++detailGen;
  const cached = cacheGet(currentPr);
  const reqParams = { owner: currentPr.owner, repo: currentPr.repo, number: currentPr.number };

  detailState.loading = cached === null;
  pushPanel(ctx, currentPr);

  // === Phase 5 additions ===
  // Chicken-and-egg: listCheckRuns is per-ref, so we need pr.headSha
  // before we can call it. Two cases:
  //   * We already have a cached PR (with headSha) — fire all four
  //     legs in parallel; the ref is good enough until the new getPull
  //     comes back with a (possibly newer) headSha.
  //   * No cache — fire the original three first, then if getPull
  //     succeeded and yielded a ref, do checks as a second stage.
  // The second-stage path adds one round-trip on the very first paint
  // of a never-seen PR; subsequent polls hit the parallel path. The
  // 30s polling cadence amortizes the cost.
  const cachedPr = /** @type {{ headSha?: string } | null | undefined} */ (cached?.pr ?? null);
  const cachedRef =
    cachedPr !== null && cachedPr !== undefined && typeof cachedPr.headSha === "string" && cachedPr.headSha.length > 0
      ? cachedPr.headSha
      : null;
  // === end Phase 5 additions ===

  const [prRes, filesRes, commentsRes, checksResMaybe] = await Promise.all([
    github
      .getPull({ ...reqParams, ...(cached?.etagPr ? { etag: cached.etagPr } : {}) })
      .catch((err) => ({ status: "offline", error: err })),
    github
      .listPullFiles({ ...reqParams, ...(cached?.etagFiles ? { etag: cached.etagFiles } : {}) })
      .catch((err) => ({ status: "offline", error: err })),
    github
      .listPullComments({ ...reqParams, ...(cached?.etagComments ? { etag: cached.etagComments } : {}) })
      .catch((err) => ({ status: "offline", error: err })),
    // === Phase 5 additions ===
    cachedRef === null
      ? Promise.resolve(null)
      : github
          .listCheckRuns({
            owner: currentPr.owner,
            repo: currentPr.repo,
            ref: cachedRef,
            ...(cached?.etagChecks ? { etag: cached.etagChecks } : {}),
          })
          .catch((err) => ({ status: "offline", error: err })),
    // === end Phase 5 additions ===
  ]);

  // === Phase 5 additions ===
  // Second-stage fetch when the cached path didn't run.  Use prRes if
  // it succeeded (preferred — could be a newer headSha) else fall back
  // to nothing. If prRes was a 304 (notModified), the cached headSha
  // is still valid — but we'd have used it on the first stage already,
  // so this branch only fires when there was no cache to begin with.
  let checksRes = checksResMaybe;
  const freshRef =
    prRes.status === "ok" &&
    prRes.pull !== undefined &&
    typeof prRes.pull.headSha === "string" &&
    prRes.pull.headSha.length > 0
      ? prRes.pull.headSha
      : null;
  if (checksResMaybe === null && freshRef !== null) {
    checksRes = await github
      .listCheckRuns({
        owner: currentPr.owner,
        repo: currentPr.repo,
        ref: freshRef,
      })
      .catch((err) => ({ status: "offline", error: err }));
  }
  // === end Phase 5 additions ===

  // Stale-render guard: if the user switched PRs while we were
  // awaiting, drop our writes on the floor — the newer fetch owns the
  // panel now. The cache slot for our PR could still be useful for a
  // future revisit, so persist it below before exiting; but skip
  // detailState mutation + pushPanel.
  const isStale = myGen !== detailGen;
  if (isStale) {
    const anyOk =
      prRes.status === "ok" ||
      filesRes.status === "ok" ||
      commentsRes.status === "ok" ||
      // === Phase 5 additions ===
      (checksRes !== null && checksRes.status === "ok");
      // === end Phase 5 additions ===
    if (currentPr !== null && anyOk) {
      cacheSet(currentPr, {
        pr: prRes.status === "ok" ? prRes.pull : cached?.pr ?? null,
        files: filesRes.status === "ok" ? filesRes.files : cached?.files ?? null,
        comments: commentsRes.status === "ok" ? commentsRes.comments : cached?.comments ?? null,
        // === Phase 5 additions ===
        checks:
          checksRes !== null && checksRes.status === "ok"
            ? checksRes.checkRuns
            : cached?.checks ?? null,
        // === end Phase 5 additions ===
        etagPr: prRes.status === "ok" ? prRes.etag ?? null : cached?.etagPr ?? null,
        etagFiles: filesRes.status === "ok" ? filesRes.etag ?? null : cached?.etagFiles ?? null,
        etagComments: commentsRes.status === "ok" ? commentsRes.etag ?? null : cached?.etagComments ?? null,
        // === Phase 5 additions ===
        etagChecks:
          checksRes !== null && checksRes.status === "ok"
            ? checksRes.etag ?? null
            : cached?.etagChecks ?? null,
        // === end Phase 5 additions ===
        lastFetchAt: Date.now(),
      });
    }
    return;
  }

  detailState.loading = false;
  detailState.perTabError = {};

  // Merge: start from cached values (if any) and overwrite per-leg
  // based on response status. notModified preserves the cached value;
  // ok replaces it; anything else leaves the cached value in place AND
  // sets the per-leg error so the tab can show a caption.
  let pr = cached?.pr ?? null;
  let files = cached?.files ?? null;
  let comments = cached?.comments ?? null;
  let etagPr = cached?.etagPr ?? null;
  let etagFiles = cached?.etagFiles ?? null;
  let etagComments = cached?.etagComments ?? null;
  // === Phase 5 additions ===
  let checks = cached?.checks ?? null;
  let etagChecks = cached?.etagChecks ?? null;
  // === end Phase 5 additions ===

  // -- PR --
  if (prRes.status === "ok") {
    pr = prRes.pull;
    etagPr = prRes.etag ?? null;
  } else if (prRes.status === "notModified") {
    etagPr = prRes.etag ?? etagPr;
  } else {
    detailState.perTabError.pr = { kind: prRes.status, ...prRes };
    if (cached === null) pr = null;
  }

  // -- Files --
  if (filesRes.status === "ok") {
    files = filesRes.files;
    etagFiles = filesRes.etag ?? null;
  } else if (filesRes.status === "notModified") {
    etagFiles = filesRes.etag ?? etagFiles;
  } else {
    detailState.perTabError.files = { kind: filesRes.status, ...filesRes };
    if (cached === null) files = null;
  }

  // -- Comments --
  if (commentsRes.status === "ok") {
    comments = commentsRes.comments;
    etagComments = commentsRes.etag ?? null;
  } else if (commentsRes.status === "notModified") {
    etagComments = commentsRes.etag ?? etagComments;
  } else {
    detailState.perTabError.comments = { kind: commentsRes.status, ...commentsRes };
    if (cached === null) comments = null;
  }

  // === Phase 5 additions ===
  // -- Checks --
  // checksRes === null means we never fired the request (no ref
  // available). That's not an error — leave the cached value alone
  // and don't set a perTabError; the tab will render its loading /
  // empty state. Once getPull succeeds we'll have a ref next poll.
  if (checksRes === null) {
    // intentionally no-op
  } else if (checksRes.status === "ok") {
    checks = checksRes.checkRuns;
    etagChecks = checksRes.etag ?? null;
  } else if (checksRes.status === "notModified") {
    etagChecks = checksRes.etag ?? etagChecks;
  } else {
    detailState.perTabError.checks = { kind: checksRes.status, ...checksRes };
    if (cached === null) checks = null;
  }
  // === end Phase 5 additions ===

  // Top-level banner. Prefer the strongest error: unauthed > rateLimited
  // > offline > serverError. If any leg surfaced one, hoist it so the
  // user sees a single clear cause.
  // === Phase 5 additions ===
  // Checks is intentionally excluded from this set: it can be absent
  // for legitimate reasons (no ref yet, no checks configured) and we
  // don't want a single failing checks leg to mask the rest. Its
  // per-tab error surfaces inside the Checks tab body instead.
  // === end Phase 5 additions ===
  const allErrors = [prRes, filesRes, commentsRes].filter(
    (r) => r.status !== "ok" && r.status !== "notModified",
  );
  if (allErrors.length === 3) {
    // Everything failed — show the worst error as the banner. If all
    // three are the same status (typical for unauthed / offline), the
    // banner alone tells the story.
    // Precedence (per design doc Error states): unauthed > rateLimited
    // > offline > serverError.
    const priority = ["unauthed", "rateLimited", "offline", "serverError"];
    const worst = priority
      .map((k) => allErrors.find((e) => e.status === k))
      .find((e) => e !== undefined);
    detailState.error = worst !== undefined ? { kind: worst.status, ...worst } : null;
  } else {
    detailState.error = null;
  }

  // Persist to cache only if we actually got non-null data for the
  // three legs (otherwise the per-tab fallback path takes over).
  if (pr !== null || files !== null || comments !== null) {
    cacheSet(currentPr, {
      pr,
      files,
      comments,
      // === Phase 5 additions ===
      checks,
      // === end Phase 5 additions ===
      etagPr,
      etagFiles,
      etagComments,
      // === Phase 5 additions ===
      etagChecks,
      // === end Phase 5 additions ===
      lastFetchAt: Date.now(),
    });
  }

  // === Phase 5 additions ===
  // Mirror the cached `checks` into detailState so the renderer can
  // read it without poking at the cache. Three other tabs read from
  // the cache via pushPanel's `data` lookup; for symmetry the Checks
  // tab does the same — but we also need detailState.checkRuns set so
  // that on a cache miss (first fetch ever) the tab still gets the
  // freshly-fetched data.
  detailState.checkRuns = checks;
  // === end Phase 5 additions ===

  pushPanel(ctx, currentPr);
}

/**
 * Top-level entry. Re-renders the panel; if a PR is set and we haven't
 * just fetched, kicks off a fetch.
 *
 * @param {{
 *   renderPanel: (panelId: string, tree: unknown) => void,
 *   log: (level: string, msg: string) => void,
 * }} ctx
 * @param {{
 *   currentPr: { owner: string, repo: string, number: number } | null,
 *   previousPr: { owner: string, repo: string, number: number } | null,
 *   github: any | null,
 * }} deps
 */
export async function renderDetailPanel(ctx, deps) {
  const { currentPr, previousPr, github } = deps;

  // PR change → reset state and stop the old poll.
  const prChanged = !sameRef(previousPr, currentPr);
  if (prChanged) {
    stopDetailPolling();
    resetDetailState();
  }

  if (currentPr === null) {
    pushPanel(ctx, null);
    return;
  }
  if (github === null) {
    // Auth not ready yet (Phase 1 path). Render empty placeholder; the
    // next activation will retry.
    pushPanel(ctx, currentPr);
    return;
  }

  // Initial render (with cache if any, spinner if not).
  pushPanel(ctx, currentPr);

  // Kick off the network fetch.
  await fetchAndRender(ctx, currentPr, github).catch((err) => {
    ctx.log("error", `prcomp: detail fetch crashed: ${String(err)}`);
  });

  // Start polling if not already.
  if (prChanged || detailTimer === null) {
    startDetailPolling(ctx, deps);
  }
}

/**
 * Identity check on `{owner, repo, number}` triples. Null-safe.
 */
function sameRef(a, b) {
  if (a === null && b === null) return true;
  if (a === null || b === null) return false;
  return a.owner === b.owner && a.repo === b.repo && a.number === b.number;
}

/**
 * Start the 30s polling interval. Idempotent: stops any existing timer
 * first.
 *
 * @param {{
 *   renderPanel: (panelId: string, tree: unknown) => void,
 *   log: (level: string, msg: string) => void,
 * }} ctx
 * @param {{
 *   currentPr: { owner: string, repo: string, number: number } | null,
 *   github: any | null,
 * }} deps
 */
export function startDetailPolling(ctx, deps) {
  stopDetailPolling();
  if (deps.currentPr === null || deps.github === null) return;
  detailTimer = setInterval(() => {
    const pr = deps.currentPr;
    const gh = deps.github;
    if (pr === null || gh === null) {
      stopDetailPolling();
      return;
    }
    fetchAndRender(ctx, pr, gh).catch((err) => {
      ctx.log("error", `prcomp: detail poll crashed: ${String(err)}`);
    });
  }, POLL_INTERVAL_MS);
  // Don't keep the event loop alive just for our poller — when the
  // host closes stdin the plugin should exit cleanly.
  if (typeof detailTimer.unref === "function") detailTimer.unref();
}

/**
 * Stop the polling interval if any.
 */
export function stopDetailPolling() {
  if (detailTimer !== null) {
    clearInterval(detailTimer);
    detailTimer = null;
  }
}

/**
 * Handle a `ui.event` whose panelId is the detail panel. Mutates the
 * module-level state and re-renders. Returns true if handled.
 *
 * @param {{
 *   renderPanel: (panelId: string, tree: unknown) => void,
 *   log: (level: string, msg: string) => void,
 * }} ctx
 * @param {{ panelId: string, nodeId: string, type: string, payload?: unknown }} event
 * @param {{
 *   currentPr: { owner: string, repo: string, number: number } | null,
 *   github: any | null,
 * }} deps
 */
export function handleDetailEvent(ctx, event, deps) {
  if (event.panelId !== DETAIL_PANEL) return false;

  // Tab switch.
  if (event.type === "detail-tab-changed") {
    const payload = /** @type {{ tabId?: unknown } | null | undefined} */ (event.payload);
    const tabId = payload !== null && payload !== undefined ? payload.tabId : undefined;
    if (tabId === "conversation" || tabId === "files" || tabId === "checks") {
      detailState.currentTab = tabId;
      // Re-render without re-fetching — cached data is fine for a tab
      // switch and the poll loop keeps it fresh.
      pushPanel(ctx, deps.currentPr);
    } else {
      ctx.log("warn", `prcomp: ignored detail-tab-changed with tabId=${String(tabId)}`);
    }
    return true;
  }

  // File row tap.
  if (typeof event.type === "string" && event.type.startsWith("detail-file-tapped:")) {
    const idxStr = event.type.slice("detail-file-tapped:".length);
    const idx = Number(idxStr);
    if (!Number.isInteger(idx) || idx < 0) {
      ctx.log("warn", `prcomp: bad file-tap index ${idxStr}`);
      return true;
    }
    const cached = deps.currentPr === null ? null : prDetailCache.get(cacheKey(deps.currentPr));
    const files = /** @type {Array<{ filename: string }> | undefined} */ (cached?.files);
    if (files === undefined || idx >= files.length) {
      ctx.log("warn", `prcomp: file-tap idx ${idx} out of range`);
      return true;
    }
    detailState.openFile = files[idx].filename;
    pushPanel(ctx, deps.currentPr);
    return true;
  }

  // Back-to-files button. The button itself emits `type: "tap"`; we
  // route on nodeId.
  if (event.nodeId === "prcomp-detail-file-back-btn" && event.type === "tap") {
    detailState.openFile = null;
    pushPanel(ctx, deps.currentPr);
    return true;
  }

  // === Phase 5 additions ===
  // Check-row tap. v0 just logs; opening a per-check log bottom
  // sheet needs github.js to fetch the run's log content (no such
  // method today). Swallowing the event keeps the host from
  // bubbling it as "unhandled".
  // TODO Phase 6: open ui.showBottomSheet with the last 200 lines of
  // the run's log (would need github.js#getCheckRunLog or similar) +
  // a "View full on GitHub" link to checkRun.htmlUrl.
  if (typeof event.type === "string" && event.type.startsWith("detail-check-tapped:")) {
    const idxStr = event.type.slice("detail-check-tapped:".length);
    ctx.log("debug", `prcomp: check-row tap idx=${idxStr} (log sheet pending Phase 6)`);
    return true;
  }
  // === end Phase 5 additions ===

  return false;
}

// === Phase 4 additions ===
// Cross-phase setters/getters for index.js's review-action dispatch.
// Kept here (rather than threaded through renderDetailPanel deps) so the
// dispatch can mutate panel state without having to know which slot of
// `detailState` is which — index.js calls setReviewError and trusts the
// next render to surface it.

/**
 * Set or clear the review/comment POST-error slot. Pass `null` to
 * dismiss the banner; pass `{ kind, action?, code? }` where `kind`
 * mirrors github.js's error union ("unauthed" | "offline" |
 * "rateLimited" | "serverError" | "unknown") and `action` is one of
 * "approve" | "request-changes" | "comment" | "reply" so the banner
 * can name the failing operation.
 *
 * @param {{ kind: string, action?: string, code?: number } | null} err
 */
export function setReviewError(err) {
  detailState.reviewError = err;
}

/**
 * Look up a single cached comment for the currently-open PR by id. Used
 * by index.js's reply-prefill path so the handler can quote the
 * original author/body without re-fetching. Returns `null` when the PR
 * isn't cached or the id isn't found.
 *
 * @param {{ owner: string, repo: string, number: number } | null} currentPr
 * @param {number} commentId
 * @returns {{ id: number, user: { login: string, avatarUrl: string }, body: string } | null}
 */
export function getDetailComment(currentPr, commentId) {
  if (currentPr === null) return null;
  const entry = prDetailCache.get(cacheKey(currentPr));
  if (entry === undefined) return null;
  const comments = /** @type {Array<{ id: number, user: { login: string, avatarUrl: string }, body: string }> | null} */ (entry.comments);
  if (comments === null || comments === undefined) return null;
  const found = comments.find((c) => c.id === commentId);
  return found ?? null;
}

/**
 * Banner factory for the review-error slot. Separate from `buildBanner`
 * (which classifies fetch errors) because the review-error context
 * names the failing action ("Approve failed", "Comment failed", …) and
 * uses slightly different copy.
 *
 * @param {{ kind: string, action?: string, code?: number } | null} err
 */
function buildReviewErrorBanner(err) {
  if (err === null) return null;
  const verb = (() => {
    switch (err.action) {
      case "approve":
        return "Approve";
      case "request-changes":
        return "Request changes";
      case "comment":
        return "Comment";
      case "reply":
        return "Reply";
      default:
        return "Review";
    }
  })();
  let body;
  switch (err.kind) {
    case "unauthed":
      body = "GitHub rejected the token. Re-auth via `gh auth login`.";
      break;
    case "offline":
      body = "Network unreachable. Retry when back online.";
      break;
    case "rateLimited":
      body = "Rate-limited by GitHub. Wait a few minutes and try again.";
      break;
    case "serverError":
      body =
        typeof err.code === "number"
          ? `GitHub returned HTTP ${err.code}.`
          : "GitHub returned an error.";
      break;
    default:
      body = "Unknown failure. Check the host log.";
      break;
  }
  return ui.banner({
    id: "prcomp-detail-review-error",
    title: `${verb} failed`,
    body,
    accent: "danger",
  });
}
// === end Phase 4 additions ===

// Exposed for tests / cross-phase introspection. Not part of the public
// plugin contract.
export const __testing = {
  getDetailState: () => detailState,
  resetDetailState,
  getCache: () => prDetailCache,
  buildDetailPanelTree,
  // Phase 4 — tests reach in to seed/inspect the review-error slot and
  // the reply-prefill cache lookup without going through index.js.
  setReviewError,
  getDetailComment,
};
