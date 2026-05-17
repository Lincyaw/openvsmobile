import { describe, expect, it } from "vitest";
import { parseUnifiedDiff } from "../src/diffParser.js";

describe("parseUnifiedDiff", () => {
  it("returns empty for empty input", () => {
    expect(parseUnifiedDiff("")).toEqual([]);
  });

  it("skips preamble lines until the first hunk", () => {
    const input = [
      "diff --git a/foo b/foo",
      "index 0123..4567 100644",
      "--- a/foo",
      "+++ b/foo",
      "@@ -1,2 +1,3 @@",
      " context",
      "+added",
      " end",
    ].join("\n");
    const hunks = parseUnifiedDiff(input);
    expect(hunks).toHaveLength(1);
    expect(hunks[0].oldStart).toBe(1);
    expect(hunks[0].oldLines).toBe(2);
    expect(hunks[0].newStart).toBe(1);
    expect(hunks[0].newLines).toBe(3);
    expect(hunks[0].lines.map((l) => l.kind)).toEqual([
      "context",
      "add",
      "context",
    ]);
    expect(hunks[0].lines[1].text).toBe("added");
  });

  it("parses multiple hunks", () => {
    const input = [
      "@@ -10 +10 @@",
      "-old",
      "+new",
      "@@ -20,3 +20,3 @@",
      " a",
      "-b",
      "+B",
      " c",
    ].join("\n");
    const hunks = parseUnifiedDiff(input);
    expect(hunks).toHaveLength(2);
    expect(hunks[0].oldLines).toBe(1);
    expect(hunks[0].newLines).toBe(1);
    expect(hunks[1].lines).toHaveLength(4);
    expect(hunks[1].lines[1].kind).toBe("del");
    expect(hunks[1].lines[2].kind).toBe("add");
  });

  it("handles the no-newline-at-end marker", () => {
    const input = [
      "@@ -1 +1 @@",
      "-old",
      "+new",
      "\\ No newline at end of file",
    ].join("\n");
    const hunks = parseUnifiedDiff(input);
    expect(hunks[0].lines.at(-1)?.kind).toBe("noNewline");
  });

  it("throws on a malformed hunk header", () => {
    const input = "@@ this is garbage @@\n+oops";
    expect(() => parseUnifiedDiff(input)).toThrow(/malformed hunk header/);
  });
});
