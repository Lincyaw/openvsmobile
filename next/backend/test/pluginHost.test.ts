// End-to-end host tests: real child processes, real stdio JSON-RPC, real
// stderr log files. Fixtures live in test/fixtures/plugins/<id>/ and get
// staged into per-test temp dirs so one test's plugins don't bleed into
// another.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  PluginHost,
  type HostLogEntry,
  type PluginState,
  type WorkspaceRef,
} from "../src/plugins/host.js";
import type { NotificationInput } from "../src/notifications.js";
import { makeTempDir, rmTempDir, sleep } from "./_helpers.js";

const FIXTURE_ROOT = join(
  dirname(fileURLToPath(import.meta.url)),
  "fixtures",
  "plugins",
);

/// Copy the named fixtures into `<staging>/<name>/`. Tests only ever
/// stage the fixtures they actually exercise — copying everything would
/// add noise (e.g. an unrelated `crashy` exit would show up in a
/// `hello` test's log buffer).
async function stageFixtures(
  staging: string,
  names: string[],
): Promise<void> {
  for (const name of names) {
    await cp(join(FIXTURE_ROOT, name), join(staging, name), {
      recursive: true,
    });
  }
}

interface Harness {
  host: PluginHost;
  pluginsDir: string;
  logDir: string;
  hostLogs: HostLogEntry[];
  hostDiagnostics: string[];
}

let staging: string | null = null;

beforeEach(async () => {
  staging = await makeTempDir("openvsmobile-pluginhost-");
});

afterEach(async () => {
  if (staging !== null) {
    await rmTempDir(staging);
    staging = null;
  }
});

async function buildHarness(
  fixtures: string[],
  overrideManifest?: { name: string; content: string },
  options?: {
    workspaceResolver?: () => WorkspaceRef | null;
    notificationPublisher?: (input: NotificationInput) => { id: string };
  },
): Promise<Harness> {
  if (staging === null) throw new Error("staging dir not set up");
  const pluginsDir = join(staging, "plugins");
  const logDir = join(staging, "logs");
  await mkdir(pluginsDir, { recursive: true });
  await mkdir(logDir, { recursive: true });
  await stageFixtures(pluginsDir, fixtures);
  if (overrideManifest !== undefined) {
    const target = join(
      pluginsDir,
      overrideManifest.name,
      "plugin.json",
    );
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, overrideManifest.content);
  }
  const hostLogs: HostLogEntry[] = [];
  const hostDiagnostics: string[] = [];
  const host = new PluginHost({
    pluginsDir,
    logDir,
    logger: (line) => hostDiagnostics.push(line),
    onHostLog: (entry) => hostLogs.push(entry),
    ...(options?.workspaceResolver !== undefined
      ? { workspaceResolver: options.workspaceResolver }
      : {}),
    ...(options?.notificationPublisher !== undefined
      ? { notificationPublisher: options.notificationPublisher }
      : {}),
  });
  await host.start();
  return { host, pluginsDir, logDir, hostLogs, hostDiagnostics };
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

describe("PluginHost", () => {
  it("discovers and activates an onStartup plugin; host.log arrives", async () => {
    const harness = await buildHarness(["hello"]);
    try {
      const log = await waitFor(
        () =>
          harness.hostLogs.find(
            (e) => e.pluginId === "hello" && e.msg === "hello",
          ),
        2000,
      );
      expect(log.level).toBe("info");
      const entry = harness.host.get("hello");
      expect(entry?.state).toBe<PluginState>("active");
      expect(entry?.process?.pid()).toBeTypeOf("number");
    } finally {
      harness.host.shutdown();
    }
  });

  it("returns -32011 when a plugin calls an RPC outside its declared capabilities", async () => {
    const harness = await buildHarness(["sneaky"]);
    try {
      // The sneaky fixture echoes received bytes to stderr wrapped in
      // <<RX>>…<<END>> markers, and stderr is captured to a file by
      // the host. Wait for the marker that contains the gate's reply.
      const logPath = join(harness.logDir, "sneaky.stderr.log");
      const reply = await waitFor(async () => {
        let raw: string;
        try {
          raw = await readFile(logPath, "utf8");
        } catch {
          return undefined;
        }
        const match = /<<RX>>(.*?)<<END>>/s.exec(raw);
        return match?.[1];
      }, 2000);
      // The reply is a JSON-RPC error. The host writes LSP framing
      // when it doesn't know the peer's mode yet — but the sneaky
      // fixture's first byte ("C" of Content-Length) flips us to LSP,
      // so the response uses Content-Length framing.
      const bodyMatch = /Content-Length:\s*\d+\r\n\r\n(.+)$/s.exec(reply);
      expect(bodyMatch).not.toBeNull();
      const body = JSON.parse(bodyMatch![1] as string);
      expect(body).toMatchObject({
        jsonrpc: "2.0",
        id: 7,
        error: { code: -32011 },
      });
      expect(String(body.error.message)).toContain("capabilityNotDeclared");
    } finally {
      harness.host.shutdown();
    }
  });

  it("marks a plugin as crashed when its process exits non-zero, with no restart", async () => {
    const harness = await buildHarness(["crashy"]);
    try {
      const entry = await waitFor(() => {
        const e = harness.host.get("crashy");
        return e?.state === "crashed" ? e : undefined;
      }, 2000);
      expect(entry.exit?.code).toBe(1);
      expect(entry.process).toBeUndefined();
      const pidWhenCrashed = entry.process;
      // No restart: state must remain "crashed" and `process` must
      // remain unset across the rest of the wait budget.
      await sleep(200);
      const after = harness.host.get("crashy");
      expect(after?.state).toBe<PluginState>("crashed");
      expect(after?.process).toBe(pidWhenCrashed);
    } finally {
      harness.host.shutdown();
    }
  });

  it("tolerates a missing plugins directory", async () => {
    if (staging === null) throw new Error("staging dir not set up");
    const host = new PluginHost({
      pluginsDir: join(staging, "does-not-exist"),
      logDir: join(staging, "logs"),
      logger: () => {},
      onHostLog: () => {},
    });
    await host.start();
    expect(host.list()).toEqual([]);
    host.shutdown();
  });

  it("skips a subdirectory without plugin.json silently", async () => {
    if (staging === null) throw new Error("staging dir not set up");
    const pluginsDir = join(staging, "plugins");
    await mkdir(join(pluginsDir, "no-manifest"), { recursive: true });
    const host = new PluginHost({
      pluginsDir,
      logDir: join(staging, "logs"),
      logger: () => {},
      onHostLog: () => {},
    });
    await host.start();
    expect(host.get("no-manifest")).toBeUndefined();
    host.shutdown();
  });

  it("registers an entry as `errored` when the manifest is invalid", async () => {
    const harness = await buildHarness([], {
      name: "broken",
      content: '{"name": "broken"}',
    });
    try {
      const entry = harness.host.get("broken");
      expect(entry?.state).toBe<PluginState>("errored");
      expect(entry?.reason).toContain("version");
    } finally {
      harness.host.shutdown();
    }
  });

  it("workspace.current returns the active WorkspaceRef and null when none is set", async () => {
    // Two-phase: start with a live workspace so the spawn-time request
    // sees it, then re-resolve to null and fan out an activation to
    // exercise the null path on the notification side.
    let workspace: WorkspaceRef | null = {
      id: "ws-1",
      root: "/tmp/repo-1",
      label: "repo-1",
    };
    const harness = await buildHarness(["workspace"], undefined, {
      workspaceResolver: () => workspace,
    });
    try {
      const logPath = join(harness.logDir, "workspace.stderr.log");
      const response = await waitFor(async () => {
        let raw: string;
        try {
          raw = await readFile(logPath, "utf8");
        } catch {
          return undefined;
        }
        // First inbound frame is the response to id:1.
        const match = /<<RX>>(.*?)<<END>>/s.exec(raw);
        if (match === null) return undefined;
        const body = JSON.parse(match[1] as string) as {
          id?: number;
          result?: { workspace?: WorkspaceRef | null };
        };
        if (body.id !== 1) return undefined;
        return body;
      }, 2000);
      expect(response.result?.workspace).toEqual({
        id: "ws-1",
        root: "/tmp/repo-1",
        label: "repo-1",
      });

      // Now flip the resolver to null and fan out — the plugin's
      // stderr dump should pick the notification up as a second
      // marker frame.
      workspace = null;
      harness.host.fanOutWorkspaceActivated(null);
      const notification = await waitFor(async () => {
        const raw = await readFile(logPath, "utf8");
        const all = [...raw.matchAll(/<<RX>>(.*?)<<END>>/gs)];
        for (const m of all) {
          const body = JSON.parse(m[1] as string) as {
            method?: string;
            params?: { workspace?: WorkspaceRef | null };
          };
          if (body.method === "workspace.activated") return body;
        }
        return undefined;
      }, 2000);
      expect(notification.params?.workspace).toBeNull();
    } finally {
      harness.host.shutdown();
    }
  });

  it("fanOutWorkspaceActivated only pushes to active plugins, skipping disabled/crashed", async () => {
    // Stage both an active plugin and a crashy one. After crashy
    // terminates, the fan-out must not throw and must reach only the
    // surviving live plugin's stderr log.
    const harness = await buildHarness(["workspace", "crashy"], undefined, {
      workspaceResolver: () => null,
    });
    try {
      // Wait for the workspace fixture's first request to land in its
      // stderr — confirms it's active and listening.
      const liveLog = join(harness.logDir, "workspace.stderr.log");
      await waitFor(async () => {
        try {
          const raw = await readFile(liveLog, "utf8");
          return /<<RX>>/.test(raw) ? true : undefined;
        } catch {
          return undefined;
        }
      }, 2000);
      // And wait for crashy to have exited.
      await waitFor(() => {
        const e = harness.host.get("crashy");
        return e?.state === "crashed" ? true : undefined;
      }, 2000);
      // Fan out — must not throw even though crashy is gone.
      const ws: WorkspaceRef = {
        id: "ws-x",
        root: "/tmp/x",
        label: "x",
      };
      expect(() => harness.host.fanOutWorkspaceActivated(ws)).not.toThrow();
      // The live plugin should observe the notification.
      const seen = await waitFor(async () => {
        const raw = await readFile(liveLog, "utf8");
        const all = [...raw.matchAll(/<<RX>>(.*?)<<END>>/gs)];
        for (const m of all) {
          const body = JSON.parse(m[1] as string) as {
            method?: string;
            params?: { workspace?: WorkspaceRef | null };
          };
          if (body.method === "workspace.activated") return body;
        }
        return undefined;
      }, 2000);
      expect(seen.params?.workspace).toEqual(ws);
    } finally {
      harness.host.shutdown();
    }
  });

  it("notify.show: a plugin with `ui` capability publishes a notification; source is the plugin id", async () => {
    const seen: NotificationInput[] = [];
    let counter = 0;
    const harness = await buildHarness(["notify"], undefined, {
      notificationPublisher: (input) => {
        seen.push(input);
        return { id: `n-${++counter}` };
      },
    });
    try {
      const captured = await waitFor(() => (seen.length > 0 ? seen[0] : undefined), 2000);
      expect(captured.title).toBe("hello from notify fixture");
      expect(captured.body).toBe("phase-6a smoke");
      expect(captured.level).toBe("info");
      // The fixture deliberately sends `source: "system"` — the host
      // must overwrite it with the plugin id BEFORE publish, otherwise
      // a plugin could impersonate the system or another plugin.
      expect(captured.source).toBe("notify");

      // The host's response (containing the assigned id) should reach
      // the plugin's stdin, which the fixture echoes to stderr.
      const logPath = join(harness.logDir, "notify.stderr.log");
      const response = await waitFor(async () => {
        let raw: string;
        try {
          raw = await readFile(logPath, "utf8");
        } catch {
          return undefined;
        }
        const all = [...raw.matchAll(/<<RX>>(.*?)<<END>>/gs)];
        for (const m of all) {
          const body = JSON.parse(m[1] as string) as {
            id?: number;
            result?: { id?: string };
          };
          if (body.id === 1 && body.result?.id !== undefined) return body;
        }
        return undefined;
      }, 2000);
      expect(response.result?.id).toBe("n-1");
    } finally {
      harness.host.shutdown();
    }
  });

  it("notify.show: a plugin without `ui` capability gets -32011 capabilityNotDeclared", async () => {
    // Stage the notify fixture but override its manifest to strip `ui`.
    const seen: NotificationInput[] = [];
    const harness = await buildHarness(["notify"], {
      name: "notify",
      content: JSON.stringify({
        id: "notify",
        name: "Notify fixture (no caps)",
        version: "0.0.1",
        entry: { kind: "node", path: "index.js" },
        activation: ["onStartup"],
        capabilities: {},
      }),
    }, {
      notificationPublisher: (input) => {
        seen.push(input);
        return { id: "should-not-fire" };
      },
    });
    try {
      const logPath = join(harness.logDir, "notify.stderr.log");
      const reply = await waitFor(async () => {
        let raw: string;
        try {
          raw = await readFile(logPath, "utf8");
        } catch {
          return undefined;
        }
        const all = [...raw.matchAll(/<<RX>>(.*?)<<END>>/gs)];
        for (const m of all) {
          const body = JSON.parse(m[1] as string) as {
            id?: number;
            error?: { code?: number; message?: string };
          };
          if (body.id === 1 && body.error !== undefined) return body;
        }
        return undefined;
      }, 2000);
      expect(reply.error?.code).toBe(-32011);
      expect(String(reply.error?.message)).toContain("capabilityNotDeclared");
      // And the publisher must never have run.
      expect(seen).toHaveLength(0);
    } finally {
      harness.host.shutdown();
    }
  });

  it("notify.show: invalid input (missing title) surfaces -32602 invalidParams to the plugin", async () => {
    // Custom fixture inline: write a plugin that fires notify.show
    // with an empty title so the host's validator rejects it. Pattern
    // after the override-manifest path the other tests use.
    if (staging === null) throw new Error("staging dir not set up");
    const pluginsDir = join(staging, "plugins");
    const logDir = join(staging, "logs");
    await mkdir(join(pluginsDir, "notifybad"), { recursive: true });
    await mkdir(logDir, { recursive: true });
    await writeFile(
      join(pluginsDir, "notifybad", "plugin.json"),
      JSON.stringify({
        id: "notifybad",
        name: "Notify bad fixture",
        version: "0.0.1",
        entry: { kind: "node", path: "index.js" },
        activation: ["onStartup"],
        capabilities: { ui: true },
      }),
    );
    await writeFile(
      join(pluginsDir, "notifybad", "index.js"),
      `
process.stdout.write(
  JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "notify.show",
    params: { input: { level: "info", title: "" } },
  }) + "\\n",
);
let buffer = Buffer.alloc(0);
process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (true) {
    const nl = buffer.indexOf(0x0a);
    if (nl === -1) return;
    let line = buffer.subarray(0, nl);
    buffer = buffer.subarray(nl + 1);
    if (line.length > 0 && line[line.length - 1] === 0x0d) {
      line = line.subarray(0, line.length - 1);
    }
    if (line.length === 0) continue;
    process.stderr.write("<<RX>>" + line.toString("utf8") + "<<END>>\\n");
  }
});
setTimeout(() => {}, 60_000);
`,
    );
    const seen: NotificationInput[] = [];
    const host = new PluginHost({
      pluginsDir,
      logDir,
      logger: () => {},
      onHostLog: () => {},
      notificationPublisher: (input) => {
        seen.push(input);
        return { id: "x" };
      },
    });
    await host.start();
    try {
      const logPath = join(logDir, "notifybad.stderr.log");
      const reply = await waitFor(async () => {
        let raw: string;
        try {
          raw = await readFile(logPath, "utf8");
        } catch {
          return undefined;
        }
        const all = [...raw.matchAll(/<<RX>>(.*?)<<END>>/gs)];
        for (const m of all) {
          const body = JSON.parse(m[1] as string) as {
            id?: number;
            error?: { code?: number; message?: string };
          };
          if (body.id === 1 && body.error !== undefined) return body;
        }
        return undefined;
      }, 2000);
      expect(reply.error?.code).toBe(-32602);
      expect(String(reply.error?.message)).toContain("title");
      expect(seen).toHaveLength(0);
    } finally {
      host.shutdown();
    }
  });

  it("env var OPENVSMOBILE_PLUGINS_DIR overrides the discovery root", () => {
    const previous = process.env.OPENVSMOBILE_PLUGINS_DIR;
    process.env.OPENVSMOBILE_PLUGINS_DIR = "/tmp/openvsmobile-test-marker";
    try {
      const host = new PluginHost();
      expect(host.dir()).toBe("/tmp/openvsmobile-test-marker");
    } finally {
      if (previous === undefined) {
        delete process.env.OPENVSMOBILE_PLUGINS_DIR;
      } else {
        process.env.OPENVSMOBILE_PLUGINS_DIR = previous;
      }
    }
  });
});
