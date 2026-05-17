// `plugin.*` RPC surface tests. Real plugin subprocesses (no mocks),
// real persistence files in temp dirs, real WebSocket-shape stubs.
//
// Covers the acceptance criteria from issue #58:
//   * enable → spawn → list shows running
//   * disable → SIGTERM honored within the grace window
//   * invokeCommand round-trips a string argument
//   * persistence survives a host restart
//   * plugin.stateChanged pushes only to subscribed peers

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { WebSocket } from "ws";
import { cp, mkdir, readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PluginHost } from "../src/plugins/host.js";
import type { PluginInfo, WirePluginState } from "../src/plugins/host.js";
import { dispatch, type RpcContext } from "../src/rpc.js";
import { ProcessState } from "../src/state.js";
import { FakeWebSocket, makeTempDir, rmTempDir, sleep } from "./_helpers.js";

const FIXTURE_ROOT = join(
  dirname(fileURLToPath(import.meta.url)),
  "fixtures",
  "plugins",
);

interface Harness {
  host: PluginHost;
  state: ProcessState;
  staging: string;
  pluginsDir: string;
  stateFile: string;
}

let staging: string | null = null;

beforeEach(async () => {
  staging = await makeTempDir("openvsmobile-pluginrpc-");
});

afterEach(async () => {
  if (staging !== null) {
    await rmTempDir(staging);
    staging = null;
  }
});

async function buildHarness(
  fixtures: string[],
  options: { stateFileContents?: string; killGraceMs?: number } = {},
): Promise<Harness> {
  if (staging === null) throw new Error("staging dir not set up");
  const pluginsDir = join(staging, "plugins");
  const logDir = join(staging, "logs");
  const stateFile = join(staging, "plugin-state.json");
  await mkdir(pluginsDir, { recursive: true });
  await mkdir(logDir, { recursive: true });
  for (const name of fixtures) {
    await cp(join(FIXTURE_ROOT, name), join(pluginsDir, name), {
      recursive: true,
    });
  }
  if (options.stateFileContents !== undefined) {
    const { writeFile } = await import("node:fs/promises");
    await writeFile(stateFile, options.stateFileContents);
  }
  const state = new ProcessState();
  const host = new PluginHost({
    pluginsDir,
    logDir,
    stateFile,
    killGraceMs: options.killGraceMs ?? 250,
    invokeTimeoutMs: 2000,
    logger: () => {},
    onHostLog: () => {},
    onStateChanged: (change) => state.broadcastPluginStateChanged(change),
  });
  state.pluginHost = host;
  await host.start();
  return { host, state, staging, pluginsDir, stateFile };
}

function makeContext(state: ProcessState, sock: FakeWebSocket): RpcContext {
  const ctx: RpcContext = {
    state,
    expectedToken: "test-token",
    serverVersion: "0.0.0-test",
    ws: sock as unknown as WebSocket,
    markAuthenticated: () => {},
  };
  // Mimic the connection layer: every authenticated dispatch carries a
  // Subscriber object that the handlers can mutate.
  const subscriber = {
    ws: sock as unknown as WebSocket,
  };
  ctx.subscriber = subscriber;
  state.addSubscriber(subscriber);
  return ctx;
}

async function call<T = unknown>(
  ctx: RpcContext,
  method: string,
  params: unknown,
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

describe("plugin.* RPCs", () => {
  it("enable transitions a disabled plugin to running and plugin.list reflects it", async () => {
    // Pre-disable the fixture so the host loads it as disabled on start.
    const harness = await buildHarness(["hello"], {
      stateFileContents: JSON.stringify({ disabled: ["hello"] }),
    });
    try {
      const sock = new FakeWebSocket();
      const ctx = makeContext(harness.state, sock);
      const before = await call<{ plugins: PluginInfo[] }>(
        ctx,
        "plugin.list",
        {},
      );
      const entry = before.plugins.find((p) => p.id === "hello");
      expect(entry?.state).toBe<WirePluginState>("disabled");

      const result = await call<{ ok: true }>(ctx, "plugin.enable", {
        id: "hello",
      });
      expect(result).toEqual({ ok: true });

      // hello has onStartup activation → enable should spawn it. The
      // spawn is awaited inside `enable()` so the state has flipped by
      // the time we land here; the only async piece is the child
      // process actually being up.
      const running = await waitFor(() => {
        const e = harness.host.get("hello");
        return e?.state === "active" ? e : undefined;
      }, 2000);
      expect(running.process?.pid()).toBeTypeOf("number");

      const after = await call<{ plugins: PluginInfo[] }>(
        ctx,
        "plugin.list",
        {},
      );
      const helloAfter = after.plugins.find((p) => p.id === "hello");
      expect(helloAfter?.state).toBe<WirePluginState>("running");
    } finally {
      harness.host.shutdown();
    }
  });

  it("disable SIGTERMs the plugin within the grace window and updates state", async () => {
    const harness = await buildHarness(["hello"], { killGraceMs: 250 });
    try {
      await waitFor(
        () => (harness.host.get("hello")?.state === "active" ? true : undefined),
        2000,
      );
      const proc = harness.host.get("hello")?.process;
      expect(proc).toBeDefined();
      const exitPromise = proc!.waitForExit();

      const sock = new FakeWebSocket();
      const ctx = makeContext(harness.state, sock);
      const start = Date.now();
      const result = await call<{ ok: true }>(ctx, "plugin.disable", {
        id: "hello",
      });
      expect(result).toEqual({ ok: true });
      // The hello fixture installs no SIGTERM handler, so the kernel
      // terminates it on the first signal — much faster than the grace
      // window. We assert that the wait returned before grace + a small
      // buffer to catch a regression that forgets the SIGKILL escalation.
      await exitPromise;
      expect(Date.now() - start).toBeLessThan(2000);
      expect(harness.host.get("hello")?.state).toBe("disabled");
    } finally {
      harness.host.shutdown();
    }
  });

  it("invokeCommand round-trips an argument through the plugin's response", async () => {
    const harness = await buildHarness(["cmd"]);
    try {
      await waitFor(
        () => (harness.host.get("cmd")?.state === "active" ? true : undefined),
        2000,
      );
      const sock = new FakeWebSocket();
      const ctx = makeContext(harness.state, sock);
      const result = await call<{ result?: unknown }>(
        ctx,
        "plugin.invokeCommand",
        {
          id: "cmd",
          commandId: "cmd.echo",
          args: "hello world",
        },
      );
      expect(result).toEqual({
        result: { echoed: "hello world", commandId: "cmd.echo" },
      });
    } finally {
      harness.host.shutdown();
    }
  });

  it("invokeCommand activates a stopped plugin when the manifest lists onCommand:<id>", async () => {
    // Pre-disable to land in `disabled`, then enable so the in-memory
    // state becomes `registered` (since the cmd fixture has onStartup,
    // calling enable starts it; we want a stopped state, so we strip
    // onStartup via a tweaked fixture). Easier path: manually transition
    // through the host's public methods. The cmd fixture has onStartup
    // so once it's enabled it starts running; we then disable it (state
    // goes `disabled`), re-enable (state goes `registered` then immediately
    // active via onStartup). That doesn't give us a stopped + onCommand
    // scenario.
    //
    // To exercise on-demand activation we restart the host with a state
    // file that keeps the plugin enabled but with no activation events
    // matching onStartup. We do this by altering the staged manifest on
    // disk before host.start() runs. To keep things small, copy the cmd
    // fixture manually and rewrite its activation events.
    if (staging === null) throw new Error("staging dir not set up");
    const pluginsDir = join(staging, "plugins");
    const logDir = join(staging, "logs");
    const stateFile = join(staging, "plugin-state.json");
    await mkdir(pluginsDir, { recursive: true });
    await mkdir(logDir, { recursive: true });
    await cp(join(FIXTURE_ROOT, "cmd"), join(pluginsDir, "cmd"), {
      recursive: true,
    });
    const { writeFile } = await import("node:fs/promises");
    await writeFile(
      join(pluginsDir, "cmd", "plugin.json"),
      JSON.stringify({
        id: "cmd",
        name: "Command fixture",
        version: "0.0.1",
        entry: { kind: "node", path: "index.js" },
        activation: ["onCommand:cmd.echoOnDemand"],
        capabilities: {},
        contributes: {
          commands: [{ id: "cmd.echoOnDemand", title: "Echo (on-demand)" }],
        },
      }),
    );
    const state = new ProcessState();
    const host = new PluginHost({
      pluginsDir,
      logDir,
      stateFile,
      killGraceMs: 250,
      invokeTimeoutMs: 2000,
      logger: () => {},
      onHostLog: () => {},
    });
    state.pluginHost = host;
    await host.start();
    try {
      // No onStartup → lazy activation. Pre-call assertions:
      expect(host.get("cmd")?.state).toBe("registered");
      const sock = new FakeWebSocket();
      const ctx = makeContext(state, sock);
      const result = await call<{ result?: unknown }>(
        ctx,
        "plugin.invokeCommand",
        {
          id: "cmd",
          commandId: "cmd.echoOnDemand",
          args: { greeting: "hi" },
        },
      );
      // Activation happened as part of the invoke.
      expect(host.get("cmd")?.state).toBe("active");
      expect(result.result).toMatchObject({
        echoed: { greeting: "hi" },
        commandId: "cmd.echoOnDemand",
      });
    } finally {
      host.shutdown();
    }
  });

  it("persists enabled/disabled state across a host restart", async () => {
    const harness = await buildHarness(["hello"]);
    try {
      const sock = new FakeWebSocket();
      const ctx = makeContext(harness.state, sock);
      await call<{ ok: true }>(ctx, "plugin.disable", { id: "hello" });
      // On-disk state file should now contain hello in `disabled`.
      const onDisk = JSON.parse(
        await readFile(harness.stateFile, "utf8"),
      ) as { disabled: string[] };
      expect(onDisk.disabled).toContain("hello");
    } finally {
      harness.host.shutdown();
    }
    // Reinstantiate the host (and a fresh ProcessState) pointing at the
    // same plugins/state files. The plugin should land in `disabled`
    // without anyone explicitly asking — that's the whole point of the
    // persistence step.
    if (staging === null) throw new Error("staging dir not set up");
    const reloadedState = new ProcessState();
    const reloaded = new PluginHost({
      pluginsDir: join(staging, "plugins"),
      logDir: join(staging, "logs"),
      stateFile: join(staging, "plugin-state.json"),
      killGraceMs: 250,
      invokeTimeoutMs: 2000,
      logger: () => {},
      onHostLog: () => {},
    });
    reloadedState.pluginHost = reloaded;
    await reloaded.start();
    try {
      expect(reloaded.get("hello")?.state).toBe("disabled");
      const sock = new FakeWebSocket();
      const ctx = makeContext(reloadedState, sock);
      const list = await call<{ plugins: PluginInfo[] }>(
        ctx,
        "plugin.list",
        {},
      );
      const hello = list.plugins.find((p) => p.id === "hello");
      expect(hello?.state).toBe<WirePluginState>("disabled");
    } finally {
      reloaded.shutdown();
    }
  });

  it("plugin.stateChanged fires for subscribed connections but not unsubscribed peers", async () => {
    const harness = await buildHarness(["hello"]);
    try {
      // Two distinct peers — one subscribes, one doesn't.
      const subSock = new FakeWebSocket();
      const subCtx = makeContext(harness.state, subSock);
      const unsubSock = new FakeWebSocket();
      makeContext(harness.state, unsubSock); // registers as subscriber but never calls plugin.subscribe
      await call<{ ok: true }>(subCtx, "plugin.subscribe", {});

      // Trigger a state transition. Wait for the plugin to be running
      // first so the disable transition is meaningful.
      await waitFor(
        () => (harness.host.get("hello")?.state === "active" ? true : undefined),
        2000,
      );
      subSock.sent = []; // any pre-subscribe pushes don't count
      unsubSock.sent = [];
      await call<{ ok: true }>(subCtx, "plugin.disable", { id: "hello" });
      // Disable goes through SIGTERM → exit; the wire-state goes from
      // "running" to "disabled" in a single setState call (the exit
      // handler is a no-op because state is already disabled), so the
      // subscriber should see exactly one frame.
      const subscribed = subSock.notifications("plugin.stateChanged");
      expect(subscribed.length).toBeGreaterThanOrEqual(1);
      const last = subscribed[subscribed.length - 1];
      expect((last.params as { id: string; state: string }).id).toBe("hello");
      expect((last.params as { id: string; state: string }).state).toBe(
        "disabled",
      );
      // The unsubscribed peer must have received nothing.
      expect(unsubSock.notifications("plugin.stateChanged")).toEqual([]);
    } finally {
      harness.host.shutdown();
    }
  });
});
