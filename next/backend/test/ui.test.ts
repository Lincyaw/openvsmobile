// UI descriptor protocol tests (issue #59 / design §4.3).
//
// Covers three responsibilities:
//   * Validation:    `ui.render` with duplicate node ids → -32602 invalidParams.
//   * Fan-out:       3 plugin-emitted `ui.render` calls → 3 `ui.tree` pushes
//                    with strictly monotonic per-panel versions; subscribe-
//                    after-renders replays the current panel snapshot.
//   * Event routing: app→backend `ui.event` reaches the owning plugin and
//                    carries the same payload.
//   * Lifecycle:     plugin exit emits `ui.tree { tree: null }` for every
//                    panel the plugin had registered.
//
// Patterned after rpc.test.ts (synthetic RpcContext + FakeWebSocket) and
// pluginHost.test.ts (real child processes for the plugin side).

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { WebSocket } from "ws";
import { cp, mkdir, readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  FakeWebSocket,
  makeTempDir,
  rmTempDir,
  sleep,
} from "./_helpers.js";
import { dispatch, RpcError, type RpcContext } from "../src/rpc.js";
import { ProcessState } from "../src/state.js";
import { PluginHost } from "../src/plugins/host.js";
import {
  UiPanelRegistry,
  UiValidationError,
  validateUiTree,
  type UiPanelSnapshot,
} from "../src/plugins/ui.js";

const FIXTURE_ROOT = join(
  dirname(fileURLToPath(import.meta.url)),
  "fixtures",
  "plugins",
);

interface Harness {
  host: PluginHost;
  state: ProcessState;
  sock: FakeWebSocket;
  ctx: RpcContext;
  logDir: string;
  diagnostics: string[];
}

let staging: string | null = null;

beforeEach(async () => {
  staging = await makeTempDir("openvsmobile-uitest-");
});

afterEach(async () => {
  if (staging !== null) {
    await rmTempDir(staging);
    staging = null;
  }
});

async function buildHarness(fixtures: string[]): Promise<Harness> {
  if (staging === null) throw new Error("staging dir not set up");
  const pluginsDir = join(staging, "plugins");
  const logDir = join(staging, "logs");
  await mkdir(pluginsDir, { recursive: true });
  await mkdir(logDir, { recursive: true });
  for (const name of fixtures) {
    await cp(join(FIXTURE_ROOT, name), join(pluginsDir, name), {
      recursive: true,
    });
  }
  const diagnostics: string[] = [];
  const host = new PluginHost({
    pluginsDir,
    logDir,
    logger: (line) => diagnostics.push(line),
    onHostLog: () => {},
  });
  const state = new ProcessState({ pluginHost: host });
  const sock = new FakeWebSocket();
  const ctx: RpcContext = {
    state,
    expectedToken: "test-token",
    serverVersion: "0.0.0-test",
    ws: sock as unknown as WebSocket,
    markAuthenticated: () => {},
  };
  await host.start();
  return { host, state, sock, ctx, logDir, diagnostics };
}

async function call<T = unknown>(
  ctx: RpcContext,
  method: string,
  params: unknown = {},
): Promise<T> {
  return (await dispatch(ctx, {
    jsonrpc: "2.0",
    id: 1,
    method,
    params,
  })) as T;
}

async function waitFor<T>(
  predicate: () => T | undefined | Promise<T | undefined>,
  budgetMs: number,
  stepMs = 25,
): Promise<T> {
  const deadline = Date.now() + budgetMs;
  while (Date.now() < deadline) {
    const v = await predicate();
    if (v !== undefined) return v;
    await sleep(stepMs);
  }
  const v = await predicate();
  if (v !== undefined) return v;
  throw new Error(`waitFor timed out after ${budgetMs}ms`);
}

describe("validateUiTree", () => {
  it("accepts a well-formed tree", () => {
    const tree = validateUiTree({
      kind: "Column",
      id: "root",
      gap: 8,
      children: [
        { kind: "Text", id: "t1", text: "hi" },
        { kind: "Spacer", id: "sp", size: 16 },
        { kind: "Button", id: "b1", label: "Go", style: "primary" },
      ],
    });
    expect(tree.kind).toBe("Column");
    if (tree.kind !== "Column") throw new Error("unreachable");
    expect(tree.children).toHaveLength(3);
  });

  it("rejects duplicate ids across the tree", () => {
    expect(() =>
      validateUiTree({
        kind: "Column",
        id: "root",
        children: [
          { kind: "Text", id: "x", text: "first" },
          {
            kind: "Section",
            id: "sec",
            children: [
              { kind: "Text", id: "x", text: "second" },
            ],
          },
        ],
      }),
    ).toThrow(UiValidationError);
  });

  it("rejects an unknown kind", () => {
    expect(() =>
      validateUiTree({ kind: "Frobnicate", id: "n" }),
    ).toThrow(/unknown node kind/);
  });

  it("rejects a missing id", () => {
    expect(() =>
      validateUiTree({ kind: "Text", text: "no id" }),
    ).toThrow(/id must be a non-empty string/);
  });

  it("rejects an invalid Button style", () => {
    expect(() =>
      validateUiTree({
        kind: "Button",
        id: "btn",
        label: "Click",
        style: "warning",
      }),
    ).toThrow(/style/);
  });
});

describe("UiPanelRegistry", () => {
  function makeReg(): {
    reg: UiPanelRegistry;
    pushes: Array<{ ws: WebSocket; method: string; params: unknown }>;
  } {
    const pushes: Array<{ ws: WebSocket; method: string; params: unknown }> = [];
    const reg = new UiPanelRegistry((ws, method, params) =>
      pushes.push({ ws, method, params }),
    );
    return { reg, pushes };
  }

  it("emits monotonic per-panel versions on repeated render", () => {
    const { reg, pushes } = makeReg();
    const sock = new FakeWebSocket() as unknown as WebSocket;
    reg.subscribe(sock);
    reg.render("p1", "home", { kind: "Text", id: "t", text: "a" });
    reg.render("p1", "home", { kind: "Text", id: "t", text: "b" });
    reg.render("p1", "home", { kind: "Text", id: "t", text: "c" });
    expect(pushes).toHaveLength(3);
    const versions = pushes.map(
      (p) => (p.params as UiPanelSnapshot).version,
    );
    expect(versions).toEqual([1, 2, 3]);
  });

  it("retirePlugin emits one tree:null push per panel and drops them", () => {
    const { reg, pushes } = makeReg();
    const sock = new FakeWebSocket() as unknown as WebSocket;
    reg.subscribe(sock);
    reg.render("p1", "home", { kind: "Text", id: "t", text: "a" });
    reg.render("p1", "settings", { kind: "Text", id: "t2", text: "b" });
    reg.render("other", "home", { kind: "Text", id: "t3", text: "x" });
    pushes.length = 0;
    const retired = reg.retirePlugin("p1");
    expect(retired).toHaveLength(2);
    for (const snap of retired) {
      expect(snap.tree).toBeNull();
      expect(snap.pluginId).toBe("p1");
    }
    // Other plugin's panels untouched, still active.
    expect(
      reg.activePanels().map((p) => `${p.pluginId}/${p.panelId}`),
    ).toEqual(["other/home"]);
    expect(pushes).toHaveLength(2);
    // Re-render under the same panelId after retirement → fresh version
    // must be strictly larger than the retire-push's version (monotonic
    // contract for any client that observed both).
    const lastRetired = retired[retired.length - 1].version;
    const fresh = reg.render("p1", "settings", {
      kind: "Text",
      id: "t2",
      text: "again",
    });
    expect(fresh.version).toBeGreaterThan(lastRetired);
  });
});

describe("ui.render dispatch (validation)", () => {
  it("returns -32602 to a plugin that emits a tree with duplicate ids", async () => {
    const harness = await buildHarness(["uibadid"]);
    try {
      // The fixture echoes the host's response onto stderr wrapped in
      // <<RESP>>…<<END>>. Tail the captured log until that lands, then
      // assert the JSON-RPC error code.
      const logPath = join(harness.logDir, "uibadid.stderr.log");
      const respLine = await waitFor(async () => {
        let raw: string;
        try {
          raw = await readFile(logPath, "utf8");
        } catch {
          return undefined;
        }
        const m = /<<RESP>>(.*?)<<END>>/s.exec(raw);
        return m?.[1];
      }, 3000);
      const resp = JSON.parse(respLine) as {
        id: number;
        error?: { code: number; message: string };
      };
      expect(resp.id).toBe(42);
      expect(resp.error).toBeDefined();
      expect(resp.error?.code).toBe(-32602);
      expect(resp.error?.message).toMatch(/duplicate node id/);
      // The duplicate-id panel must never have been registered.
      expect(harness.host.ui.activePanels()).toEqual([]);
    } finally {
      harness.host.shutdown();
    }
  });
});

describe("ui.subscribe + plugin-driven ui.render fan-out", () => {
  it("delivers 3 monotonic pushes for 3 plugin-emitted ui.render calls", async () => {
    const harness = await buildHarness(["uiemitter"]);
    try {
      // Subscribe FIRST (the harness socket joins the fan-out group). The
      // emitter fixture races to render on startup, so we have to wait
      // long enough for the host to receive + register all three trees
      // even if our subscribe lost the race for the very first one.
      const subRes = await call<{ ok: boolean }>(harness.ctx, "ui.subscribe");
      expect(subRes.ok).toBe(true);
      // The subscribe response is followed by a microtask-deferred
      // snapshot replay of currently-active panels — if any plugin
      // render already landed before subscribe, we get its snapshot now;
      // future pushes layer on top. Either way the LAST `ui.tree` we
      // observe must carry version 3 and the "third"-leaf text.
      const last = await waitFor(() => {
        const pushes = harness.sock.notifications("ui.tree");
        if (pushes.length === 0) return undefined;
        const tail = pushes[pushes.length - 1].params as UiPanelSnapshot;
        if (tail.version < 3) return undefined;
        return tail;
      }, 3000);
      expect(last.pluginId).toBe("uiemitter");
      expect(last.panelId).toBe("home");
      expect(last.tree).not.toBeNull();
      // The fixture mutates only the Text leaf between renders; assert the
      // current panel snapshot reflects the third render's label.
      const text = findText(last.tree!, "root-text");
      expect(text).toBe("third");
      // Versions across the captured push stream must be strictly increasing.
      const versions = harness.sock
        .notifications("ui.tree")
        .map((p) => (p.params as UiPanelSnapshot).version);
      for (let i = 1; i < versions.length; i++) {
        expect(versions[i]).toBeGreaterThan(versions[i - 1]);
      }
    } finally {
      harness.host.shutdown();
    }
  });

  it("re-subscribing replays the current snapshot for active panels", async () => {
    const harness = await buildHarness(["uiemitter"]);
    try {
      // Wait until the host has all three renders applied. We assert on
      // the registry's view, which doesn't need a live subscriber.
      const snap = await waitFor(() => {
        const panels = harness.host.ui.activePanels();
        const home = panels.find((p) => p.panelId === "home");
        if (home === undefined || home.version < 3) return undefined;
        return home;
      }, 3000);
      expect(snap.version).toBe(3);
      // Now subscribe a fresh socket; the replay path should send one
      // ui.tree with the snapshot.
      const sock = new FakeWebSocket();
      const ctx: RpcContext = {
        ...harness.ctx,
        ws: sock as unknown as WebSocket,
      };
      await call<{ ok: boolean }>(ctx, "ui.subscribe");
      // Microtask flush.
      await Promise.resolve();
      await Promise.resolve();
      const pushes = sock.notifications("ui.tree");
      expect(pushes.length).toBe(1);
      const replay = pushes[0].params as UiPanelSnapshot;
      expect(replay.version).toBe(3);
      expect(findText(replay.tree!, "root-text")).toBe("third");
    } finally {
      harness.host.shutdown();
    }
  });
});

describe("ui.event round-trip", () => {
  it("forwards an app→backend ui.event into the owning plugin", async () => {
    const harness = await buildHarness(["uiemitter"]);
    try {
      // Wait until the fixture has emitted at least one tree — the
      // plugin's first stdout byte is what flips the host's FrameCodec
      // out of "unknown" / LSP into "newline" mode. Sending ui.event
      // before then would frame the payload as LSP and the fixture
      // (a bare newline parser) would never see it.
      await waitFor(() => {
        const panels = harness.host.ui.activePanels();
        return panels.length > 0 ? panels : undefined;
      }, 3000);
      // Send a synthetic tap.
      await call(harness.ctx, "ui.event", {
        pluginId: "uiemitter",
        panelId: "home",
        nodeId: "submit-btn",
        type: "tap",
        payload: { from: "test" },
      });
      // Fixture surfaces the inbound event via stderr markers. Wait for
      // the marker line to land in the captured log.
      const logPath = join(harness.logDir, "uiemitter.stderr.log");
      const eventJson = await waitFor(async () => {
        let raw: string;
        try {
          raw = await readFile(logPath, "utf8");
        } catch {
          return undefined;
        }
        const m = /<<UIEVT>>(.*?)<<END>>/s.exec(raw);
        return m?.[1];
      }, 3000);
      const evt = JSON.parse(eventJson) as {
        pluginId: string;
        panelId: string;
        nodeId: string;
        type: string;
        payload?: unknown;
      };
      expect(evt.pluginId).toBe("uiemitter");
      expect(evt.panelId).toBe("home");
      expect(evt.nodeId).toBe("submit-btn");
      expect(evt.type).toBe("tap");
      expect(evt.payload).toEqual({ from: "test" });
    } finally {
      harness.host.shutdown();
    }
  });

  it("rejects ui.event with -32602 for an unknown plugin", async () => {
    const harness = await buildHarness([]);
    try {
      await expect(
        call(harness.ctx, "ui.event", {
          pluginId: "no-such-plugin",
          panelId: "home",
          nodeId: "n",
          type: "tap",
        }),
      ).rejects.toBeInstanceOf(RpcError);
    } finally {
      harness.host.shutdown();
    }
  });
});

describe("plugin exit lifecycle", () => {
  it("emits ui.tree { tree: null } for every panel when a plugin's process exits", async () => {
    const harness = await buildHarness(["uiemitter"]);
    try {
      await call(harness.ctx, "ui.subscribe");
      await waitFor(() => {
        const panels = harness.host.ui.activePanels();
        const home = panels.find((p) => p.panelId === "home");
        return home !== undefined && home.version >= 3 ? home : undefined;
      }, 3000);
      const beforeKills = harness.sock.notifications("ui.tree").length;
      // Kill the plugin process; `handlePluginExit` retires the panel.
      const entry = harness.host.get("uiemitter");
      expect(entry?.state).toBe("active");
      entry?.process?.kill();
      const retirementPush = await waitFor(() => {
        const pushes = harness.sock.notifications("ui.tree");
        for (let i = beforeKills; i < pushes.length; i++) {
          const snap = pushes[i].params as UiPanelSnapshot;
          if (snap.tree === null && snap.panelId === "home") return snap;
        }
        return undefined;
      }, 3000);
      expect(retirementPush.pluginId).toBe("uiemitter");
      expect(retirementPush.tree).toBeNull();
      expect(retirementPush.version).toBeGreaterThan(3);
      // After retirement the registry no longer lists the panel.
      expect(harness.host.ui.activePanels()).toEqual([]);
    } finally {
      harness.host.shutdown();
    }
  });
});

function findText(node: unknown, id: string): string | undefined {
  if (!node || typeof node !== "object") return undefined;
  const n = node as { id?: string; kind?: string; text?: string;
    children?: unknown[]; items?: unknown[] };
  if (n.kind === "Text" && n.id === id && typeof n.text === "string") {
    return n.text;
  }
  for (const arr of [n.children, n.items]) {
    if (!Array.isArray(arr)) continue;
    for (const c of arr) {
      const found = findText(c, id);
      if (found !== undefined) return found;
    }
  }
  return undefined;
}
