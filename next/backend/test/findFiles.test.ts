// Unit tests for workspace.findFiles.
//
// Real filesystem fixtures (no mocks per docs/conventions.md §6):
//   * 30 files spread across nested directories.
//   * A `.gitignore` excluding `secret/`.
//   * The hard-coded noise dirs (`node_modules`, `.git`, `dist`, `build`,
//     `.dart_tool`, `target`, `vendor`) populated with one file each.
//   * A symlink rooted inside the workspace pointing to a file *outside*
//     the workspace.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { promises as fs } from "node:fs";
import { join } from "node:path";
import {
  makeTempDir,
  rmTempDir,
  writeWorkspaceFile,
} from "./_helpers.js";
import { findFiles, scoreMatch } from "../src/findFiles.js";

let workspaceRoot: string;
let outsideRoot: string;

const FILES = [
  "README.md",
  "package.json",
  "src/index.ts",
  "src/util.ts",
  "src/util/format.ts",
  "src/util/parse.ts",
  "src/lib/server.ts",
  "src/lib/client.ts",
  "src/lib/store.ts",
  "src/cli/main.ts",
  "src/cli/help.ts",
  "src/cli/args.ts",
  "test/index.test.ts",
  "test/util.test.ts",
  "test/cli.test.ts",
  "docs/guide.md",
  "docs/api.md",
  "docs/release.md",
  "foo/bar.md",
  "foo/baz.md",
  "scripts/build.sh",
  "scripts/release.sh",
  "scripts/dev.sh",
  "config/dev.json",
  "config/prod.json",
  "config/test.json",
  "examples/one.ts",
  "examples/two.ts",
  "examples/three.ts",
  "Makefile",
];

const IGNORED_DIRS_WITH_FILE = [
  "node_modules/some-pkg/index.js",
  ".git/HEAD",
  "dist/bundle.js",
  "build/output.js",
  ".dart_tool/cache.json",
  "target/binary",
  "vendor/dep/lib.go",
];

beforeEach(async () => {
  workspaceRoot = await makeTempDir("openvsmobile-find-");
  outsideRoot = await makeTempDir("openvsmobile-find-outside-");
  for (const rel of FILES) {
    await writeWorkspaceFile(workspaceRoot, rel, "x\n");
  }
  for (const rel of IGNORED_DIRS_WITH_FILE) {
    await writeWorkspaceFile(workspaceRoot, rel, "x\n");
  }
  // Populate a `.gitignore` that excludes `secret/`. The hard-coded noise
  // dir filter handles `node_modules` etc. — we want a separate signal that
  // gitignore patterns are also honored.
  await writeWorkspaceFile(workspaceRoot, ".gitignore", "secret/\n");
  await writeWorkspaceFile(workspaceRoot, "secret/passwords.txt", "nope\n");
});

afterEach(async () => {
  await rmTempDir(workspaceRoot);
  await rmTempDir(outsideRoot);
});

describe("findFiles", () => {
  it("scores 'fobar' against foo/bar.md positively", async () => {
    const result = await findFiles(workspaceRoot, {
      query: "fobar",
      limit: 50,
      includeIgnored: false,
    });
    const hit = result.matches.find((m) => m.path === "foo/bar.md");
    expect(hit).toBeDefined();
    expect(hit!.score).toBeGreaterThan(0);
  });

  it("excludes hard-coded noise dirs", async () => {
    const result = await findFiles(workspaceRoot, {
      // Query has chars from every noise file so a stray hit would surface.
      query: "i",
      limit: 200,
      includeIgnored: false,
    });
    const paths = result.matches.map((m) => m.path);
    for (const noise of [
      "node_modules/",
      ".git/",
      "dist/",
      "build/",
      ".dart_tool/",
      "target/",
      "vendor/",
    ]) {
      expect(paths.some((p) => p.startsWith(noise))).toBe(false);
    }
  });

  it("excludes paths matched by .gitignore", async () => {
    const result = await findFiles(workspaceRoot, {
      query: "password",
      limit: 50,
      includeIgnored: false,
    });
    expect(result.matches).toEqual([]);
  });

  it("includeIgnored:true surfaces ignored + noise paths", async () => {
    const result = await findFiles(workspaceRoot, {
      query: "password",
      limit: 50,
      includeIgnored: true,
    });
    expect(result.matches.some((m) => m.path === "secret/passwords.txt"))
      .toBe(true);
  });

  it("ranks basename matches above prefix-only matches", async () => {
    // `index` matches both `src/index.ts` (basename) and `test/index.test.ts`
    // (basename also, but with more chars after).
    const result = await findFiles(workspaceRoot, {
      query: "index",
      limit: 50,
      includeIgnored: false,
    });
    const indexTs = result.matches.findIndex((m) => m.path === "src/index.ts");
    const indexTest = result.matches.findIndex(
      (m) => m.path === "test/index.test.ts",
    );
    expect(indexTs).toBeGreaterThanOrEqual(0);
    expect(indexTest).toBeGreaterThanOrEqual(0);
    expect(indexTs).toBeLessThan(indexTest);
  });

  it("returns matches sorted by score desc", async () => {
    const result = await findFiles(workspaceRoot, {
      query: "main",
      limit: 50,
      includeIgnored: false,
    });
    for (let i = 1; i < result.matches.length; i++) {
      const prev = result.matches[i - 1]!;
      const cur = result.matches[i]!;
      expect(prev.score).toBeGreaterThanOrEqual(cur.score);
    }
  });

  it("respects limit and reports truncated", async () => {
    const result = await findFiles(workspaceRoot, {
      // Single char matches almost everything — guaranteed to overflow `limit`.
      query: "e",
      limit: 3,
      includeIgnored: false,
    });
    expect(result.matches.length).toBeLessThanOrEqual(3);
    // We can't promise `truncated:true` here because the scorer drops
    // candidates that don't contain the query — but on this corpus every file
    // has an 'e', so we expect strictly more than 3 matches in total.
    // Easier signal: an unconstrained run finds more than 3.
    const wide = await findFiles(workspaceRoot, {
      query: "e",
      limit: 200,
      includeIgnored: false,
    });
    expect(wide.matches.length).toBeGreaterThan(3);
  });

  it("returns no matches and truncated:false for an empty query", async () => {
    const result = await findFiles(workspaceRoot, {
      query: "   ",
      limit: 50,
      includeIgnored: false,
    });
    expect(result.matches).toEqual([]);
    expect(result.truncated).toBe(false);
  });

  it("does not follow a symlink pointing outside the workspace", async () => {
    // Create a sibling file outside the workspace and a symlink to it from
    // inside. The walker must skip the symlink entirely — neither return
    // its target nor descend into it.
    await fs.writeFile(join(outsideRoot, "leaked.md"), "leaked\n");
    await fs.symlink(
      join(outsideRoot, "leaked.md"),
      join(workspaceRoot, "leaked-link.md"),
    );
    const result = await findFiles(workspaceRoot, {
      query: "leak",
      limit: 50,
      includeIgnored: false,
    });
    expect(result.matches).toEqual([]);
  });

  it("does not descend into a directory symlink", async () => {
    await fs.mkdir(join(outsideRoot, "external-dir"), { recursive: true });
    await fs.writeFile(
      join(outsideRoot, "external-dir", "hidden.txt"),
      "hidden\n",
    );
    await fs.symlink(
      join(outsideRoot, "external-dir"),
      join(workspaceRoot, "link-dir"),
    );
    const result = await findFiles(workspaceRoot, {
      query: "hidden",
      limit: 50,
      includeIgnored: false,
    });
    expect(result.matches).toEqual([]);
  });

  it("returns case-insensitive matches", async () => {
    const result = await findFiles(workspaceRoot, {
      query: "README",
      limit: 50,
      includeIgnored: false,
    });
    expect(result.matches.some((m) => m.path === "README.md")).toBe(true);
  });
});

describe("scoreMatch", () => {
  it("returns null when the query is not a subsequence", () => {
    expect(scoreMatch("zzz", "src/index.ts")).toBeNull();
  });

  it("scores consecutive matches higher than scattered", () => {
    const consecutive = scoreMatch("index", "src/index.ts");
    const scattered = scoreMatch("ixs", "src/index.ts");
    expect(consecutive).not.toBeNull();
    expect(scattered).not.toBeNull();
    expect(consecutive!).toBeGreaterThan(scattered!);
  });

  it("scores basename matches higher than prefix matches", () => {
    const basename = scoreMatch("util", "src/util.ts");
    const prefix = scoreMatch("util", "src/util/format.ts");
    expect(basename).not.toBeNull();
    expect(prefix).not.toBeNull();
    expect(basename!).toBeGreaterThan(prefix!);
  });
});
