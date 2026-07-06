import { describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
const BACKEND_DIR = join(HERE, "..");
const SCRIPT = join(BACKEND_DIR, "bin", "openvsmobile-pairing-qr.mjs");

function withRuntime<T>(data: unknown, fn: (path: string) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "ovsm-pairing-"));
  try {
    const path = join(dir, "runtime.json");
    writeFileSync(path, JSON.stringify(data));
    return fn(path);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function runQr(args: string[]) {
  return spawnSync(process.execPath, [SCRIPT, ...args], {
    encoding: "utf8",
  });
}

describe("openvsmobile-pairing-qr", () => {
  it("builds compact Iroh pairing JSON from runtime info", () => {
    withRuntime(
      {
        port: 39811,
        token: "tok",
        version: "0.4.7",
        iroh: {
          endpointId: "endpoint",
          ticket: "ticket",
          alpn: "openvsmobile.rpc.v1",
        },
      },
      (runtimePath) => {
        const result = runQr([
          "--runtime",
          runtimePath,
          "--version",
          "0.4.7",
          "--name",
          "home",
          "--json-only",
        ]);
        expect(result.status).toBe(0);
        const payload = JSON.parse(result.stdout);
        expect(payload).toMatchObject({
          v: 1,
          k: "ovsm.backend",
          n: "home",
          tr: "iroh",
          token: "tok",
          version: "0.4.7",
          iroh: {
            endpointId: "endpoint",
            ticket: "ticket",
            alpn: "openvsmobile.rpc.v1",
          },
        });
      },
    );
  });

  it("builds WebSocket pairing JSON with the supplied reachable host", () => {
    withRuntime(
      {
        port: 39811,
        token: "tok",
        version: "0.4.7",
      },
      (runtimePath) => {
        const result = runQr([
          "--runtime",
          runtimePath,
          "--host",
          "10.0.0.12",
          "--json-only",
        ]);
        expect(result.status).toBe(0);
        const payload = JSON.parse(result.stdout);
        expect(payload).toMatchObject({
          tr: "websocket",
          token: "tok",
          ws: { host: "10.0.0.12", port: 39811 },
        });
      },
    );
  });

  it("fails loudly on stale runtime version", () => {
    withRuntime(
      {
        port: 39811,
        token: "tok",
        version: "0.4.6",
      },
      (runtimePath) => {
        const result = runQr([
          "--runtime",
          runtimePath,
          "--version",
          "0.4.7",
          "--json-only",
        ]);
        expect(result.status).toBe(1);
        expect(result.stderr).toContain("does not match");
      },
    );
  });
});
