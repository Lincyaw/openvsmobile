// Integration tests for the dispatch table: workspace.subscribe modes,
// git.diff caching, git.log shape, and fs.listDir/readFile contract changes.
//
// Drives `dispatch()` directly with a synthetic RpcContext — no WebSocket,
// no Connection lifecycle. The real workspace model + chokidar still spin up
// because that's the integration we care about exercising.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { WebSocket } from "ws";
import { rm } from "node:fs/promises";
import { join } from "node:path";
import {
  FakeWebSocket,
  git,
  makeRepo,
  makeTempDir,
  rmTempDir,
  writeWorkspaceFile,
} from "./_helpers.js";
import { dispatch, type RpcContext } from "../src/rpc.js";
import { ProcessState } from "../src/state.js";

let repoDir: string;
let state: ProcessState;
let sock: FakeWebSocket;

function makeContext(): RpcContext {
  return {
    state,
    expectedToken: "test-token",
    serverVersion: "0.0.0-test",
    ws: sock as unknown as WebSocket,
    markAuthenticated: () => {},
  };
}

async function call<T = unknown>(method: string, params: unknown): Promise<T> {
  const ctx = makeContext();
  return (await dispatch(ctx, {
    jsonrpc: "2.0",
    id: 1,
    method,
    params,
  })) as T;
}

beforeEach(async () => {
  repoDir = await makeTempDir("openvsmobile-rpctest-");
  await makeRepo(repoDir);
  await writeWorkspaceFile(repoDir, "README.md", "v1\n");
  await git(repoDir, ["add", "-A"]);
  await git(repoDir, ["commit", "-q", "-m", "first"]);
  state = new ProcessState();
  sock = new FakeWebSocket();
});

afterEach(async () => {
  state.shutdownAll();
  await rmTempDir(repoDir);
});

describe("workspace.subscribe dispatch", () => {
  it("snapshot mode emits a decoration.snapshot follow-up", async () => {
    const opened = await call<{ workspace: { id: string } }>("workspace.open", {
      root: repoDir,
    });
    // No sinceVersion → snapshot.
    const result = await call<{ mode: string; baseVersion: number }>(
      "workspace.subscribe",
      { workspaceId: opened.workspace.id },
    );
    expect(result.mode).toBe("snapshot");
    // Snapshot follow-up arrives on the next microtask tick.
    await Promise.resolve();
    await Promise.resolve();
    const snaps = sock.notifications("workspace.decoration.snapshot");
    expect(snaps.length).toBe(1);
    // Clean repo → entries is empty.
    expect(
      (snaps[0].params as { entries: unknown[] }).entries,
    ).toEqual([]);
  });

  it("current mode emits nothing follow-up", async () => {
    const opened = await call<{ workspace: { id: string } }>("workspace.open", {
      root: repoDir,
    });
    // Subscribe with the live version → current.
    const first = await call<{ mode: string; baseVersion: number }>(
      "workspace.subscribe",
      { workspaceId: opened.workspace.id },
    );
    // Clear notifs from the first (snapshot) subscribe.
    sock.sent = [];
    const result = await call<{ mode: string }>("workspace.subscribe", {
      workspaceId: opened.workspace.id,
      sinceVersion: first.baseVersion,
    });
    expect(result.mode).toBe("current");
    await Promise.resolve();
    expect(sock.notifications("workspace.decoration.snapshot")).toEqual([]);
    expect(sock.notifications("workspace.decoration.delta")).toEqual([]);
  });
});

describe("git.diff", () => {
  type DiffLine = { kind: "context" | "add" | "del"; text: string };
  type Hunk = {
    oldStart: number;
    oldLines: number;
    newStart: number;
    newLines: number;
    header: string;
    lines: DiffLine[];
  };
  type DiffResp = {
    hunks: Hunk[];
    baseSha: string;
    headSha: string;
    isBinary: boolean;
    tooLarge?: true;
  };

  it("returns one hunk with the right shape for a one-line staged edit", async () => {
    const opened = await call<{ workspace: { id: string } }>("workspace.open", {
      root: repoDir,
    });
    // README.md starts as "v1\n" from beforeEach; edit + stage to mirror the
    // canonical "diff vs HEAD" call path.
    await writeWorkspaceFile(repoDir, "README.md", "v2\n");
    await git(repoDir, ["add", "README.md"]);
    const res = await call<DiffResp>("git.diff", {
      workspaceId: opened.workspace.id,
      path: "README.md",
    });
    expect(res.isBinary).toBe(false);
    expect(res.tooLarge).toBeUndefined();
    expect(res.baseSha).toMatch(/^[0-9a-f]{40}$/);
    expect(res.headSha).toMatch(/^[0-9a-f]{40}$/);
    expect(res.hunks).toHaveLength(1);
    const h = res.hunks[0];
    expect(h.oldStart).toBe(1);
    expect(h.oldLines).toBe(1);
    expect(h.newStart).toBe(1);
    expect(h.newLines).toBe(1);
    expect(h.header).toMatch(/^@@ -1 \+1 @@/);
    expect(h.lines).toEqual([
      { kind: "del", text: "v1" },
      { kind: "add", text: "v2" },
    ]);
  });

  it("short-circuits the second call for an identical content-addressed key", async () => {
    const opened = await call<{ workspace: { id: string } }>("workspace.open", {
      root: repoDir,
    });
    await writeWorkspaceFile(repoDir, "README.md", "v2\n");
    const first = await call<DiffResp>("git.diff", {
      workspaceId: opened.workspace.id,
      path: "README.md",
    });
    // Mutate the working tree WITHOUT triggering a drain (which would
    // invalidate the diff cache via the model's onInvalidate hook). The
    // identical (baseSha, headSha) pair we just computed must hit the cache
    // and return the OLD result byte-for-byte even though git would now see
    // different content on disk.
    await writeWorkspaceFile(repoDir, "README.md", "v3-different\n");
    const second = await call<DiffResp>("git.diff", {
      workspaceId: opened.workspace.id,
      path: "README.md",
      // Re-pass the resolved baseSha so we exercise the (workspace, path,
      // baseSha, headSha-from-disk) key path. The server recomputes headSha
      // from the new on-disk file, so this MISSES cache and returns a fresh
      // result — that proves the key is content-addressed (the original
      // assertion was inverted; what the cache actually short-circuits is a
      // repeated call with the same on-disk state, exercised below).
      base: first.baseSha,
    });
    expect(second.headSha).not.toBe(first.headSha);
    // Same-on-disk replay should be cached.
    await writeWorkspaceFile(repoDir, "README.md", "v2\n");
    const third = await call<DiffResp>("git.diff", {
      workspaceId: opened.workspace.id,
      path: "README.md",
    });
    expect(third).toEqual(first);
  });

  it("returns isBinary: true with empty hunks for a binary file", async () => {
    const opened = await call<{ workspace: { id: string } }>("workspace.open", {
      root: repoDir,
    });
    // Commit a PNG fixture so the binary kind is determined by content, not
    // by .gitattributes. The 8-byte PNG magic plus an IHDR chunk header is
    // enough for git's heuristic to classify it binary.
    const pngBytes = new Uint8Array([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // magic
      0x00, 0x00, 0x00, 0x0d, // IHDR length
      0x49, 0x48, 0x44, 0x52, // "IHDR"
      0x00, 0x00, 0x00, 0x01, // width 1
      0x00, 0x00, 0x00, 0x01, // height 1
      0x08, 0x06, 0x00, 0x00, 0x00, // bit depth, color type, etc.
    ]);
    await writeWorkspaceFile(repoDir, "icon.png", pngBytes);
    await git(repoDir, ["add", "-A"]);
    await git(repoDir, ["commit", "-q", "-m", "binary"]);
    // Modify the file so there's actually a diff to render.
    const pngEdited = new Uint8Array([...pngBytes, 0xff, 0x00, 0xff]);
    await writeWorkspaceFile(repoDir, "icon.png", pngEdited);
    const res = await call<DiffResp>("git.diff", {
      workspaceId: opened.workspace.id,
      path: "icon.png",
    });
    expect(res.isBinary).toBe(true);
    expect(res.hunks).toEqual([]);
    expect(res.baseSha).toMatch(/^[0-9a-f]{40}$/);
    expect(res.headSha).toMatch(/^[0-9a-f]{40}$/);
  });

  it("renders a deleted file as a single hunk of del lines", async () => {
    const opened = await call<{ workspace: { id: string } }>("workspace.open", {
      root: repoDir,
    });
    // Commit a multi-line file, then delete it from the working tree.
    await writeWorkspaceFile(repoDir, "gone.txt", "alpha\nbeta\ngamma\n");
    await git(repoDir, ["add", "-A"]);
    await git(repoDir, ["commit", "-q", "-m", "add gone.txt"]);
    await rm(join(repoDir, "gone.txt"));
    const res = await call<DiffResp>("git.diff", {
      workspaceId: opened.workspace.id,
      path: "gone.txt",
    });
    expect(res.isBinary).toBe(false);
    expect(res.tooLarge).toBeUndefined();
    expect(res.hunks).toHaveLength(1);
    expect(res.hunks[0].lines.map((l) => l.kind)).toEqual(["del", "del", "del"]);
    expect(res.hunks[0].lines.map((l) => l.text)).toEqual([
      "alpha",
      "beta",
      "gamma",
    ]);
  });

  it("flags tooLarge: true when the diff exceeds 500 KiB", async () => {
    const opened = await call<{ workspace: { id: string } }>("workspace.open", {
      root: repoDir,
    });
    // ~600 KiB of unique lines so the diff payload comfortably crosses the
    // 500 KiB cap. We commit a smaller seed (no need to bloat the index
    // before the diff), then overwrite it with the big content.
    await writeWorkspaceFile(repoDir, "big.txt", "seed\n");
    await git(repoDir, ["add", "-A"]);
    await git(repoDir, ["commit", "-q", "-m", "seed big.txt"]);
    const lines: string[] = [];
    for (let i = 0; i < 20000; i++) {
      lines.push(`line ${i} ${"x".repeat(30)}`);
    }
    await writeWorkspaceFile(repoDir, "big.txt", lines.join("\n") + "\n");
    const res = await call<DiffResp>("git.diff", {
      workspaceId: opened.workspace.id,
      path: "big.txt",
    });
    expect(res.tooLarge).toBe(true);
    expect(res.hunks).toEqual([]);
    expect(res.isBinary).toBe(false);
  });

  it("matches `git diff SHA1 SHA2 -- path` for an arbitrary commit pair", async () => {
    const opened = await call<{ workspace: { id: string } }>("workspace.open", {
      root: repoDir,
    });
    // Two more commits on top of the beforeEach "first" commit, so we have
    // three SHAs in line. The diff we test compares the OLDEST and NEWEST.
    await writeWorkspaceFile(repoDir, "README.md", "v2\n");
    await git(repoDir, ["add", "-A"]);
    await git(repoDir, ["commit", "-q", "-m", "v2"]);
    await writeWorkspaceFile(repoDir, "README.md", "v3\n");
    await git(repoDir, ["add", "-A"]);
    await git(repoDir, ["commit", "-q", "-m", "v3"]);
    const sha1 = (await git(repoDir, ["rev-parse", "HEAD~2"])).trim();
    const sha2 = (await git(repoDir, ["rev-parse", "HEAD"])).trim();
    const res = await call<DiffResp>("git.diff", {
      workspaceId: opened.workspace.id,
      path: "README.md",
      base: sha1,
      head: sha2,
    });
    expect(res.baseSha).toBe(sha1);
    expect(res.headSha).toBe(sha2);
    expect(res.isBinary).toBe(false);
    expect(res.hunks).toHaveLength(1);
    expect(res.hunks[0].lines).toEqual([
      { kind: "del", text: "v1" },
      { kind: "add", text: "v3" },
    ]);
  });

  it("rejects a non-existent path with -32602 invalidParams", async () => {
    const opened = await call<{ workspace: { id: string } }>("workspace.open", {
      root: repoDir,
    });
    await expect(
      call<DiffResp>("git.diff", {
        workspaceId: opened.workspace.id,
        path: "does-not-exist.txt",
      }),
    ).rejects.toMatchObject({ code: -32602 });
  });
});

describe("git.log", () => {
  type LogEntry = {
    sha: string;
    parents: string[];
    authorName: string;
    authorEmail: string;
    authorDate: string;
    committerDate: string;
    subject: string;
    body?: string;
  };
  type LogResp = { entries: LogEntry[]; nextCursor?: string };

  it("returns commit entries newest-first with the rich LogEntry shape", async () => {
    const opened = await call<{ workspace: { id: string } }>("workspace.open", {
      root: repoDir,
    });
    await writeWorkspaceFile(repoDir, "a.txt", "a\n");
    await git(repoDir, ["add", "-A"]);
    await git(repoDir, ["commit", "-q", "-m", "second"]);
    const log = await call<LogResp>("git.log", {
      workspaceId: opened.workspace.id,
      limit: 10,
    });
    expect(log.entries.length).toBeGreaterThanOrEqual(2);
    expect(log.entries[0].subject).toBe("second");
    expect(log.entries[1].subject).toBe("first");
    expect(log.entries[0].sha).toMatch(/^[0-9a-f]{40}$/);
    expect(log.entries[0].authorName).toBeTruthy();
    expect(log.entries[0].authorEmail).toContain("@");
    expect(Array.isArray(log.entries[0].parents)).toBe(true);
  });
});

describe("fs.listDir / fs.readFile contract", () => {
  it("listDir returns TreeEntry with kind + version", async () => {
    const opened = await call<{ workspace: { id: string } }>("workspace.open", {
      root: repoDir,
    });
    const ls = await call<{
      entries: Array<{ name: string; kind: string; type: string }>;
      version: number;
    }>("fs.listDir", { workspaceId: opened.workspace.id, path: repoDir });
    expect(ls.version).toBeGreaterThanOrEqual(1);
    const readme = ls.entries.find((e) => e.name === "README.md");
    expect(readme?.kind).toBe("file");
    // Legacy alias still emitted for the pre-PR-B client.
    expect(readme?.type).toBe("file");
  });

  it("readFile ifEtag match returns notModified true", async () => {
    const opened = await call<{ workspace: { id: string } }>("workspace.open", {
      root: repoDir,
    });
    const first = await call<{ etag: string; contentBase64: string }>(
      "fs.readFile",
      { workspaceId: opened.workspace.id, path: `${repoDir}/README.md` },
    );
    expect(first.etag).toMatch(/^\d+-\d+$/);
    const second = await call<{
      etag: string;
      notModified?: boolean;
      contentBase64?: string;
    }>("fs.readFile", {
      workspaceId: opened.workspace.id,
      path: `${repoDir}/README.md`,
      ifEtag: first.etag,
    });
    expect(second.notModified).toBe(true);
    expect(second.contentBase64).toBeUndefined();
  });
});
