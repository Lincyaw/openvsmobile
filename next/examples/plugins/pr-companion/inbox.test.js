// Unit tests for render/inbox.js — covers the pure renderer + the
// filter pipeline + the relative-time helper + the row-event handler
// dispatch. Picks up via the `../examples/plugins/*/*.test.js` glob in
// next/backend/vitest.config.ts.
//
// We don't exercise the actual GitHub HTTP path here (that's
// github.test.js). The handler tests stub the dep object inline so a
// single test can assert "scope-pick fires setScope then pollInbox
// then rerender" without standing up a plugin host.

import { describe, expect, it, vi } from "vitest";

// The renderer module imports `@openvsmobile/sdk` to get the `ui.*`
// constructors. The SDK is wired into plugin processes via the host's
// custom loader (next/backend/packages/sdk/runtime/sdk-loader.mjs), so
// it is not resolvable through plain Node ESM lookup from this file's
// location. We stub the small subset the renderer needs — every
// constructor passes its params through verbatim with a `kind` tag, so
// assertions on the returned tree shape continue to work.
vi.mock("@openvsmobile/sdk", () => {
  /**
   * @param {string} kind
   * @returns {(p?: object) => Record<string, unknown>}
   */
  const make = (kind) => (p = {}) => ({ kind, ...p });
  return {
    ui: {
      column: make("Column"),
      row: make("Row"),
      section: make("Section"),
      list: make("List"),
      listTile: make("ListTile"),
      text: make("Text"),
      button: make("Button"),
      badge: make("Badge"),
      banner: make("Banner"),
      tabBar: make("TabBar"),
      codeBlock: make("CodeBlock"),
      // Anything the renderer doesn't currently use stays unstubbed —
      // a typo there would surface as a runtime error in the test, which
      // is exactly the signal we want.
    },
  };
});

const {
  filterNotifications,
  formatRelative,
  handleInboxEvent,
  inboxEvents,
  parsePullUrl,
  renderInboxPanel,
} = await import("./render/inbox.js");

/** Build a minimal Notification fixture with all required shape. */
function note(overrides = {}) {
  return {
    id: "n1",
    reason: "review_requested",
    updatedAt: "2026-05-18T08:00:00Z",
    repository: { fullName: "octo/repo", owner: "octo", name: "repo" },
    subject: {
      title: "Fix the thing",
      url: "https://api.github.com/repos/octo/repo/pulls/42",
      type: "PullRequest",
    },
    ...overrides,
  };
}

/** Tiny faux PluginContext — only the fields the handler reads. */
function fakeCtx() {
  return {
    log: vi.fn(),
    showActionSheet: vi.fn(async () => ({ delivered: true })),
  };
}

describe("formatRelative", () => {
  const NOW = Date.parse("2026-05-18T12:00:00Z");

  it("renders ages with the smallest sensible unit", () => {
    expect(formatRelative("2026-05-18T11:59:30Z", NOW)).toBe("just now");
    expect(formatRelative("2026-05-18T11:55:00Z", NOW)).toBe("5m ago");
    expect(formatRelative("2026-05-18T10:00:00Z", NOW)).toBe("2h ago");
    expect(formatRelative("2026-05-16T12:00:00Z", NOW)).toBe("2d ago");
  });

  it("falls back to the ISO date prefix beyond 30 days", () => {
    expect(formatRelative("2026-03-01T00:00:00Z", NOW)).toBe("2026-03-01");
  });

  it("returns empty string on garbage input", () => {
    expect(formatRelative("", NOW)).toBe("");
    expect(formatRelative("not-a-date", NOW)).toBe("");
  });

  it("handles future timestamps as 'just now'", () => {
    expect(formatRelative("2027-01-01T00:00:00Z", NOW)).toBe("just now");
  });
});

describe("parsePullUrl", () => {
  it("extracts owner/repo/number from the standard subject URL", () => {
    expect(parsePullUrl("https://api.github.com/repos/o/r/pulls/42")).toEqual({
      owner: "o",
      repo: "r",
      number: 42,
    });
  });

  it("returns null on non-PR URLs", () => {
    expect(parsePullUrl("https://api.github.com/repos/o/r/issues/42")).toBeNull();
    expect(parsePullUrl("")).toBeNull();
    expect(parsePullUrl(null)).toBeNull();
  });
});

describe("filterNotifications", () => {
  const ns = [
    note({ id: "1", reason: "review_requested" }),
    note({
      id: "2",
      reason: "mention",
      repository: { fullName: "other/repo", owner: "other", name: "repo" },
    }),
    note({ id: "3", reason: "assign" }),
    note({ id: "4", reason: "author" }),
    note({
      id: "5",
      reason: "review_requested",
      subject: { title: "An issue", url: "x", type: "Issue" },
    }),
  ];

  it("drops non-PR subjects regardless of tab", () => {
    const out = filterNotifications(ns, {
      scope: "allRepos",
      repo: null,
      tab: "review",
      dismissedIds: new Set(),
    });
    expect(out.map((n) => n.id)).toEqual(["1"]);
  });

  it("scope=thisRepo keeps only the active repo", () => {
    const out = filterNotifications(ns, {
      scope: "thisRepo",
      repo: { owner: "octo", repo: "repo" },
      tab: "review",
      dismissedIds: new Set(),
    });
    expect(out.map((n) => n.id)).toEqual(["1"]);
  });

  it("scope=thisRepo with no repo falls through to allRepos", () => {
    const out = filterNotifications(ns, {
      scope: "thisRepo",
      repo: null,
      tab: "mentioned",
      dismissedIds: new Set(),
    });
    expect(out.map((n) => n.id)).toEqual(["2"]);
  });

  it("assigned tab covers both 'assign' and 'author' reasons", () => {
    const out = filterNotifications(ns, {
      scope: "allRepos",
      repo: null,
      tab: "assigned",
      dismissedIds: new Set(),
    });
    expect(out.map((n) => n.id).sort()).toEqual(["3", "4"]);
  });

  it("dismissed ids are filtered after scope + tab", () => {
    const out = filterNotifications(ns, {
      scope: "allRepos",
      repo: null,
      tab: "review",
      dismissedIds: new Set(["1"]),
    });
    expect(out).toEqual([]);
  });
});

describe("renderInboxPanel", () => {
  function baseOpts(overrides = {}) {
    return {
      auth: { status: "ok", token: "x", user: { login: "alice" } },
      workspace: { id: "ws1", label: "demo" },
      repo: { owner: "octo", repo: "repo" },
      scope: /** @type {"thisRepo" | "allRepos"} */ ("thisRepo"),
      tab: "review",
      notifications: [note()],
      dismissedIds: new Set(),
      error: null,
      lastRefreshIso: null,
      ...overrides,
    };
  }

  it("short-circuits to the auth banner when auth.status !== 'ok'", () => {
    const tree = renderInboxPanel(null, baseOpts({ auth: { status: "missing" } }));
    expect(tree.kind).toBe("Column");
    // Auth-missing branch renders a Section wrapping the banner + hint.
    const child = tree.children[0];
    expect(child.kind).toBe("Section");
  });

  it("renders the full tree with scope chip, tabs, and list", () => {
    const tree = renderInboxPanel(null, baseOpts());
    expect(tree.kind).toBe("Column");
    const kinds = tree.children.map((c) => c.kind);
    expect(kinds).toContain("Row"); // scope chip row
    expect(kinds).toContain("TabBar");
    expect(kinds).toContain("List");
  });

  it("hides the 'Switch scope…' button when there is no GH repo", () => {
    const tree = renderInboxPanel(
      null,
      baseOpts({ repo: null, scope: "allRepos" }),
    );
    const scopeRow = tree.children.find((c) => c.kind === "Row");
    expect(scopeRow).toBeDefined();
    const buttons = scopeRow.children.filter((c) => c.kind === "Button");
    expect(buttons).toHaveLength(0);
  });

  it("surfaces a banner when the workspace has no GitHub remote", () => {
    const tree = renderInboxPanel(
      null,
      baseOpts({
        repo: null,
        scope: "allRepos",
        workspace: { id: "ws1", label: "internal" },
      }),
    );
    const banner = tree.children.find((c) => c.kind === "Banner");
    expect(banner).toBeDefined();
    expect(banner.title).toBe("All-repos view");
    expect(banner.body).toContain("internal");
  });

  it("renders the empty-state caption when filters yield no rows", () => {
    const tree = renderInboxPanel(
      null,
      baseOpts({
        notifications: [
          note({ id: "x", reason: "mention" }), // not in 'review' tab
        ],
      }),
    );
    const section = tree.children.find(
      (c) => c.kind === "Section" && c.id === "prcomp-inbox-empty",
    );
    expect(section).toBeDefined();
  });

  it("rate-limited error renders the warning banner", () => {
    const tree = renderInboxPanel(
      null,
      baseOpts({
        error: {
          kind: "rateLimited",
          resetAt: new Date("2026-05-18T13:00:00Z"),
        },
      }),
    );
    const banner = tree.children.find((c) => c.kind === "Banner");
    expect(banner).toBeDefined();
    expect(banner.accent).toBe("warning");
  });
});

describe("handleInboxEvent", () => {
  function makeDeps(overrides = {}) {
    const deps = {
      getInbox: () => ({
        activeTab: "review",
        notifications: [note()],
        error: null,
        etag: null,
        lastModified: null,
        lastRefreshIso: null,
      }),
      setActiveTab: vi.fn(),
      getScope: () => "thisRepo",
      setScope: vi.fn(async () => undefined),
      getRepo: () => ({ owner: "octo", repo: "repo" }),
      getWorkspace: () => ({ id: "ws1", label: "demo" }),
      getAuth: () => ({ status: "ok" }),
      getDismissedIds: () => new Set(),
      addDismissedId: vi.fn(async () => undefined),
      openPrDetail: vi.fn(),
      pollInbox: vi.fn(async () => undefined),
      rerender: vi.fn(),
      ...overrides,
    };
    return deps;
  }

  it("tab-changed routes through setActiveTab and rerender", async () => {
    const ctx = fakeCtx();
    const deps = makeDeps();
    await handleInboxEvent(
      ctx,
      {
        panelId: "inbox",
        nodeId: "prcomp-inbox-tabs",
        type: inboxEvents.TAB_CHANGED,
        payload: { tabId: "assigned" },
      },
      deps,
    );
    expect(deps.setActiveTab).toHaveBeenCalledWith("assigned");
    expect(deps.rerender).toHaveBeenCalledTimes(1);
  });

  it("scope-open-sheet calls showActionSheet with both options when a repo exists", async () => {
    const ctx = fakeCtx();
    const deps = makeDeps();
    await handleInboxEvent(
      ctx,
      {
        panelId: "inbox",
        nodeId: "prcomp-inbox-scope-switch-btn",
        type: inboxEvents.SCOPE_OPEN_SHEET,
      },
      deps,
    );
    expect(ctx.showActionSheet).toHaveBeenCalledTimes(1);
    const sheet = ctx.showActionSheet.mock.calls[0][1];
    expect(sheet.actions).toHaveLength(2);
    expect(sheet.actions[0].label).toContain("Just this repo");
  });

  it("scope-switch button tap (real UI path) reaches showActionSheet", async () => {
    // Buttons fire {type:'tap', nodeId} — the handler must route on
    // the node id, not on a synthetic 'inbox-scope-open-sheet' string.
    const ctx = fakeCtx();
    const deps = makeDeps();
    await handleInboxEvent(
      ctx,
      {
        panelId: "inbox",
        nodeId: "prcomp-inbox-scope-switch-btn",
        type: "tap",
      },
      deps,
    );
    expect(ctx.showActionSheet).toHaveBeenCalledTimes(1);
  });

  it("scope-open-sheet hides 'Just this repo' when repo is null", async () => {
    const ctx = fakeCtx();
    const deps = makeDeps({ getRepo: () => null });
    await handleInboxEvent(
      ctx,
      {
        panelId: "inbox",
        nodeId: "prcomp-inbox-scope-switch-btn",
        type: inboxEvents.SCOPE_OPEN_SHEET,
      },
      deps,
    );
    const sheet = ctx.showActionSheet.mock.calls[0][1];
    expect(sheet.actions).toHaveLength(1);
    expect(sheet.actions[0].label).toBe("All repos");
  });

  it("scope-picked persists, re-renders, and polls", async () => {
    const ctx = fakeCtx();
    const deps = makeDeps();
    await handleInboxEvent(
      ctx,
      {
        panelId: "inbox",
        nodeId: "n/a",
        type: `${inboxEvents.SCOPE_PICKED_PREFIX}allRepos`,
      },
      deps,
    );
    expect(deps.setScope).toHaveBeenCalledWith("allRepos");
    expect(deps.rerender).toHaveBeenCalledTimes(1);
    expect(deps.pollInbox).toHaveBeenCalledTimes(1);
  });

  it("pr-tapped at index 0 resolves to openPrDetail with the parsed ref", async () => {
    const ctx = fakeCtx();
    const deps = makeDeps();
    await handleInboxEvent(
      ctx,
      {
        panelId: "inbox",
        nodeId: "n/a",
        type: `${inboxEvents.PR_TAPPED_PREFIX}0`,
      },
      deps,
    );
    expect(deps.openPrDetail).toHaveBeenCalledWith({
      owner: "octo",
      repo: "repo",
      number: 42,
    });
  });

  it("pr-dismissed adds the id and re-renders", async () => {
    const ctx = fakeCtx();
    const deps = makeDeps();
    await handleInboxEvent(
      ctx,
      {
        panelId: "inbox",
        nodeId: "n/a",
        type: `${inboxEvents.PR_DISMISSED_PREFIX}0`,
      },
      deps,
    );
    expect(deps.addDismissedId).toHaveBeenCalledWith("n1");
    expect(deps.rerender).toHaveBeenCalledTimes(1);
  });

  it("out-of-bounds row index logs a warning and short-circuits", async () => {
    const ctx = fakeCtx();
    const deps = makeDeps();
    await handleInboxEvent(
      ctx,
      {
        panelId: "inbox",
        nodeId: "n/a",
        type: `${inboxEvents.PR_TAPPED_PREFIX}99`,
      },
      deps,
    );
    expect(ctx.log).toHaveBeenCalled();
    expect(deps.openPrDetail).not.toHaveBeenCalled();
  });

  it("unknown event type logs a warning", async () => {
    const ctx = fakeCtx();
    const deps = makeDeps();
    await handleInboxEvent(
      ctx,
      { panelId: "inbox", nodeId: "n/a", type: "nope" },
      deps,
    );
    expect(ctx.log).toHaveBeenCalled();
  });
});
