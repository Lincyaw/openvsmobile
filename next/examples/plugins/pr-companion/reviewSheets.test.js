// Unit tests for render/reviewSheets.js — Phase 4 pure helpers.
//
// Picks up via the `../examples/plugins/*/*.test.js` glob in
// next/backend/vitest.config.ts.
//
// Scope: the side-effect-free pieces of Phase 4 (event constants,
// quote-prefill builder, github.js result → reviewError mapping,
// heading-text picker). The orchestration that wires these into
// showActionSheet / showBottomSheet + the github POST lives in
// index.js's `handlePhase4ReviewEvent`; that path is integration-only
// (plugin.run() at module load makes index.js unimportable from
// vitest) and is exercised end-to-end by the plugin-host smoke tests
// once those cover Phase 4.

import { describe, expect, it } from "vitest";

import {
  reviewEvents,
  reviewSheetHeading,
  buildReplyQuotePrefill,
  mapPostError,
} from "./render/reviewSheets.js";

describe("reviewEvents", () => {
  it("ships stable node ids and pick eventIds", () => {
    // These strings are the wire contract between the dispatch in
    // index.js and the renderer in prDetail.js / conversationTab.js. A
    // rename here is a real protocol break, so pin them down.
    expect(reviewEvents.REVIEW_BTN_NODE).toBe("prcomp-detail-review-btn");
    expect(reviewEvents.BODY_FIELD_NODE).toBe("prcomp-review-body-field");
    expect(reviewEvents.SUBMIT_BTN_NODE).toBe("prcomp-review-submit-btn");
    expect(reviewEvents.PICK_APPROVE).toBe("detail-review-approve");
    expect(reviewEvents.PICK_REQUEST_CHANGES).toBe(
      "detail-review-request-changes",
    );
    expect(reviewEvents.PICK_COMMENT).toBe("detail-review-comment");
  });
});

describe("reviewSheetHeading", () => {
  it("names the four actions unambiguously", () => {
    expect(reviewSheetHeading("approve", null)).toBe("Approve this PR");
    expect(reviewSheetHeading("request-changes", null)).toBe(
      "Request changes",
    );
    expect(reviewSheetHeading("comment", null)).toBe("Comment on PR");
  });
  it("includes the reply target author when available", () => {
    expect(reviewSheetHeading("reply", "alice")).toBe("Reply to @alice");
  });
  it("falls back to a generic reply label when the author is unknown", () => {
    expect(reviewSheetHeading("reply", null)).toBe("Reply to comment");
    expect(reviewSheetHeading("reply", "")).toBe("Reply to comment");
  });
});

describe("buildReplyQuotePrefill", () => {
  it("builds the GitHub-flavored quote block", () => {
    const out = buildReplyQuotePrefill({
      user: { login: "alice" },
      body: "Looks good to me",
    });
    expect(out).toBe("> @alice wrote:\n> Looks good to me\n\n");
  });
  it("quotes only the first line of multi-line bodies", () => {
    const out = buildReplyQuotePrefill({
      user: { login: "bob" },
      body: "First line\nSecond line\nThird line",
    });
    expect(out).toBe("> @bob wrote:\n> First line\n\n");
  });
  it("truncates long first lines to 200 chars", () => {
    const long = "x".repeat(500);
    const out = buildReplyQuotePrefill({
      user: { login: "c" },
      body: long,
    });
    // Author line (12 chars including newline) + `> ` + 200 x's + `\n\n`.
    expect(out).toBe(`> @c wrote:\n> ${"x".repeat(200)}\n\n`);
  });
  it("renders an empty quote line when the body is whitespace-only", () => {
    const out = buildReplyQuotePrefill({
      user: { login: "d" },
      body: "   ",
    });
    expect(out).toBe("> @d wrote:\n>\n\n");
  });
  it("tolerates missing body / user fields", () => {
    const out = buildReplyQuotePrefill(
      /** @type {any} */ ({ user: { login: "e" } }),
    );
    expect(out).toBe("> @e wrote:\n>\n\n");
  });
});

describe("mapPostError", () => {
  it("maps the four github.js status kinds we surface as banners", () => {
    expect(mapPostError({ status: "unauthed" })).toEqual({ kind: "unauthed" });
    expect(mapPostError({ status: "offline" })).toEqual({ kind: "offline" });
    expect(mapPostError({ status: "rateLimited" })).toEqual({
      kind: "rateLimited",
    });
    expect(mapPostError({ status: "serverError", code: 500 })).toEqual({
      kind: "serverError",
      code: 500,
    });
  });
  it("preserves the HTTP code on serverError, omits it when absent", () => {
    expect(mapPostError({ status: "serverError" })).toEqual({
      kind: "serverError",
    });
  });
  it("falls back to 'unknown' for anything else (including null)", () => {
    expect(mapPostError({ status: "something-weird" })).toEqual({
      kind: "unknown",
    });
    expect(mapPostError(/** @type {any} */ (null))).toEqual({ kind: "unknown" });
  });
});
