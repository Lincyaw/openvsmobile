// PR Companion — Conversation tab body (Phase 3, read-only).
//
// Renders the PR body as the first card, then top-level issue comments
// in chronological order (GitHub returns them that way; we trust the
// server's ordering rather than re-sorting on `createdAt`).
//
// "Top-level" means: the comment has neither `path` nor `inReplyToId`.
//   * `path` is set on review-thread comments (inline file comments).
//   * `inReplyToId` is set on replies WITHIN a review thread.
//
// The github.js client's `listPullComments` already hits the
// `/issues/{n}/comments` endpoint which only returns top-level
// conversation, so both fields are typically null — but we filter
// defensively in case a future caller swaps in
// `/pulls/{n}/comments` (merge-tab work). This is also a one-line
// guarantee that Phase 4's inline-comment work won't accidentally
// leak inline comments into this view.

import { ui } from "@openvsmobile/sdk";

import { filterTopLevelComments, formatRelative } from "./_pure.js";

// Re-export so callers can import either from here or from _pure.js
// without caring which file owns the canonical implementation.
export { filterTopLevelComments, formatRelative };

// === Phase 4 additions ===
// Wire events for the top-level Comment button and per-comment reply.
// The button itself emits `{type:'tap', nodeId:'prcomp-conv-comment-btn'}`;
// the per-comment swipe/tap actions carry a hardcoded eventId prefix
// followed by the GitHub comment id, which index.js parses to look up
// the original body (for the quote prefill) and route the reply POST.
export const conversationEvents = {
  COMMENT_BUTTON_NODE: "prcomp-conv-comment-btn",
  REPLY_PREFIX: "prcomp-conv-reply:",
};
// === end Phase 4 additions ===

/**
 * Build the Conversation tab body.
 *
 * @param {{
 *   pr: { body: string } | null,
 *   comments: Array<{
 *     id: number,
 *     user: { login: string, avatarUrl: string },
 *     body: string,
 *     createdAt: string,
 *     path: string | null,
 *     inReplyToId: number | null,
 *   }> | null,
 *   error?: { kind: string } | null,
 *   nowMs?: number,
 * }} params
 */
export function buildConversationTabBody({ pr, comments, error, nowMs }) {
  /** @type {import("@openvsmobile/sdk").UiNode[]} */
  const items = [];

  // PR body card. If we have a pr object but its body is empty / null,
  // render an explicit placeholder so the card isn't blank.
  if (pr !== null) {
    const body = typeof pr.body === "string" ? pr.body.trim() : "";
    items.push(
      ui.section({
        id: "prcomp-detail-conv-body",
        variant: "card",
        children:
          body.length > 0
            ? [
                ui.markdown({
                  id: "prcomp-detail-conv-body-md",
                  markdown: body,
                }),
              ]
            : [
                ui.text({
                  id: "prcomp-detail-conv-body-empty",
                  text: "(no description)",
                  style: "caption",
                }),
              ],
      }),
    );
  }

  // Comments. `null` means the fetch failed for this tab; degrade with a
  // caption inside the same list so the PR body remains visible above.
  if (comments === null) {
    const msg =
      error !== null && error !== undefined
        ? `Failed to load comments (${error.kind}).`
        : "Failed to load comments.";
    items.push(
      ui.section({
        id: "prcomp-detail-conv-comments-error",
        children: [
          ui.text({
            id: "prcomp-detail-conv-comments-error-text",
            text: msg,
            style: "caption",
          }),
        ],
      }),
    );
  } else {
    const topLevel = filterTopLevelComments(comments);
    for (const c of topLevel) {
      const cBody = typeof c.body === "string" ? c.body.trim() : "";
      // === Phase 4 additions ===
      // Comments rendered as listTile (not section/card) so they pick up
      // swipe-to-reply via UiListTile.swipeActions — UiSection doesn't
      // expose that slot. This trades full markdown rendering for a
      // tappable + swipeable shape; the body is collapsed into a
      // subtitle string. The full body is one tap away (the reply sheet
      // pre-fills it as a quote block), and the rich render returns in
      // a future "tap to expand" phase if the regression bites.
      const when = formatRelative(c.createdAt, nowMs);
      const title = when.length > 0 ? `${c.user.login} · ${when}` : c.user.login;
      const subtitle =
        cBody.length > 0
          ? cBody.split("\n")[0].slice(0, 140)
          : "(empty comment)";
      items.push(
        ui.listTile({
          id: `prcomp-detail-conv-comment-${c.id}`,
          title,
          subtitle,
          leading: ui.avatar({
            id: `prcomp-detail-conv-comment-${c.id}-avatar`,
            src: c.user.avatarUrl,
            size: "sm",
          }),
          // Both gestures route to the same reply sheet so phone users
          // can choose whichever feels natural. The id suffix is the
          // GitHub comment id; index.js parses it back out.
          onTapEvent: `${conversationEvents.REPLY_PREFIX}${c.id}`,
          swipeActions: [
            {
              label: "Reply",
              eventId: `${conversationEvents.REPLY_PREFIX}${c.id}`,
            },
          ],
        }),
      );
      // === end Phase 4 additions ===
    }
    if (topLevel.length === 0 && pr !== null) {
      // Successful fetch, just no conversation yet. A brief placeholder
      // is friendlier than an empty list under the body card.
      items.push(
        ui.section({
          id: "prcomp-detail-conv-empty",
          children: [
            ui.text({
              id: "prcomp-detail-conv-empty-text",
              text: "No comments yet.",
              style: "caption",
            }),
          ],
        }),
      );
    }
  }

  // If the PR itself failed to load but somehow we're called anyway,
  // produce one item so the list isn't empty.
  if (items.length === 0) {
    items.push(
      ui.section({
        id: "prcomp-detail-conv-no-pr",
        children: [
          ui.text({
            id: "prcomp-detail-conv-no-pr-text",
            text: "PR data unavailable.",
            style: "caption",
          }),
        ],
      }),
    );
  }

  // === Phase 4 additions ===
  // Top-level Comment button at the bottom of the list. Always shown
  // when the PR loaded (pr !== null), even on the empty-conversation
  // path — that's the most natural place to start a thread. Suppressed
  // when the PR fetch itself failed since we don't have a number to
  // POST against; the user retries once the PR data lands.
  if (pr !== null) {
    items.push(
      ui.section({
        id: "prcomp-detail-conv-comment-cta",
        children: [
          ui.button({
            id: conversationEvents.COMMENT_BUTTON_NODE,
            label: "Comment",
            style: "secondary",
          }),
        ],
      }),
    );
  }
  // === end Phase 4 additions ===

  return ui.list({
    id: "prcomp-detail-conv-list",
    items,
  });
}
