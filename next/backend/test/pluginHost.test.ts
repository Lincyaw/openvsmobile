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
} from "../src/plugins/host.js";
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
