// Integration tests for WorkspaceModel against a real on-disk git repo.
// No mocks — chokidar watches the temp dir, the git CLI is the real one.
//
// We do not rely on chokidar firing on the host's clock; the model exposes
// `drainOnce()` so we can force a drain after each filesystem change.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  FakeWebSocket,
  git,
  makeRepo,
  makeTempDir,
  rmTempDir,
  writeWorkspaceFile,
} from "./_helpers.js";
import type { WebSocket } from "ws";
import { WorkspaceModel } from "../src/workspaceModel.js";

let repoDir: string;
let model: WorkspaceModel;

async function newModel(root: string): Promise<WorkspaceModel> {
  const m = new WorkspaceModel({ workspaceId: "ws-test", root });
  await m.init();
  return m;
}

beforeEach(async () => {
  repoDir = await makeTempDir("openvsmobile-modeltest-");
  await makeRepo(repoDir);
  await writeWorkspaceFile(repoDir, "README.md", "hello\n");
  await git(repoDir, ["add", "-A"]);
  await git(repoDir, ["commit", "-q", "-m", "initial"]);
});

afterEach(async () => {
  if (model !== undefined) await model.dispose();
  await rmTempDir(repoDir);
});

describe("WorkspaceModel subscription modes", () => {
  it("returns current when sinceVersion matches", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    const result = model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: model.currentVersion(),
    });
    expect(result.mode).toBe("current");
    expect(result.baseVersion).toBe(model.currentVersion());
  });

  it("returns snapshot when no sinceVersion provided", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    const result = model.subscribe(sock as unknown as WebSocket, {});
    expect(result.mode).toBe("snapshot");
  });

  it("returns replay when sinceVersion is one behind", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    // Make a change and drain to bump the version.
    await writeWorkspaceFile(repoDir, "new.txt", "hi\n");
    await model.drainOnce();
    const versionAfter = model.currentVersion();
    expect(versionAfter).toBeGreaterThan(1);
    // Subscribe with the pre-change version → replay.
    const result = model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: 1,
    });
    expect(result.mode).toBe("replay");
    // Allow microtasks to flush.
    await Promise.resolve();
    await Promise.resolve();
    const decoNotifs = sock.notifications("workspace.decoration.delta");
    expect(decoNotifs.length).toBeGreaterThanOrEqual(1);
  });

  it("returns snapshot when sinceVersion is from the future", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    const result = model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: 9999,
    });
    expect(result.mode).toBe("snapshot");
  });
});

describe("WorkspaceModel drain emits decoration deltas", () => {
  it("emits decoration.delta on file modify", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: model.currentVersion(),
    });
    await writeWorkspaceFile(repoDir, "README.md", "modified\n");
    await model.drainOnce();
    const deltas = sock.notifications("workspace.decoration.delta");
    expect(deltas.length).toBeGreaterThanOrEqual(1);
    const entries = (deltas[0].params as { entries: Array<{ path: string; status: string }> }).entries;
    expect(entries.some((e) => e.path === "README.md" && e.status === "M")).toBe(true);
  });

  it("emits decoration.delta with '?' for an untracked file", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: model.currentVersion(),
    });
    await writeWorkspaceFile(repoDir, "untracked.txt", "new file\n");
    await model.drainOnce();
    const deltas = sock.notifications("workspace.decoration.delta");
    const entries = deltas.flatMap(
      (d) => (d.params as { entries: Array<{ path: string; status: string }> }).entries,
    );
    expect(entries.some((e) => e.path === "untracked.txt" && e.status === "?")).toBe(true);
  });

  it("emits null status to clear a previously-modified file", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: model.currentVersion(),
    });
    // Modify, drain → expect "M".
    await writeWorkspaceFile(repoDir, "README.md", "edited\n");
    await model.drainOnce();
    // Revert via git checkout to clear.
    await git(repoDir, ["checkout", "--", "README.md"]);
    await model.drainOnce();
    const deltas = sock.notifications("workspace.decoration.delta");
    const entries = deltas.flatMap(
      (d) => (d.params as { entries: Array<{ path: string; status: string | null }> }).entries,
    );
    expect(entries.some((e) => e.path === "README.md" && e.status === null)).toBe(true);
  });

  it("emits decoration.delta with 'D' when a tracked file is deleted", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: model.currentVersion(),
    });
    await rmTempDir(`${repoDir}/README.md`);
    await model.drainOnce();
    const deltas = sock.notifications("workspace.decoration.delta");
    const entries = deltas.flatMap(
      (d) => (d.params as { entries: Array<{ path: string; status: string }> }).entries,
    );
    expect(entries.some((e) => e.path === "README.md" && e.status === "D")).toBe(true);
  });
});

describe("WorkspaceModel head.changed", () => {
  it("emits head.changed on branch switch", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: model.currentVersion(),
    });
    await git(repoDir, ["checkout", "-q", "-b", "feature"]);
    await model.drainOnce();
    const heads = sock.notifications("workspace.head.changed");
    expect(heads.length).toBeGreaterThanOrEqual(1);
    expect((heads[0].params as { branch: string }).branch).toBe("feature");
  });
});

describe("WorkspaceModel path-scoped subscription", () => {
  it("filters decoration deltas to subscribed path prefix", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    // Subscribe with a path filter limited to "src/".
    model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: model.currentVersion(),
      paths: ["src"],
    });
    // Write a file outside the scope — should not be delivered.
    await writeWorkspaceFile(repoDir, "outside.txt", "noise\n");
    await model.drainOnce();
    // Write a file inside the scope — must be delivered.
    await writeWorkspaceFile(repoDir, "src/in-scope.ts", "ok\n");
    await model.drainOnce();

    const deltas = sock.notifications("workspace.decoration.delta");
    const entries = deltas.flatMap(
      (d) =>
        (d.params as { entries: Array<{ path: string }> }).entries,
    );
    // The in-scope file shows up.
    expect(entries.some((e) => e.path === "src/in-scope.ts")).toBe(true);
    // The out-of-scope file is filtered out.
    expect(entries.some((e) => e.path === "outside.txt")).toBe(false);
  });

  it("always delivers head.changed (path-less events bypass scope)", async () => {
    model = await newModel(repoDir);
    const sock = new FakeWebSocket();
    model.subscribe(sock as unknown as WebSocket, {
      sinceVersion: model.currentVersion(),
      paths: ["src"],
    });
    await git(repoDir, ["checkout", "-q", "-b", "feature"]);
    await model.drainOnce();
    const heads = sock.notifications("workspace.head.changed");
    expect(heads.length).toBeGreaterThanOrEqual(1);
  });
});

describe("WorkspaceModel decoration snapshot", () => {
  it("buildDecorationSnapshot lists non-clean files only", async () => {
    model = await newModel(repoDir);
    // Make one dirty file.
    await writeWorkspaceFile(repoDir, "dirty.txt", "x\n");
    await model.drainOnce();
    const snap = model.buildDecorationSnapshot();
    expect(snap.length).toBeGreaterThanOrEqual(1);
    expect(snap.find((e) => e.path === "dirty.txt")?.status).toBe("?");
    expect(snap.find((e) => e.path === "README.md")).toBeUndefined();
  });
});
