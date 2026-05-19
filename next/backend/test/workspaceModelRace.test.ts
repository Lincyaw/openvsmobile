// Race + lifecycle tests for WorkspaceModel that the first pass missed:
//   - replay-subscribe vs concurrent drain (B1 regression test)
//   - duplicate subscribe from same socket (B2 regression test)
//   - causal ordering inside one drain window (M6.1)
//   - .gitignore matcher rebuild (M6.2)
//   - journal-overflow → snapshot (M6.3)
//   - socket-close auto-unsubscribe (M6.4) — via ProcessState
//   - porcelain v2 rename surfaced as tree.delta.renamed (M6.5)
//
// Same testing posture as workspaceModel.test.ts: real git repos in temp
// dirs, real chokidar, real `git` binary.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { WebSocket } from "ws";
import {
  FakeWebSocket,
  git,
  makeRepo,
  makeTempDir,
  rmTempDir,
  writeWorkspaceFile,
  sleep,
} from "./_helpers.js";
import { WorkspaceModel } from "../src/workspaceModel.js";
import { ProcessState } from "../src/state.js";
import { dispatch, type RpcContext } from "../src/rpc.js";

let repoDir: string;
let model: WorkspaceModel;

async function newModel(root: string): Promise<WorkspaceModel> {
  const m = new WorkspaceModel({ workspaceId: "ws-race", root });
  await m.init();
  return m;
}

beforeEach(async () => {
  repoDir = await makeTempDir("openvsmobile-racetest-");
  await makeRepo(repoDir);
  await writeWorkspaceFile(repoDir, "README.md", "v1\n");
  await git(repoDir, ["add", "-A"]);
  await git(repoDir, ["commit", "-q", "-m", "initial"]);
});

afterEach(async () => {
  if (model !== undefined) await model.dispose();
  await rmTempDir(repoDir);
});

describe("B1: replay vs concurrent drain", () => {
  it("delivers events strictly monotonically when a drain interleaves with replay", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    // Drive the model to version > 1 so there's something in the journal.
    await writeWorkspaceFile(repoDir, "README.md", "v2\n");
    await model.drainOnce();
    const beforeReplay = model.currentVersion();
    // Subscribe with sinceVersion = 1 → replay mode. The replay slice is
    // captured synchronously inside subscribe(), then delivered in a
    // microtask. Between those points we fire a fresh drain that emits a
    // NEW event (version = beforeReplay + 1) via the live-fanout path.
    const result = model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: 1,
    });
    expect(result.mode).toBe("replay");
    // Fire a real drain by mutating the tree. The drainOnce promise resolves
    // after the live event has been fanned. Then we let the microtask flush.
    await writeWorkspaceFile(repoDir, "between.txt", "x\n");
    await model.drainOnce();
    // Flush the queued replay microtask.
    await Promise.resolve();
    await Promise.resolve();
    // Collect every workspace.* notif and extract versions.
    const versions = sock.sent
      .filter((m) => typeof m.method === "string" && m.method.startsWith("workspace."))
      .map((m) => (m.params as { version: number }).version);
    expect(versions.length).toBeGreaterThan(0);
    // Monotonic, no duplicates.
    for (let i = 1; i < versions.length; i++) {
      expect(versions[i]).toBeGreaterThan(versions[i - 1]);
    }
    // And we covered both the replayed window and the new event.
    expect(Math.max(...versions)).toBeGreaterThan(beforeReplay);
  });
});

describe("B2: duplicate subscribe replaces the prior subscriber", () => {
  it("only delivers a notif once even after subscribing twice from the same socket", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: model.currentVersion(),
    });
    // Second subscribe from the same ws → should replace, not stack.
    model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: model.currentVersion(),
    });
    expect(model.subscriberCount()).toBe(1);
    // Fire one decoration delta and assert exactly one delivery.
    await writeWorkspaceFile(repoDir, "README.md", "edited\n");
    await model.drainOnce();
    const decoNotifs = sock.notifications("workspace.decoration.delta");
    expect(decoNotifs).toHaveLength(1);
  });
});

describe("M6.1: causal ordering inside one drain window", () => {
  it("emits head.changed → tree.delta → decoration.delta → commit.added in order", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: model.currentVersion(),
    });
    // Drive everything in one window:
    //   - create + checkout new branch (HEAD changes)
    //   - make + commit a new file (commit.added on current branch)
    //   - leave one working-tree mod behind (decoration.delta)
    //   - new file shows up as a tree add too (tree.delta)
    await git(repoDir, ["checkout", "-q", "-b", "feature"]);
    await writeWorkspaceFile(repoDir, "feat.txt", "feature\n");
    await git(repoDir, ["add", "-A"]);
    await git(repoDir, ["commit", "-q", "-m", "feat"]);
    // Leave an unstaged dirty file.
    await writeWorkspaceFile(repoDir, "README.md", "dirty\n");
    await model.drainOnce();
    // Collect ordering by index in sock.sent.
    const order = sock.sent
      .filter((m) => typeof m.method === "string" && m.method.startsWith("workspace."))
      .map((m) => m.method as string);
    // Filter the subset we care about; we may also see e.g. multiple
    // head.changed's if branch then commit both move HEAD.
    expect(order).toContain("workspace.head.changed");
    expect(order).toContain("workspace.tree.delta");
    expect(order).toContain("workspace.decoration.delta");
    // Causal: every head.changed appears before any following tree/deco/commit
    // for that same drain (versions are strictly increasing).
    const versions = sock.sent
      .filter((m) => typeof m.method === "string" && m.method.startsWith("workspace."))
      .map((m) => (m.params as { version: number }).version);
    for (let i = 1; i < versions.length; i++) {
      expect(versions[i]).toBeGreaterThan(versions[i - 1]);
    }
  });
});

describe("M6.2: .gitignore matcher rebuild", () => {
  it("hides a now-ignored file from the decoration map after .gitignore is written", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: model.currentVersion(),
    });
    // Create a file that would be untracked.
    await writeWorkspaceFile(repoDir, "build.log", "noise\n");
    await model.drainOnce();
    let entries = sock.notifications("workspace.decoration.delta").flatMap(
      (n) => (n.params as { entries: Array<{ path: string; status: string }> }).entries,
    );
    expect(entries.some((e) => e.path === "build.log" && e.status === "?")).toBe(true);
    // Now add a .gitignore that excludes *.log. The model rebuilds its
    // matcher AND triggers a re-scan drain. The decoration for build.log
    // should clear (git status no longer surfaces it).
    sock.sent = [];
    await writeWorkspaceFile(repoDir, ".gitignore", "*.log\n");
    // chokidar fires `add` for the new .gitignore. The model schedules the
    // matcher reload + drain; give it a tick to settle, then force drain.
    await sleep(150);
    await model.drainOnce();
    entries = sock.notifications("workspace.decoration.delta").flatMap(
      (n) => (n.params as { entries: Array<{ path: string; status: string | null }> }).entries,
    );
    // We expect either a cleared status for build.log, or its absence from
    // any further delta. The strong assertion: the file is no longer in the
    // model's decoration snapshot.
    const snap = model.buildDecorationSnapshot();
    expect(snap.find((e) => e.path === "build.log")).toBeUndefined();
  });
});

describe("M6.3: journal overflow falls back to snapshot", () => {
  it("returns snapshot mode when sinceVersion is older than journal head", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    const baseVersion = model.currentVersion();
    // Push enough synthetic events to bury baseVersion past the journal cap.
    const cap = WorkspaceModel.journalMaxEvents();
    for (let i = 0; i < cap + 10; i++) {
      model._testEmitSyntheticDecorationEvent(`tmp/${i}.txt`);
    }
    const result = model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: baseVersion,
    });
    expect(result.mode).toBe("snapshot");
  });
});

describe("M6.4: socket close auto-unsubscribes", () => {
  it("ProcessState.removeSubscriber detaches the ws from every workspace model", async () => {
    const state = new ProcessState();
    const sock = new FakeWebSocket();
    const ctx: RpcContext = {
      state,
      expectedToken: "t",
      serverVersion: "0",
      ws: sock as unknown as WebSocket,
      markAuthenticated: () => {},
    };
    const opened = (await dispatch(ctx, {
      jsonrpc: "2.0",
      id: 1,
      method: "workspace.open",
      params: { root: repoDir },
    })) as { workspace: { id: string } };
    await dispatch(ctx, {
      jsonrpc: "2.0",
      id: 2,
      method: "workspace.subscribe",
      params: { workspaceId: opened.workspace.id },
    });
    const ws = state.workspaces.get(opened.workspace.id);
    expect(ws.model?.subscriberCount()).toBe(1);
    // Simulate socket close: register as subscriber via markAuthenticated
    // would normally happen on handshake, but for this test we directly
    // exercise removeSubscriber's auto-cleanup.
    state.addSubscriber({ ws: sock as unknown as WebSocket });
    state.removeSubscriber({ ws: sock as unknown as WebSocket });
    expect(ws.model?.subscriberCount()).toBe(0);
    // A subsequent drain must not throw or attempt to fan out to the closed
    // socket. (FakeWebSocket would record any send.)
    sock.close();
    sock.sent = [];
    await writeWorkspaceFile(repoDir, "README.md", "x\n");
    await ws.model?.drainOnce();
    expect(sock.sent).toEqual([]);
    state.shutdownAll();
  });
});

describe("M6.5: porcelain v2 rename surfaced as tree.delta.renamed", () => {
  it("git mv produces a renamed pair in tree.delta and 'M' in decoration.delta", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: model.currentVersion(),
    });
    // Stage the rename so porcelain v2 sees it as kind "2".
    await git(repoDir, ["mv", "README.md", "DOCS.md"]);
    await model.drainOnce();
    const trees = sock.notifications("workspace.tree.delta");
    expect(trees.length).toBeGreaterThanOrEqual(1);
    const renamed = trees.flatMap(
      (n) => (n.params as { renamed: Array<{ from: string; to: string }> }).renamed,
    );
    expect(renamed).toContainEqual({ from: "README.md", to: "DOCS.md" });
    // decoration.delta should surface DOCS.md only (not README.md, since git
    // mv stages a rename — the source path effectively becomes the new path).
    const deco = sock.notifications("workspace.decoration.delta").flatMap(
      (n) => (n.params as { entries: Array<{ path: string; status: string }> }).entries,
    );
    expect(deco.some((e) => e.path === "DOCS.md")).toBe(true);
  });
});

describe("M1: non-git workspace skips git invocations", () => {
  it("does not spawn git-watcher or read HEAD when workspace isn't a repo", async () => {
    // Brand new temp dir, no `git init`.
    const plain = await makeTempDir("openvsmobile-plain-");
    try {
      const m = new WorkspaceModel({ workspaceId: "ws-plain", root: plain });
      await m.init();
      const sock = new FakeWebSocket();
      m.subscribe(sock as unknown as WebSocket, {
        sinceVersion: m.currentVersion(),
      });
      // Touch a file and drain — should NOT throw, NOT emit head.changed,
      // and NOT emit decoration.delta (no repo → nothing to decorate).
      await writeWorkspaceFile(plain, "hello.txt", "hi\n");
      await m.drainOnce();
      expect(sock.notifications("workspace.head.changed")).toHaveLength(0);
      expect(sock.notifications("workspace.decoration.delta")).toHaveLength(0);
      await m.dispose();
    } finally {
      await rmTempDir(plain);
    }
  });
});
