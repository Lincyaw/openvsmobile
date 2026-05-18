// PR Companion — Inbox renderer + event handler.
//
// Pure data-in / UiNode-out for `renderInboxPanel`; effectful for
// `handleInboxEvent` (mutates state via the dependency-injected
// callbacks, then asks for a re-render). Splitting the two means the
// render half is trivially unit-testable without standing up an
// SDK / fetch / fs harness.
//
// The auth-failure paths fall through to the SAME banner shapes that
// `index.js`'s Phase 1 `authBanner` helper produces (duplicated here
// to keep this module self-contained — the banners are short, and
// importing across phases would force this file to know about index.js
// internals it shouldn't need). The visual contract is "auth banner
// replaces the entire inbox content tree until the user has a usable
// token"; the column/section IDs are deliberately stable so the host's
// reconciler keeps focus / scroll state on the next re-render.

import { ui } from "@openvsmobile/sdk";

// Wire-event prefixes — the colon-suffix form lets the handler parse a
// row index (or scope value) off the end without a separate payload
// shape. Matches the convention the design doc spells out under "Tap a
// row → push PR detail panel".
const EVENT_TAB_CHANGED = "inbox-tab-changed";
// Buttons fire a hardcoded `{type:'tap', nodeId:<id>}` event — the
// SDK's `ui.button` has no `onTapEvent` field. We dispatch on node id.
const NODE_SCOPE_SWITCH_BTN = "prcomp-inbox-scope-switch-btn";
const EVENT_SCOPE_OPEN_SHEET = "inbox-scope-open-sheet";
const EVENT_SCOPE_PICKED_PREFIX = "inbox-scope-picked:";
const EVENT_PR_TAPPED_PREFIX = "inbox-pr-tapped:";
const EVENT_PR_DISMISSED_PREFIX = "inbox-pr-dismissed:";

const TAB_REVIEW = "review";
const TAB_MENTIONED = "mentioned";
const TAB_ASSIGNED = "assigned";

const INBOX_PANEL = "inbox";

/**
 * @typedef {Object} Notification
 * @property {string} id
 * @property {string} reason
 * @property {string} updatedAt
 * @property {{ fullName: string, owner: string, name: string }} repository
 * @property {{ title: string, url: string, type: string }} subject
 */

/**
 * Render the auth-failure / offline banner that takes over the inbox
 * tree when we don't have a usable token. Mirrors index.js's Phase-1
 * helper; kept local so this module doesn't reach back into index.js.
 *
 * @param {{ status: string } & Record<string, unknown>} auth
 */
function authBanner(auth) {
  if (auth.status === "missing") {
    return ui.section({
      id: "prcomp-inbox-auth-missing",
      children: [
        ui.banner({
          id: "prcomp-inbox-auth-missing-banner",
          title: "GitHub CLI not installed",
          body: "PR Companion uses the gh CLI to obtain a GitHub token. Install it on the host where the openvsmobile backend runs.",
          accent: "danger",
        }),
        ui.codeBlock({
          id: "prcomp-inbox-auth-missing-hint",
          code: [
            "# macOS",
            "brew install gh",
            "",
            "# Debian / Ubuntu",
            "sudo apt install gh",
            "",
            "# Arch",
            "sudo pacman -S github-cli",
          ].join("\n"),
          language: "sh",
        }),
      ],
    });
  }
  if (auth.status === "unauthed" || auth.status === "tokenInvalid") {
    const title =
      auth.status === "tokenInvalid"
        ? "GitHub rejected your token"
        : "GitHub CLI is not signed in";
    return ui.section({
      id: "prcomp-inbox-auth-unauthed",
      children: [
        ui.banner({
          id: "prcomp-inbox-auth-unauthed-banner",
          title,
          body: "Run gh auth login in the terminal to (re)authenticate. The plugin re-reads the token on every activation.",
          accent: "danger",
        }),
        ui.codeBlock({
          id: "prcomp-inbox-auth-unauthed-hint",
          code: "gh auth login",
          language: "sh",
        }),
      ],
    });
  }
  // "offline" or anything unrecognized — info-accent banner; the inbox
  // is unusable until the next activation re-runs the auth resolver.
  return ui.banner({
    id: "prcomp-inbox-auth-offline-banner",
    title: "GitHub unreachable",
    body: "Retrying on next activation.",
    accent: "info",
  });
}

/**
 * Format an ISO timestamp into a compact relative string ("just now",
 * "5m ago", "3h ago", "2d ago"). Anything older than ~30 days falls
 * back to the ISO date prefix to avoid the "47w ago" pattern the
 * design doc explicitly avoids.
 *
 * Exported for unit tests; not part of the public renderer surface.
 *
 * @param {string} iso
 * @param {number} [nowMs] — override for tests; defaults to Date.now()
 * @returns {string}
 */
export function formatRelative(iso, nowMs) {
  if (typeof iso !== "string" || iso.length === 0) return "";
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return "";
  const now = typeof nowMs === "number" ? nowMs : Date.now();
  const deltaMs = now - t;
  if (deltaMs < 0) return "just now";
  const sec = Math.floor(deltaMs / 1000);
  if (sec < 45) return "just now";
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  if (day < 30) return `${day}d ago`;
  // Older — use the date prefix; we never render "Nw ago" in the inbox.
  return iso.slice(0, 10);
}

/**
 * Map a notification `reason` (GitHub API value) to the human label we
 * show under the row + the badge text. Centralized so the same value
 * appears in both places without a render-site copy-paste.
 *
 * @param {string} reason
 * @returns {{ badge: string, secondary: string }}
 */
function reasonLabels(reason) {
  switch (reason) {
    case "review_requested":
      return { badge: "review", secondary: "review requested" };
    case "mention":
      return { badge: "mention", secondary: "you were mentioned" };
    case "assign":
      return { badge: "assigned", secondary: "assigned to you" };
    case "author":
      return { badge: "author", secondary: "your PR has activity" };
    case "comment":
      return { badge: "comment", secondary: "new comment" };
    case "subscribed":
      return { badge: "subscribed", secondary: "subscribed thread" };
    case "team_mention":
      return { badge: "team", secondary: "your team was mentioned" };
    default:
      // Unknown reason — show the raw value so the user can still tell
      // why this row showed up; we never silently drop information here.
      return { badge: reason || "update", secondary: reason || "update" };
  }
}

/**
 * Parse `subject.url` (e.g. `https://api.github.com/repos/o/r/pulls/42`)
 * into `{owner, repo, number}`. Notifications API doesn't expose the
 * PR number directly; we extract it from the subject URL so the tap
 * handler can navigate to the right detail panel.
 *
 * @param {string} url
 * @returns {{ owner: string, repo: string, number: number } | null}
 */
export function parsePullUrl(url) {
  if (typeof url !== "string" || url.length === 0) return null;
  const m = url.match(/\/repos\/([^/]+)\/([^/]+)\/pulls\/(\d+)/);
  if (m === null) return null;
  const number = Number(m[3]);
  if (!Number.isFinite(number) || number <= 0) return null;
  return { owner: m[1], repo: m[2], number };
}

/**
 * Apply scope + tab + dismissed filters in that order. Pure; exported
 * for unit tests so we can assert the filter pipeline without going
 * through the full render path.
 *
 * @param {Notification[]} notifications
 * @param {{ scope: "thisRepo" | "allRepos", repo: { owner: string, repo: string } | null, tab: string, dismissedIds: Set<string> }} opts
 * @returns {Notification[]}
 */
export function filterNotifications(notifications, opts) {
  const { scope, repo, tab, dismissedIds } = opts;
  let out = notifications;
  // Subject-type filter: we only render PRs. Issues and discussions
  // show up in the same Notifications API response but are out of
  // scope for the plugin.
  out = out.filter((n) => n.subject?.type === "PullRequest");
  if (scope === "thisRepo" && repo !== null) {
    const full = `${repo.owner}/${repo.repo}`;
    out = out.filter((n) => n.repository?.fullName === full);
  }
  // Tab filter — see design doc § "Inbox panel". `assigned` accepts
  // both `assign` and `author` so a user's own PRs with activity show
  // up under the same tab as PRs assigned to them (the GitHub web UI
  // groups these similarly).
  out = out.filter((n) => {
    switch (tab) {
      case TAB_REVIEW:
        return n.reason === "review_requested";
      case TAB_MENTIONED:
        return n.reason === "mention" || n.reason === "team_mention";
      case TAB_ASSIGNED:
        return n.reason === "assign" || n.reason === "author";
      default:
        return true;
    }
  });
  out = out.filter((n) => !dismissedIds.has(n.id));
  return out;
}

/**
 * Banner above the tab bar reflecting transient inbox-level state
 * (rate limit, offline, no-GH-workspace). Returns `null` when there is
 * nothing to surface; the caller drops the slot from the column.
 *
 * @param {{ error: { kind: string, [k: string]: unknown } | null, repo: { owner: string, repo: string } | null, workspaceLabel: string | null }} opts
 */
function inboxBanner({ error, repo, workspaceLabel }) {
  if (error !== null) {
    if (error.kind === "rateLimited") {
      const resetAt = /** @type {Date | undefined} */ (error.resetAt);
      const when =
        resetAt instanceof Date
          ? resetAt.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
          : "shortly";
      return ui.banner({
        id: "prcomp-inbox-banner-rate",
        title: "GitHub rate-limited",
        body: `Cached results shown; will retry around ${when}.`,
        accent: "warning",
      });
    }
    if (error.kind === "offline") {
      return ui.banner({
        id: "prcomp-inbox-banner-offline",
        title: "Offline",
        body: "Showing cached PRs. Next refresh will retry.",
        accent: "info",
      });
    }
    if (error.kind === "unauthed") {
      return ui.banner({
        id: "prcomp-inbox-banner-unauthed",
        title: "GitHub rejected your token",
        body: "Run gh auth login in the terminal and re-open the inbox.",
        accent: "danger",
      });
    }
    if (error.kind === "serverError") {
      const code = /** @type {number | undefined} */ (error.code);
      return ui.banner({
        id: "prcomp-inbox-banner-server",
        title: "GitHub returned an error",
        body: `HTTP ${code ?? "?"} — retrying on next refresh.`,
        accent: "warning",
      });
    }
  }
  if (repo === null) {
    const body =
      workspaceLabel !== null
        ? `Workspace "${workspaceLabel}" isn't a GitHub repo — showing all your PRs.`
        : "No workspace active — showing all your PRs.";
    return ui.banner({
      id: "prcomp-inbox-banner-noscope",
      title: "All-repos view",
      body,
      accent: "info",
    });
  }
  return null;
}

/**
 * Build the scope-chip row that sits above the tab bar.
 *
 * @param {{ scope: "thisRepo" | "allRepos", repo: { owner: string, repo: string } | null }} opts
 */
function scopeRow({ scope, repo }) {
  const label =
    scope === "thisRepo" && repo !== null
      ? `${repo.owner}/${repo.repo}`
      : "All repos";
  const children = [
    ui.badge({
      id: "prcomp-inbox-scope-badge",
      text: label,
      variant: "pill",
      accent: "muted",
    }),
  ];
  if (repo !== null) {
    // The switcher only makes sense when we actually have a "this repo"
    // option to offer. Without a GH repo on the current workspace the
    // toggle is forced to All-repos and there's nothing to switch to.
    children.push(
      ui.button({
        id: NODE_SCOPE_SWITCH_BTN,
        label: "Switch scope…",
        style: "secondary",
      }),
    );
  }
  return ui.row({
    id: "prcomp-inbox-scope-row",
    gap: "sm",
    children,
  });
}

/**
 * Build a single inbox row as a listTile. We use ListTile (rather than
 * a hand-rolled Row inside a List) because that's the only SDK shape
 * that carries `swipeActions`; multi-line richness is delivered via
 * `subtitle` (which the renderer is willing to wrap).
 *
 * The row index is baked into the per-row event ids; the handler maps
 * back to the notification by re-running the same filter pipeline.
 *
 * @param {{ notification: Notification, index: number }} opts
 */
function inboxRow({ notification, index }) {
  const url = notification.subject?.url ?? "";
  const ref = parsePullUrl(url);
  // We can still render the row when the URL doesn't parse — we just
  // can't navigate from it. Disabling the tap silently is friendlier
  // than dropping the row outright.
  const tappable = ref !== null;
  const repoFull = notification.repository?.fullName ?? "?";
  const labels = reasonLabels(notification.reason);
  const numberSuffix = ref !== null ? ` #${ref.number}` : "";
  const title = `${repoFull}${numberSuffix} — ${notification.subject?.title ?? ""}`.trim();
  const when = formatRelative(notification.updatedAt);
  // Compact two-piece subtitle keeps the row usable on a phone-width
  // screen; richer rendering (avatar in a row, badge + caption + date)
  // is where Phase 4+ can grow this if the cramped feel persists.
  const subtitle = `${labels.secondary}${when ? ` · ${when}` : ""}`;
  /** @type {Record<string, unknown>} */
  const tile = {
    id: `prcomp-inbox-row-${notification.id}`,
    title,
    subtitle,
    leading: ui.badge({
      id: `prcomp-inbox-row-${notification.id}-badge`,
      text: labels.badge,
      variant: "pill",
      accent: "muted",
    }),
    swipeActions: [
      {
        label: "Dismiss",
        eventId: `${EVENT_PR_DISMISSED_PREFIX}${index}`,
        accent: "danger",
      },
    ],
  };
  if (tappable) {
    tile.onTapEvent = `${EVENT_PR_TAPPED_PREFIX}${index}`;
  }
  return ui.listTile(/** @type {Parameters<typeof ui.listTile>[0]} */ (tile));
}

/**
 * Pure renderer: state in → widget tree out.
 *
 * `notifications` MUST already include only the rows we'd want to
 * render before scope/tab filters — the renderer applies those itself
 * so the handler can resolve `inbox-pr-tapped:{idx}` against the same
 * filtered list the user sees.
 *
 * @param {unknown} _ctx — accepted for parity with the rest of the
 *   renderer surface; not used here so the function stays pure.
 * @param {{
 *   auth: { status: string } & Record<string, unknown>,
 *   workspace: { id: string, label: string } | null,
 *   repo: { owner: string, repo: string } | null,
 *   scope: "thisRepo" | "allRepos",
 *   tab: string,
 *   notifications: Notification[],
 *   dismissedIds: Set<string>,
 *   error: { kind: string, [k: string]: unknown } | null,
 *   lastRefreshIso: string | null,
 * }} opts
 */
export function renderInboxPanel(_ctx, opts) {
  const { auth } = opts;
  if (auth === null || auth.status !== "ok") {
    return ui.column({
      id: "prcomp-inbox-root",
      gap: "md",
      children: [
        authBanner(auth ?? { status: "offline" }),
      ],
    });
  }

  const visible = filterNotifications(opts.notifications, {
    scope: opts.scope,
    repo: opts.repo,
    tab: opts.tab,
    dismissedIds: opts.dismissedIds,
  });

  /** @type {ReturnType<typeof ui.column>["children"]} */
  const children = [];

  children.push(scopeRow({ scope: opts.scope, repo: opts.repo }));

  children.push(
    ui.tabBar({
      id: "prcomp-inbox-tabs",
      activeId: opts.tab,
      onChangeEvent: EVENT_TAB_CHANGED,
      tabs: [
        { id: TAB_REVIEW, label: "Review" },
        { id: TAB_MENTIONED, label: "Mentioned" },
        { id: TAB_ASSIGNED, label: "Assigned" },
      ],
    }),
  );

  const banner = inboxBanner({
    error: opts.error,
    repo: opts.repo,
    workspaceLabel: opts.workspace?.label ?? null,
  });
  if (banner !== null) children.push(banner);

  if (visible.length === 0) {
    const captionParts = ["No PRs need your attention."];
    if (opts.lastRefreshIso !== null) {
      captionParts.push(`Last refreshed ${formatRelative(opts.lastRefreshIso)}.`);
    }
    children.push(
      ui.section({
        id: "prcomp-inbox-empty",
        children: [
          ui.text({
            id: "prcomp-inbox-empty-caption",
            text: captionParts.join(" "),
            style: "caption",
          }),
        ],
      }),
    );
  } else {
    children.push(
      ui.list({
        id: "prcomp-inbox-list",
        items: visible.map((n, idx) => inboxRow({ notification: n, index: idx })),
      }),
    );
  }

  return ui.column({
    id: "prcomp-inbox-root",
    gap: "md",
    children,
  });
}

/**
 * Event router for inbox-owned UI events.
 *
 * `deps` carries the side-effect channels (state getters/setters,
 * persistence, polling, detail-panel navigation, the GitHub client)
 * so the renderer module never reaches into index.js's module-scoped
 * state directly. This is what makes inbox.js self-contained enough
 * to unit-test.
 *
 * Unrecognized events return without error — the caller will already
 * have logged the unhandled-event warning from index.js's top-level
 * `onUiEvent`.
 *
 * @param {{ log: (level: string, msg: string) => void, showActionSheet: (panelId: string, sheet: import("@openvsmobile/sdk").UiActionSheet) => Promise<unknown> }} ctx
 * @param {{ type: string, payload?: unknown, panelId: string, nodeId: string }} event
 * @param {{
 *   getInbox: () => { activeTab: string, notifications: Notification[], error: { kind: string, [k: string]: unknown } | null, etag: string | null, lastModified: string | null, lastRefreshIso: string | null },
 *   setActiveTab: (tabId: string) => void,
 *   getScope: () => "thisRepo" | "allRepos",
 *   setScope: (scope: "thisRepo" | "allRepos") => Promise<void>,
 *   getRepo: () => { owner: string, repo: string } | null,
 *   getWorkspace: () => { id: string, label: string } | null,
 *   getAuth: () => { status: string } & Record<string, unknown>,
 *   getDismissedIds: () => Set<string>,
 *   addDismissedId: (id: string) => Promise<void>,
 *   openPrDetail: (ref: { owner: string, repo: string, number: number }) => void,
 *   pollInbox: () => Promise<boolean>,
 *   rerender: () => void,
 * }} deps
 */
export async function handleInboxEvent(ctx, event, deps) {
  if (event.type === EVENT_TAB_CHANGED) {
    const payload = /** @type {{ tabId?: unknown } | undefined} */ (event.payload);
    const tabId =
      typeof payload?.tabId === "string" ? payload.tabId : TAB_REVIEW;
    deps.setActiveTab(tabId);
    deps.rerender();
    return;
  }

  // Scope-switch button: button widgets fire `{type:'tap', nodeId}`.
  // We accept either the dispatch via node id (real button path) OR the
  // synthetic EVENT_SCOPE_OPEN_SHEET for direct test injection.
  if (
    (event.type === "tap" && event.nodeId === NODE_SCOPE_SWITCH_BTN) ||
    event.type === EVENT_SCOPE_OPEN_SHEET
  ) {
    const repo = deps.getRepo();
    /** @type {import("@openvsmobile/sdk").UiActionSheetAction[]} */
    const actions = [];
    if (repo !== null) {
      actions.push({
        label: `Just this repo (${repo.owner}/${repo.repo})`,
        eventId: `${EVENT_SCOPE_PICKED_PREFIX}thisRepo`,
      });
    }
    actions.push({
      label: "All repos",
      eventId: `${EVENT_SCOPE_PICKED_PREFIX}allRepos`,
    });
    await ctx.showActionSheet(INBOX_PANEL, {
      id: "prcomp-inbox-scope-sheet",
      title: "PR inbox scope",
      actions,
    });
    return;
  }

  if (event.type.startsWith(EVENT_SCOPE_PICKED_PREFIX)) {
    const value = event.type.slice(EVENT_SCOPE_PICKED_PREFIX.length);
    if (value !== "thisRepo" && value !== "allRepos") {
      ctx.log("warn", `prcomp: ignoring unknown scope value "${value}"`);
      return;
    }
    await deps.setScope(value);
    deps.rerender();
    // Trigger a refetch — the visible set is shrinking or growing, so
    // the user sees instant feedback even though the underlying data
    // is the same notifications list (the fetch is essentially free
    // thanks to ETag → 304). Re-render only if pollInbox surfaced new
    // data or a banner transition; 304 with no error change is silent.
    const changed = await deps.pollInbox();
    if (changed) deps.rerender();
    return;
  }

  if (event.type.startsWith(EVENT_PR_TAPPED_PREFIX)) {
    const idx = Number(event.type.slice(EVENT_PR_TAPPED_PREFIX.length));
    const inbox = deps.getInbox();
    const filtered = filterNotifications(inbox.notifications, {
      scope: deps.getScope(),
      repo: deps.getRepo(),
      tab: inbox.activeTab,
      dismissedIds: deps.getDismissedIds(),
    });
    const notification = filtered[idx];
    if (notification === undefined) {
      ctx.log("warn", `prcomp: tapped row index ${idx} out of bounds`);
      return;
    }
    const ref = parsePullUrl(notification.subject?.url ?? "");
    if (ref === null) {
      ctx.log(
        "warn",
        `prcomp: notification ${notification.id} has no parsable PR URL`,
      );
      return;
    }
    deps.openPrDetail(ref);
    return;
  }

  if (event.type.startsWith(EVENT_PR_DISMISSED_PREFIX)) {
    const idx = Number(event.type.slice(EVENT_PR_DISMISSED_PREFIX.length));
    const inbox = deps.getInbox();
    const filtered = filterNotifications(inbox.notifications, {
      scope: deps.getScope(),
      repo: deps.getRepo(),
      tab: inbox.activeTab,
      dismissedIds: deps.getDismissedIds(),
    });
    const notification = filtered[idx];
    if (notification === undefined) {
      ctx.log("warn", `prcomp: dismiss row index ${idx} out of bounds`);
      return;
    }
    await deps.addDismissedId(notification.id);
    // TODO Phase 5: when the SDK gains a time-limited toast-with-undo
    // affordance, surface an "Undo" toast here so a mis-swipe is
    // recoverable. `ctx.showAlert` would block the user behind a modal
    // for a destructive-but-not-irreversible action, which is worse
    // than leaving the row hidden until the next GitHub `updated_at`
    // bump re-surfaces it.
    deps.rerender();
    return;
  }

  ctx.log(
    "warn",
    `prcomp: inbox handler received unrecognized event type "${event.type}"`,
  );
}

// Re-exported event-name constants for callers that want to switch on
// the prefix without re-declaring it.
export const inboxEvents = {
  TAB_CHANGED: EVENT_TAB_CHANGED,
  SCOPE_OPEN_SHEET: EVENT_SCOPE_OPEN_SHEET,
  SCOPE_PICKED_PREFIX: EVENT_SCOPE_PICKED_PREFIX,
  PR_TAPPED_PREFIX: EVENT_PR_TAPPED_PREFIX,
  PR_DISMISSED_PREFIX: EVENT_PR_DISMISSED_PREFIX,
};
