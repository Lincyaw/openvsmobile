// PR Companion — Phase 2 (Inbox).
//
// Phase 1 (skeleton + auth + workspace detection) and Phase 2 (this
// slice — GitHub Notifications fetch with ETag, three-tab filter, scope
// chip + switcher, swipe-to-dismiss with persistence) coexist in this
// file. Phase 3 (PR detail) is implemented in `render/prDetail.js` by a
// parallel worker; the partition between phases here uses explicit
// section markers so the merge is mechanical.
//
// What this file owns:
//   * Module-level state for inbox + cross-phase navigation target.
//   * `onActivate` / `onWorkspaceActivated` / `onUiEvent` wiring.
//   * The `pollInbox` ETag-polling loop (60s foreground cadence).
//   * Dispatching inbox UI events through `handleInboxEvent`.
//
// What this file does NOT own:
//   * Inbox widget-tree construction or filter logic — see
//     `render/inbox.js`.
//   * PR-detail rendering — see `render/prDetail.js` (Phase 3 module;
//     exists after Phase 3 merges).
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

const execFileAsync = promisify(execFile);

const INBOX_PANEL = "inbox";
const DETAIL_PANEL = "detail";
const USER_AGENT = "openvsmobile-pr-companion/0.1";

const GIT_TIMEOUT_MS = 5000;
const INBOX_POLL_INTERVAL_MS = 60_000;

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

// Latest ctx captured at the top of every lifecycle hook — used by
// off-cycle save / log paths (e.g. saveState invocations triggered
// from a setInterval tick).
let currentCtx = /** @type {import("@openvsmobile/sdk").PluginContext | null} */ (
  null
);

// ─────────────────────────────────────────────────────────────
// === Cross-phase: shared state ===
// ─────────────────────────────────────────────────────────────
// Read by Phase 2's row-tap handler, read+written by Phase 3's detail
// renderer. Lives OUTSIDE the per-phase blocks so the Phase 3 merge can
// reference it without shuffling code.

/** @type {{ owner: string, repo: string, number: number } | null} */
let currentDetailPr = null;

// ─────────────────────────────────────────────────────────────
// === Phase 2 (Inbox) state ===
// ─────────────────────────────────────────────────────────────

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

let githubClient = /** @type {ReturnType<typeof createGithubClient> | null} */ (
  null
);
/** @type {NodeJS.Timeout | null} */
let inboxTimer = null;

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
 * Caller is expected to `render(ctx)` after — pollInbox does not
 * re-render so the dispatcher gets to batch consecutive state changes
 * (scope-pick → poll → render, rather than scope-pick → render →
 * poll → render).
 *
 * Tolerates a null client (auth.status !== "ok"): no-op so the panel
 * keeps showing the auth banner.
 *
 * @param {{ log: (level: string, msg: string) => void }} ctx
 */
async function pollInbox(ctx) {
  if (githubClient === null) return;
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
    return;
  }
  if (result.status === "notModified") {
    // 304 keeps the existing list; refresh the validators in case the
    // server rotated them, and clear any transient error banner.
    inboxState.etag = result.etag ?? inboxState.etag;
    inboxState.error = null;
    inboxState.lastRefreshIso = new Date().toISOString();
    return;
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
}

// ─────────────────────────────────────────────────────────────
// === Phase 3 (Detail) state ===
// ─────────────────────────────────────────────────────────────
// (Phase 3 owns this section; Phase 2 leaves it absent.)

function buildDetailTree() {
  // Phase-2-only placeholder. Phase 3 replaces this builder with the
  // real conversation/files/checks tree driven by `currentDetailPr`.
  // Until then we paint a friendly note so the panel slot isn't
  // visually empty.
  const text =
    currentDetailPr === null
      ? "Open a PR from the Inbox tab. (Phase 3)"
      : `Selected PR: ${currentDetailPr.owner}/${currentDetailPr.repo} #${currentDetailPr.number}. Detail UI lands in Phase 3.`;
  return ui.section({
    id: "prcomp-detail-section",
    title: "PR Detail",
    children: [
      ui.text({ id: "prcomp-detail-placeholder", text }),
    ],
  });
}

/**
 * Cross-phase entry point: Phase 2's row-tap handler invokes this
 * after setting `currentDetailPr`. Phase 3 reshapes the body inside
 * `buildDetailTree`; the call site here stays unchanged.
 *
 * @param {import("@openvsmobile/sdk").PluginContext} ctx
 */
function renderDetailPanel(ctx) {
  ctx.renderPanel(DETAIL_PANEL, buildDetailTree());
}

function render(ctx) {
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
  renderDetailPanel(ctx);
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

    // === Phase 2: persisted-state load + client instantiation ===
    persistedState = await loadState(ctx);
    dismissedSet = new Set(persistedState.dismissedIds);
    if (currentAuth !== null && currentAuth.status === "ok") {
      githubClient = createGithubClient({
        token: currentAuth.token,
        userAgent: USER_AGENT,
      });
      // First poll runs concurrently with the initial paint — the
      // paint reflects the empty list + the "no PRs" empty state, then
      // the next render after the fetch fills it in. Acceptable
      // because the empty state is brief and the alternative (await
      // pollInbox before first paint) holds the user behind a blank
      // panel for the full HTTP round trip.
      pollInbox(ctx)
        .then(() => render(ctx))
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
          .then(() => render(ctx))
          .catch((err) => {
            ctx.log(
              "error",
              `prcomp: inbox poll threw: ${err?.message ?? String(err)}`,
            );
          });
      }, INBOX_POLL_INTERVAL_MS);
      inboxTimer.unref?.();
    }

    render(ctx);
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
    render(ctx);
    // Workspace switch = scope change in most cases. Kick a poll so
    // the user sees instant feedback for the new scope; the ETag
    // means the call is essentially free on the wire even when the
    // notification list is unchanged.
    if (githubClient !== null) {
      pollInbox(ctx)
        .then(() => render(ctx))
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
          renderDetailPanel(ctx);
        },
        pollInbox: () => pollInbox(ctx),
        rerender: () => render(ctx),
      });
      return;
    }
    // === Phase 3: Detail events ===
    // (Phase 3 inserts its branch here.)
    ctx.log(
      "warn",
      `prcomp: unhandled event ${event.panelId}/${event.type}`,
    );
  },
});

plugin.run();
