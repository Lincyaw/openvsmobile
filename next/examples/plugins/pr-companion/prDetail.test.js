// PR Companion — Phase 3 pure-helper unit tests.
//
// Vitest picks this file up via
// `../examples/plugins/*/*.test.js` in next/backend/vitest.config.ts.
//
// Scope: the pure parsing / filtering helpers that don't import the
// SDK. They live in `./render/_pure.js` precisely so this test file
// can import them without triggering a `@openvsmobile/sdk` resolution
// (the example plugin directory has no `node_modules`, only the host's
// sdk-loader supplies the SDK at runtime).
//
// The SDK-using tree builders (`buildFilesTabBody`,
// `buildConversationTabBody`, `buildDetailPanelTree`) are exercised
// end-to-end once the plugin host's smoke tests cover Phase 3; the
// pure helpers below pin down the edge cases the design doc calls out
// (binaries, large patches, no extension, dotfiles, inline comments
// leaking into the top-level list, clock skew, etc.).

import { describe, it, expect } from "vitest";

import {
  inferLanguage,
  splitHunks,
  fileIdSlug,
  filterTopLevelComments,
  formatRelative,
} from "./render/_pure.js";

describe("inferLanguage", () => {
  it("maps common extensions", () => {
    expect(inferLanguage("a.js")).toBe("javascript");
    expect(inferLanguage("a.ts")).toBe("typescript");
    expect(inferLanguage("a/b/c.tsx")).toBe("typescript");
    expect(inferLanguage("foo.dart")).toBe("dart");
    expect(inferLanguage("script.sh")).toBe("bash");
    expect(inferLanguage("README.md")).toBe("markdown");
  });

  it("returns null for unknown / no extension", () => {
    expect(inferLanguage("Dockerfile")).toBeNull();
    expect(inferLanguage("Makefile")).toBeNull();
    expect(inferLanguage("a.unknownext")).toBeNull();
    expect(inferLanguage("")).toBeNull();
    // Dotfile: leading `.` is not an extension separator.
    expect(inferLanguage(".gitignore")).toBeNull();
  });

  it("is case-insensitive on the extension", () => {
    expect(inferLanguage("a.TS")).toBe("typescript");
    expect(inferLanguage("a.PY")).toBe("python");
  });
});

describe("splitHunks", () => {
  it("splits on @@ markers and keeps the header", () => {
    const patch = [
      "@@ -1,3 +1,4 @@",
      " line a",
      "+added",
      " line b",
      "@@ -10,2 +11,2 @@",
      "-old",
      "+new",
    ].join("\n");
    const hunks = splitHunks(patch);
    expect(hunks).toHaveLength(2);
    expect(hunks[0].startsWith("@@ -1,3 +1,4 @@")).toBe(true);
    expect(hunks[0]).toContain("+added");
    expect(hunks[1].startsWith("@@ -10,2 +11,2 @@")).toBe(true);
    expect(hunks[1]).toContain("+new");
  });

  it("returns [] for null / empty input", () => {
    expect(splitHunks(null)).toEqual([]);
    expect(splitHunks("")).toEqual([]);
  });

  it("yields the input as a single chunk when no @@ header", () => {
    const hunks = splitHunks("just\nplain\ntext");
    expect(hunks).toHaveLength(1);
    expect(hunks[0]).toBe("just\nplain\ntext");
  });
});

describe("fileIdSlug", () => {
  it("collapses path separators and dots to dashes", () => {
    expect(fileIdSlug("src/foo.ts")).toBe("src-foo-ts");
    expect(fileIdSlug("a/b/c.d.e")).toBe("a-b-c-d-e");
  });
  it("leaves alphanumerics alone", () => {
    expect(fileIdSlug("Foo123Bar")).toBe("Foo123Bar");
  });
});

describe("filterTopLevelComments", () => {
  it("filters out comments with path or inReplyToId", () => {
    const comments = [
      { id: 1, path: null, inReplyToId: null },
      { id: 2, path: "src/a.ts", inReplyToId: null }, // inline review comment
      { id: 3, path: null, inReplyToId: 1 }, // thread reply
      { id: 4, path: null, inReplyToId: null },
    ];
    const result = filterTopLevelComments(comments);
    expect(result.map((c) => c.id)).toEqual([1, 4]);
  });

  it("tolerates undefined as well as null", () => {
    // The github.js mapper produces `null` consistently, but a defensive
    // filter should treat `undefined` (e.g. from a future caller) the
    // same way.
    const comments = [{ id: 5 }];
    expect(filterTopLevelComments(comments)).toHaveLength(1);
  });
});

describe("formatRelative", () => {
  const now = Date.parse("2026-05-18T12:00:00Z");

  it("renders 'just now' for sub-minute deltas", () => {
    expect(formatRelative("2026-05-18T11:59:30Z", now)).toBe("just now");
  });
  it("renders minutes / hours / days / months / years", () => {
    expect(formatRelative("2026-05-18T11:55:00Z", now)).toBe("5m ago");
    expect(formatRelative("2026-05-18T09:00:00Z", now)).toBe("3h ago");
    expect(formatRelative("2026-05-15T12:00:00Z", now)).toBe("3d ago");
    expect(formatRelative("2026-02-17T12:00:00Z", now)).toBe("3mo ago");
    expect(formatRelative("2023-05-18T12:00:00Z", now)).toBe("3y ago");
  });
  it("returns input unchanged for unparseable input", () => {
    expect(formatRelative("not a date", now)).toBe("not a date");
  });
  it("renders 'just now' for future-dated input (clock skew)", () => {
    expect(formatRelative("2026-05-18T13:00:00Z", now)).toBe("just now");
  });
  it("returns empty string for empty / non-string input", () => {
    expect(formatRelative("", now)).toBe("");
  });
});
