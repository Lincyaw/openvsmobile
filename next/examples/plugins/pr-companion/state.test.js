// Unit tests for state.js — drives the load / save round-trip against a
// real temp directory (no fs mocks; conventions §6). The state module
// resolves its paths from `os.homedir()` at module load, so each test
// redirects HOME to a private tmp dir and dynamically re-imports the
// module — that way the test owns the entire fs surface and never
// touches the developer's actual `~/.openvsmobile/pr-companion`.

import { mkdtemp, readFile, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/** @type {string} */
let HOME;
/** @type {string} */
let prevHome;
/** @type {Awaited<ReturnType<typeof import("./state.js")>>} */
// eslint-disable-next-line no-unused-vars
let stateMod;

async function loadModule() {
  // Bypass the module-graph cache by adding a unique query string; we
  // need a fresh evaluation per test so the path constants reflect the
  // freshly-set HOME.
  const url = new URL("./state.js", import.meta.url);
  url.searchParams.set("t", String(Math.random()));
  return import(url.href);
}

beforeEach(async () => {
  prevHome = process.env.HOME ?? "";
  HOME = await mkdtemp(join(tmpdir(), "prcomp-state-"));
  process.env.HOME = HOME;
});

afterEach(async () => {
  process.env.HOME = prevHome;
  // Best-effort cleanup; ignore failure since the OS will reap /tmp
  // eventually anyway.
  await rm(HOME, { recursive: true, force: true }).catch(() => {});
  vi.restoreAllMocks();
});

describe("defaultState", () => {
  it("returns an empty, well-shaped state", async () => {
    const mod = await loadModule();
    const s = mod.defaultState();
    expect(s).toEqual({
      dismissedIds: [],
      lastSeenAt: null,
      scopeByWorkspace: {},
    });
    // Each call returns a fresh object — mutations don't leak.
    s.dismissedIds.push("x");
    expect(mod.defaultState().dismissedIds).toEqual([]);
  });
});

describe("loadState", () => {
  it("returns defaults when the file does not exist", async () => {
    const mod = await loadModule();
    const s = await mod.loadState();
    expect(s).toEqual(mod.defaultState());
  });

  it("normalizes a partial / malformed file without throwing", async () => {
    const mod = await loadModule();
    await mkdir(join(HOME, ".openvsmobile", "pr-companion"), {
      recursive: true,
    });
    // Half-shaped on purpose: missing dismissedIds, garbage scope, an
    // invalid lastSeenAt type, plus a bogus enum value in scopeByWorkspace.
    await writeFile(
      join(HOME, ".openvsmobile", "pr-companion", "state.json"),
      JSON.stringify({
        dismissedIds: ["a", 42, null, "b"],
        lastSeenAt: 123,
        scopeByWorkspace: { ws1: "thisRepo", ws2: "bogus", ws3: 9 },
      }),
      "utf8",
    );
    const s = await mod.loadState();
    expect(s.dismissedIds).toEqual(["a", "b"]);
    expect(s.lastSeenAt).toBeNull();
    expect(s.scopeByWorkspace).toEqual({ ws1: "thisRepo" });
  });

  it("returns defaults on invalid JSON and logs via ctx", async () => {
    const mod = await loadModule();
    await mkdir(join(HOME, ".openvsmobile", "pr-companion"), {
      recursive: true,
    });
    await writeFile(
      join(HOME, ".openvsmobile", "pr-companion", "state.json"),
      "{not json",
      "utf8",
    );
    const log = vi.fn();
    const s = await mod.loadState({ log });
    expect(s).toEqual(mod.defaultState());
    expect(log).toHaveBeenCalledWith(
      "warn",
      expect.stringContaining("not valid JSON"),
    );
  });
});

describe("saveState", () => {
  it("writes the JSON and round-trips through loadState", async () => {
    const mod = await loadModule();
    /** @type {import("./state.js").PersistedState} */
    const s = {
      dismissedIds: ["x", "y"],
      lastSeenAt: "2026-05-18T00:00:00Z",
      scopeByWorkspace: { ws1: "allRepos" },
    };
    await mod.saveState(s);

    const onDisk = await readFile(
      join(HOME, ".openvsmobile", "pr-companion", "state.json"),
      "utf8",
    );
    expect(JSON.parse(onDisk)).toEqual(s);

    const reloaded = await mod.loadState();
    expect(reloaded).toEqual(s);
  });

  it("creates the parent directory when missing", async () => {
    const mod = await loadModule();
    // The temp HOME is empty; saveState must mkdir -p on the way.
    await mod.saveState(mod.defaultState());
    const onDisk = await readFile(
      join(HOME, ".openvsmobile", "pr-companion", "state.json"),
      "utf8",
    );
    expect(JSON.parse(onDisk)).toEqual(mod.defaultState());
  });

  it("logs and swallows on failure rather than throwing", async () => {
    const mod = await loadModule();
    // Point HOME at a regular file so mkdir → ENOTDIR. The save must
    // not propagate; the plugin would otherwise die on a transient
    // disk error, which is exactly what the spec forbids.
    process.env.HOME = join(HOME, "not-a-dir");
    await writeFile(process.env.HOME, "x", "utf8");
    const mod2 = await loadModule();
    const log = vi.fn();
    await expect(
      mod2.saveState(mod2.defaultState(), { log }),
    ).resolves.toBeUndefined();
    expect(log).toHaveBeenCalled();
  });
});
