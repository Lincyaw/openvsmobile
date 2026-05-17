// End-to-end coverage for the `examples/plugins/hello` reference
// plugin. Spawns the host pointing at the example directory, subscribes
// to `ui.tree`, fakes the two `ui.event`s the example responds to
// (changed → tap), and asserts the re-rendered tree contains the
// expected greeting.
//
// This doubles as the platform-end smoke test for `@openvsmobile/sdk`:
// any regression in SDK framing, ui.* constructors, or NODE_PATH
// resolution on the spawn path surfaces here.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { WebSocket } from "ws";
import { cp, mkdir } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  FakeWebSocket,
  makeTempDir,
  rmTempDir,
  sleep,
} from "./_helpers.js";
import { dispatch, type RpcContext } from "../src/rpc.js";
import { ProcessState } from "../src/state.js";
import { PluginHost } from "../src/plugins/host.js";
import type { UiPanelSnapshot } from "../src/plugins/ui.js";

const THIS_FILE_DIR = dirname(fileURLToPath(import.meta.url));
const EXAMPLE_HELLO_DIR = resolve(
  THIS_FILE_DIR,
  "..",
  "..",
  "examples",
  "plugins",
  "hello",
);

let staging: string | null = null;

beforeEach(async () => {
  staging = await makeTempDir("openvsmobile-hello-");
});

afterEach(async () => {
  if (staging !== null) {
    await rmTempDir(staging);
    staging = null;
  }
});

async function buildHarness(): Promise<{
  host: PluginHost;
  sock: FakeWebSocket;
  ctx: RpcContext;
  diagnostics: string[];
}> {
  if (staging === null) throw new Error("staging dir not set up");
  const pluginsDir = join(staging, "plugins");
  const logDir = join(staging, "logs");
  await mkdir(pluginsDir, { recursive: true });
  await mkdir(logDir, { recursive: true });
  // Stage a copy of the in-repo example so the test owns its plugin
  // dir and the host's writes (state file etc.) don't bleed into the
  // committed `examples/plugins/hello/` tree.
  await cp(EXAMPLE_HELLO_DIR, join(pluginsDir, "hello"), {
    recursive: true,
  });
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
  return { host, sock, ctx, diagnostics };
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

function findText(node: unknown, id: string): string | undefined {
  if (!node || typeof node !== "object") return undefined;
  const n = node as {
    id?: string;
    kind?: string;
    text?: string;
    children?: unknown[];
    items?: unknown[];
  };
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

describe("examples/plugins/hello end-to-end", () => {
  it(
    "renders the home panel on activation, then re-renders with the typed name after a Greet tap",
    async () => {
      const harness = await buildHarness();
      try {
        await call<{ ok: boolean }>(harness.ctx, "ui.subscribe");
        // Wait for the activation render to land. The fixture uses the
        // SDK's `renderPanel`, which serializes a Section with a Text +
        // TextField + Button — all three node ids are stable across
        // renders, so we can assert on them directly.
        const initial = await waitFor(() => {
          const pushes = harness.sock.notifications("ui.tree");
          const home = pushes.find((p) => {
            const snap = p.params as UiPanelSnapshot;
            return snap.pluginId === "hello" && snap.panelId === "home";
          });
          if (home === undefined) return undefined;
          const snap = home.params as UiPanelSnapshot;
          return snap.tree === null ? undefined : snap;
        }, 5000);
        expect(initial.pluginId).toBe("hello");
        expect(findText(initial.tree, "greeting")).toBe("Hello, stranger.");

        const versionBefore = initial.version;

        // Simulate the app: user types into the TextField.
        await call(harness.ctx, "ui.event", {
          pluginId: "hello",
          panelId: "home",
          nodeId: "name-field",
          type: "changed",
          payload: { value: "Ada" },
        });
        // Then taps Greet.
        await call(harness.ctx, "ui.event", {
          pluginId: "hello",
          panelId: "home",
          nodeId: "greet-btn",
          type: "tap",
        });

        // Expect a fresh ui.tree push with the personalised greeting.
        const updated = await waitFor(() => {
          const pushes = harness.sock.notifications("ui.tree");
          for (let i = pushes.length - 1; i >= 0; i--) {
            const snap = pushes[i].params as UiPanelSnapshot;
            if (
              snap.pluginId === "hello" &&
              snap.panelId === "home" &&
              snap.tree !== null &&
              snap.version > versionBefore
            ) {
              return snap;
            }
          }
          return undefined;
        }, 5000);
        expect(findText(updated.tree, "greeting")).toBe("Hello, Ada!");
        // Node ids stable: the TextField's id must round-trip so focus
        // and any client-side input state survive the re-render.
        const findTextField = (node: unknown, id: string): unknown => {
          if (!node || typeof node !== "object") return undefined;
          const n = node as {
            id?: string;
            kind?: string;
            children?: unknown[];
            items?: unknown[];
          };
          if (n.kind === "TextField" && n.id === id) return node;
          for (const arr of [n.children, n.items]) {
            if (!Array.isArray(arr)) continue;
            for (const c of arr) {
              const f = findTextField(c, id);
              if (f !== undefined) return f;
            }
          }
          return undefined;
        };
        expect(findTextField(updated.tree, "name-field")).toBeDefined();
      } finally {
        harness.host.shutdown();
      }
    },
  );
});
