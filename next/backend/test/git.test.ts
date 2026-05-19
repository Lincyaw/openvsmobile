// Pin the orientation of `git rev-list --left-right --count` parsing.
// The output format is `<behind>\t<ahead>` (left = upstream-only,
// right = HEAD-only). A silent flip here would mislabel every ahead/
// behind badge in the UI, so we lock the contract with a fixture.

import { describe, expect, it } from "vitest";
import { parseRevListAheadBehind } from "../src/git.js";

describe("parseRevListAheadBehind", () => {
  it("maps `<behind>\\t<ahead>` to {behind, ahead}", () => {
    expect(parseRevListAheadBehind("3\t5")).toEqual({ behind: 3, ahead: 5 });
  });
});
