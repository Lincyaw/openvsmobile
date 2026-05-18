// Registry-level coverage for the workspace.activated trigger added in
// the Phase-0 SDK workspace surface. The host-side fan-out is already
// covered in pluginHost.test.ts; this file pins the *call-site* logic
// in WorkspaceRegistry — i.e. that fireActivatedIfChanged is invoked
// exactly once per real transition, suppressed on no-op transitions,
// and never invoked from detachAllForShutdown.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { makeRepo, makeTempDir, rmTempDir } from "./_helpers.js";
import { WorkspaceRegistry, type ActiveWorkspace } from "../src/workspace.js";

const noop: () => void = () => undefined;

function newRegistry(): WorkspaceRegistry {
  return new WorkspaceRegistry(noop, noop, { kind: "none" }, null);
}

let repoA: string;
let repoB: string;

beforeEach(async () => {
  repoA = await makeTempDir("openvsmobile-regtest-a-");
  repoB = await makeTempDir("openvsmobile-regtest-b-");
  await makeRepo(repoA);
  await makeRepo(repoB);
});

afterEach(async () => {
  await rmTempDir(repoA);
  await rmTempDir(repoB);
});

describe("WorkspaceRegistry activated-hook", () => {
  it("fires once per real transition; suppresses no-op activate", async () => {
    const registry = newRegistry();
    const hook = vi.fn<(ws: ActiveWorkspace | null) => void>();
    registry.setActivatedHook(hook);

    // open(repoA) with default activate=true → currentId null → ws-A.
    const wsA = await registry.open(repoA);
    expect(hook).toHaveBeenCalledTimes(1);
    expect(hook.mock.calls[0]?.[0]?.id).toBe(wsA.id);

    // open(repoB) → currentId ws-A → ws-B.
    const wsB = await registry.open(repoB);
    expect(hook).toHaveBeenCalledTimes(2);
    expect(hook.mock.calls[1]?.[0]?.id).toBe(wsB.id);

    // activate(ws-A) → ws-B → ws-A; fires.
    registry.activate(wsA.id);
    expect(hook).toHaveBeenCalledTimes(3);
    expect(hook.mock.calls[2]?.[0]?.id).toBe(wsA.id);

    // activate(ws-A) again — already current; suppressed.
    registry.activate(wsA.id);
    expect(hook).toHaveBeenCalledTimes(3);

    registry.disposeAll();
  });

  it("close(currentId) fires; close(non-current) does not", async () => {
    const registry = newRegistry();
    const hook = vi.fn<(ws: ActiveWorkspace | null) => void>();
    registry.setActivatedHook(hook);

    const wsA = await registry.open(repoA);
    const wsB = await registry.open(repoB); // becomes current
    hook.mockClear();

    // Close the non-current one → no transition.
    registry.close(wsA.id);
    expect(hook).not.toHaveBeenCalled();

    // Close the current one → currentId flips (here: to null since
    // nothing left). Hook fires with null payload.
    registry.close(wsB.id);
    expect(hook).toHaveBeenCalledTimes(1);
    expect(hook.mock.calls[0]?.[0]).toBeNull();
  });

  it("disposeAll fires when workspaces existed; suppresses when already empty", async () => {
    const registry = newRegistry();
    const hook = vi.fn<(ws: ActiveWorkspace | null) => void>();
    registry.setActivatedHook(hook);

    // disposeAll on a fresh registry — currentId already null, no
    // transition.
    registry.disposeAll();
    expect(hook).not.toHaveBeenCalled();

    await registry.open(repoA);
    hook.mockClear();

    registry.disposeAll();
    expect(hook).toHaveBeenCalledTimes(1);
    expect(hook.mock.calls[0]?.[0]).toBeNull();
  });

  it("detachAllForShutdown does NOT fire the activated hook", async () => {
    // Process-shutdown path: plugins are tearing down alongside, so a
    // last-gasp workspace.activated(null) push would be noise at best
    // and a race-with-stdin-close at worst.
    const registry = newRegistry();
    const hook = vi.fn<(ws: ActiveWorkspace | null) => void>();
    registry.setActivatedHook(hook);

    await registry.open(repoA);
    hook.mockClear();

    registry.detachAllForShutdown();
    expect(hook).not.toHaveBeenCalled();
  });
});
