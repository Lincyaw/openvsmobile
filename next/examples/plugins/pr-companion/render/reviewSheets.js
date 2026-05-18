// PR Companion — Phase 4 pure helpers for the review/comment sheets.
//
// Side-effectful pieces (showActionSheet / showBottomSheet invocation,
// github POST orchestration, module-level submit-pending guard) live in
// index.js's `handlePhase4ReviewEvent` because they need direct access
// to the cross-phase module-level slots there (githubClient,
// currentDetailPr, the prDetail re-render entry point).
//
// What lives here:
//   * Wire-event constants (action-sheet eventIds + sheet/button node
//     ids) — single source of truth so the dispatch in index.js and any
//     future renderer of these sheets can't drift.
//   * `buildReplyQuotePrefill` — GitHub-flavored markdown quote-block
//     prefix used when the user taps reply on an existing comment.
//   * `mapPostError` — github.js status union → reviewError banner
//     shape used by `setReviewError` in render/prDetail.js.
//   * `reviewSheetHeading` — the user-visible label that names the
//     pending action in the bottom sheet (the sheet has no other
//     metadata; the heading is the user's only "you're about to
//     approve this PR" confirmation).
//
// This file MUST stay free of @openvsmobile/sdk imports so it can be
// unit-tested without the host's sdk-loader (same convention as
// render/_pure.js).

/// Wire-event constants. The dispatch in index.js imports these so a
/// rename to any of these strings would surface as a compile-time
/// error rather than a silently-broken sheet.
export const reviewEvents = {
  REVIEW_BTN_NODE: "prcomp-detail-review-btn",
  BODY_FIELD_NODE: "prcomp-review-body-field",
  SUBMIT_BTN_NODE: "prcomp-review-submit-btn",
  PICK_APPROVE: "detail-review-approve",
  PICK_REQUEST_CHANGES: "detail-review-request-changes",
  PICK_COMMENT: "detail-review-comment",
};

/**
 * Human label for the bottom-sheet heading. Picked by which action
 * sheet button the user tapped (or by "reply" for the per-comment
 * path). For replies we include the original author so the user
 * confirms they're replying to the right thread before submitting.
 *
 * @param {'approve' | 'request-changes' | 'comment' | 'reply'} action
 * @param {string | null} replyToAuthor
 */
export function reviewSheetHeading(action, replyToAuthor) {
  switch (action) {
    case "approve":
      return "Approve this PR";
    case "request-changes":
      return "Request changes";
    case "comment":
      return "Comment on PR";
    case "reply":
      return replyToAuthor !== null && replyToAuthor.length > 0
        ? `Reply to @${replyToAuthor}`
        : "Reply to comment";
    default:
      return "Review";
  }
}

/**
 * Build the quote-block prefill for a reply per the GitHub-flavored
 * markdown convention:
 *
 *   > @author wrote:
 *   > <first line of original body, truncated to 200 chars>
 *
 *   <cursor>
 *
 * Only the first line is quoted on purpose — fully quoting long
 * comments wastes screen on a phone and the original is one tap away
 * (the comment row that the user just tapped to open this sheet).
 *
 * Empty / whitespace-only bodies still produce a `>` line so the
 * quote block isn't visually broken; the user can edit the prefix
 * before submitting.
 *
 * @param {{ user: { login: string }, body: string }} comment
 */
export function buildReplyQuotePrefill(comment) {
  const login = comment?.user?.login ?? "";
  const body = typeof comment?.body === "string" ? comment.body : "";
  const firstLine = body.split("\n", 1)[0].trim().slice(0, 200);
  const authorLine = `> @${login} wrote:`;
  const bodyLine = firstLine.length > 0 ? `> ${firstLine}` : ">";
  return `${authorLine}\n${bodyLine}\n\n`;
}

/**
 * Map github.js's POST-result `{status, code?}` union into the
 * reviewError slot shape used by setReviewError in render/prDetail.js.
 * Mirrors the `error.kind` switch in `buildReviewErrorBanner`.
 *
 * @param {{ status: string, code?: number }} result
 * @returns {{ kind: string, code?: number }}
 */
export function mapPostError(result) {
  if (result === null || result === undefined) return { kind: "unknown" };
  if (result.status === "unauthed") return { kind: "unauthed" };
  if (result.status === "offline") return { kind: "offline" };
  if (result.status === "rateLimited") return { kind: "rateLimited" };
  if (result.status === "serverError") {
    return typeof result.code === "number"
      ? { kind: "serverError", code: result.code }
      : { kind: "serverError" };
  }
  return { kind: "unknown" };
}
