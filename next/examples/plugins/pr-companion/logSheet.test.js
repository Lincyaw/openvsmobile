// Unit tests for render/logSheet.js — pure builder, exercises the
// last-N-lines truncation + every branch of the error envelope.
//
// logSheet.js imports `@openvsmobile/sdk` for its `ui.*` constructors.
// The SDK is wired into plugin processes via the host's custom loader,
// so it's not resolvable through plain Node ESM lookup from this file's
// location — we stub it the same way inbox.test.js does, returning
// `{kind, ...p}` shapes so the tree-shape assertions below still
// inspect the field names the constructors were called with.

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
      text: make("Text"),
      banner: make("Banner"),
      codeBlock: make("CodeBlock"),
      bottomSheet: make("BottomSheet"),
    },
  };
});

const { buildLogSheet, tailLines, LOG_TAIL_LINES, LOG_SHEET_ID } =
  await import("./render/logSheet.js");

function mkRun(partial = {}) {
  return {
    name: "build",
    status: "completed",
    conclusion: "success",
    startedAt: "2026-05-18T10:00:00Z",
    completedAt: "2026-05-18T10:02:34Z",
    ...partial,
  };
}

describe("tailLines", () => {
  it("returns the input verbatim when at or below the cap", () => {
    const log = "line 1\nline 2\nline 3";
    const out = tailLines(log);
    expect(out.body).toBe(log);
    expect(out.truncated).toBe(false);
  });

  it("returns just the last LOG_TAIL_LINES when over the cap", () => {
    const lines = Array.from({ length: LOG_TAIL_LINES + 50 }, (_, i) => `L${i}`);
    const out = tailLines(lines.join("\n"));
    expect(out.truncated).toBe(true);
    const outLines = out.body.split("\n");
    expect(outLines).toHaveLength(LOG_TAIL_LINES);
    // First surviving line should be index 50; last is the original last.
    expect(outLines[0]).toBe("L50");
    expect(outLines[outLines.length - 1]).toBe(`L${LOG_TAIL_LINES + 49}`);
  });

  it("handles empty / non-string input", () => {
    expect(tailLines("")).toEqual({ body: "", truncated: false });
    // @ts-expect-error — exercising the runtime guard
    expect(tailLines(null)).toEqual({ body: "", truncated: false });
    // @ts-expect-error
    expect(tailLines(undefined)).toEqual({ body: "", truncated: false });
  });
});

describe("buildLogSheet — ok branches", () => {
  it("renders a codeBlock with status caption when content fits", () => {
    const sheet = buildLogSheet({
      run: mkRun(),
      result: { status: "ok", body: "all good" },
    });
    expect(sheet.id).toBe(LOG_SHEET_ID);
    expect(sheet.title).toBe("build");
    const col = sheet.child;
    expect(col.kind).toBe("Column");
    // Status caption is the first child.
    expect(col.children[0].kind).toBe("Text");
    // Then the codeBlock (no truncated-caption because content fits).
    const codeBlock = col.children[col.children.length - 1];
    expect(codeBlock.kind).toBe("CodeBlock");
    expect(codeBlock.code).toBe("all good");
    expect(codeBlock.language).toBe("bash");
  });

  it("inserts the truncated caption when content exceeds the cap", () => {
    const long = Array.from({ length: LOG_TAIL_LINES + 1 }, (_, i) => `L${i}`).join("\n");
    const sheet = buildLogSheet({
      run: mkRun(),
      result: { status: "ok", body: long },
    });
    // Find the truncated caption — second child.
    const truncated = sheet.child.children[1];
    expect(truncated.kind).toBe("Text");
    expect(truncated.text).toContain(`last ${LOG_TAIL_LINES}`);
  });

  it("falls back to status when captionForRun returns empty", () => {
    const sheet = buildLogSheet({
      // No startedAt / completedAt — captionForRun yields "".
      run: mkRun({
        startedAt: null,
        completedAt: null,
        conclusion: null,
        status: "queued",
      }),
      result: { status: "ok", body: "" },
    });
    const cap = sheet.child.children[0];
    expect(cap.kind).toBe("Text");
    expect(cap.text).toBe("queued");
  });
});

describe("buildLogSheet — error branches", () => {
  it("notFound → info banner about pruning / not-yet-started", () => {
    const sheet = buildLogSheet({
      run: mkRun(),
      result: { status: "notFound" },
    });
    const banner = sheet.child.children[sheet.child.children.length - 1];
    expect(banner.kind).toBe("Banner");
    expect(banner.accent).toBe("info");
    expect(banner.title).toMatch(/unavailable/i);
  });

  it("unauthed → danger banner about token", () => {
    const sheet = buildLogSheet({
      run: mkRun(),
      result: { status: "unauthed" },
    });
    const banner = sheet.child.children[sheet.child.children.length - 1];
    expect(banner.accent).toBe("danger");
    expect(banner.title).toMatch(/token/i);
  });

  it("rateLimited → warning banner with the HH:MM reset time", () => {
    const reset = new Date("2026-05-18T15:30:00Z");
    const sheet = buildLogSheet({
      run: mkRun(),
      result: { status: "rateLimited", resetAt: reset },
    });
    const banner = sheet.child.children[sheet.child.children.length - 1];
    expect(banner.accent).toBe("warning");
    expect(banner.title).toMatch(/Rate-limited until/);
  });

  it("offline → info banner", () => {
    const sheet = buildLogSheet({
      run: mkRun(),
      result: { status: "offline" },
    });
    const banner = sheet.child.children[sheet.child.children.length - 1];
    expect(banner.accent).toBe("info");
    expect(banner.title).toMatch(/offline/i);
  });

  it("serverError → danger banner naming the code", () => {
    const sheet = buildLogSheet({
      run: mkRun(),
      result: { status: "serverError", code: 502 },
    });
    const banner = sheet.child.children[sheet.child.children.length - 1];
    expect(banner.accent).toBe("danger");
    expect(banner.title).toMatch(/502/);
  });

  it("unknown status → generic danger banner", () => {
    const sheet = buildLogSheet({
      run: mkRun(),
      // @ts-expect-error — exercising the catch-all
      result: { status: "futureStatus" },
    });
    const banner = sheet.child.children[sheet.child.children.length - 1];
    expect(banner.accent).toBe("danger");
  });
});
