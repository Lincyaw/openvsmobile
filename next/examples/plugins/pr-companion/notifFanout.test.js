// Unit tests for render/notifFanout.js — pure helper. The helper itself
// has no SDK dependency, but it imports `parsePullUrl` from
// render/inbox.js which DOES import `@openvsmobile/sdk` for its `ui.*`
// constructors. The SDK is wired into plugin processes via the host's
// custom loader (next/backend/packages/sdk/runtime/sdk-loader.mjs), so
// it's not resolvable through plain Node ESM lookup from this file's
// location. We stub it the same way inbox.test.js does.

import { describe, expect, it, vi } from "vitest";

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
    },
  };
});

const { computeNotifFanout, FANOUT_GROUP_KEY, FANOUT_TTL_SECONDS } =
  await import("./render/notifFanout.js");

/**
 * Build a Notification shape matching the fields consumed by the
 * fanout helper. Defaults are a valid review-requested PR; per-test
 * overrides land via the partial param.
 */
function mkNotif(partial = {}) {
  return {
    id: "1",
    reason: "review_requested",
    repository: { owner: "octocat", name: "Hello-World", fullName: "octocat/Hello-World" },
    subject: {
      title: "Update README",
      url: "https://api.github.com/repos/octocat/Hello-World/pulls/42",
      type: "PullRequest",
    },
    ...partial,
  };
}

describe("computeNotifFanout — cold start", () => {
  it("pre-populates ids without firing toasts when shownSet is empty", () => {
    const notifs = [
      mkNotif({ id: "a" }),
      mkNotif({ id: "b" }),
      mkNotif({ id: "c" }),
    ];
    const out = computeNotifFanout({
      notifications: notifs,
      dismissedSet: new Set(),
      shownSet: new Set(),
    });
    expect(out.coldStart).toBe(true);
    expect(out.toasts).toEqual([]);
    expect(out.idsToMark).toEqual(["a", "b", "c"]);
  });

  it("still skips dismissed ids on cold start", () => {
    const out = computeNotifFanout({
      notifications: [mkNotif({ id: "a" }), mkNotif({ id: "b" })],
      dismissedSet: new Set(["a"]),
      shownSet: new Set(),
    });
    expect(out.toasts).toEqual([]);
    expect(out.idsToMark).toEqual(["b"]);
  });
});

describe("computeNotifFanout — steady state", () => {
  it("fires a toast only for ids not in shownSet or dismissedSet", () => {
    const out = computeNotifFanout({
      notifications: [
        mkNotif({ id: "a" }), // already shown — skip
        mkNotif({ id: "b" }), // dismissed — skip
        mkNotif({ id: "c" }), // genuinely new — fire
      ],
      dismissedSet: new Set(["b"]),
      shownSet: new Set(["a"]),
    });
    expect(out.coldStart).toBe(false);
    expect(out.toasts).toHaveLength(1);
    expect(out.toasts[0].notifId).toBe("c");
    expect(out.idsToMark).toEqual(["c"]);
  });

  it("uses the per-reason title mapping", () => {
    const reasons = [
      { reason: "review_requested", title: "Review requested" },
      { reason: "mention", title: "You were mentioned" },
      { reason: "team_mention", title: "You were mentioned" },
      { reason: "assign", title: "PR assigned to you" },
      { reason: "comment", title: "PR activity" },
      { reason: "subscribed", title: "PR activity" },
    ];
    for (const { reason, title } of reasons) {
      const out = computeNotifFanout({
        notifications: [mkNotif({ id: `n-${reason}`, reason })],
        dismissedSet: new Set(),
        // Non-empty shownSet → not cold start. The exact id doesn't
        // matter; just needs at least one entry distinct from `n-*`.
        shownSet: new Set(["seed"]),
      });
      expect(out.toasts[0]?.input.title, `reason=${reason}`).toBe(title);
    }
  });

  it("renders body as owner/repo #N — title", () => {
    const out = computeNotifFanout({
      notifications: [
        mkNotif({
          id: "a",
          subject: {
            title: "Fix flaky test",
            url: "https://api.github.com/repos/foo/bar/pulls/99",
            type: "PullRequest",
          },
        }),
      ],
      dismissedSet: new Set(),
      shownSet: new Set(["seed"]),
    });
    expect(out.toasts[0].input.body).toBe("foo/bar #99 — Fix flaky test");
  });

  it("sets groupKey, ttl, level, and source on the toast", () => {
    const out = computeNotifFanout({
      notifications: [mkNotif({ id: "a" })],
      dismissedSet: new Set(),
      shownSet: new Set(["seed"]),
    });
    const input = out.toasts[0].input;
    expect(input.groupKey).toBe(FANOUT_GROUP_KEY);
    expect(input.ttl).toBe(FANOUT_TTL_SECONDS);
    expect(input.level).toBe("info");
    expect(input.source).toBe("pr-companion");
    // No `action` field — deep-linking is deferred per spec.
    expect(input.action).toBeUndefined();
  });

  it("marks unparseable / non-PR ids as shown so they don't re-trigger", () => {
    // First entry has a non-PR subject; second has a malformed URL.
    // Both must be skipped from `toasts` but still appear in `idsToMark`.
    const out = computeNotifFanout({
      notifications: [
        mkNotif({
          id: "issue",
          subject: {
            title: "An issue",
            url: "https://api.github.com/repos/foo/bar/issues/1",
            type: "Issue",
          },
        }),
        mkNotif({
          id: "bad-url",
          subject: { title: "Broken", url: "not-a-url", type: "PullRequest" },
        }),
        mkNotif({ id: "good" }),
      ],
      dismissedSet: new Set(),
      shownSet: new Set(["seed"]),
    });
    expect(out.toasts.map((t) => t.notifId)).toEqual(["good"]);
    expect(out.idsToMark.sort()).toEqual(["bad-url", "good", "issue"].sort());
  });

  it("skips notifications missing a string id entirely", () => {
    const out = computeNotifFanout({
      // @ts-expect-error — exercising the runtime guard
      notifications: [mkNotif({ id: null }), mkNotif({ id: "ok" })],
      dismissedSet: new Set(),
      shownSet: new Set(["seed"]),
    });
    expect(out.idsToMark).toEqual(["ok"]);
  });
});
