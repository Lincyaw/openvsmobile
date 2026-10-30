import { expect, it } from "vitest";
import iroh from "@number0/iroh";
import { mkdtempSync, rmSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawn } from "node:child_process";
import { spawn as spawnPty } from "node-pty";
import type { WebSocket } from "ws";
import { deflateRawSync } from "node:zlib";
import { IrohRpcSocket } from "../src/irohRpcSocket.js";
import { Connection } from "../src/connection.js";
import { ProcessState } from "../src/state.js";
import { RpcClient, ClientRpcError } from "../src/cli/client.js";
import {
  importHost,
  loadConfig,
  validateHost,
  type Host,
} from "../src/cli/config.js";

it("imports existing pairing formats and preserves private relay settings", () => {
  const data = {
    token: "bearer",
    iroh: {
      ticket: "ticket",
      alpn: "custom.rpc",
      relay: {
        mode: "custom",
        relays: [
          {
            url: "https://relay.example.com",
            quicPort: 7842,
            authToken: "relay-secret",
          },
        ],
      },
    },
  };
  expect(importHost(JSON.stringify(data))).toEqual(data);
  const qr =
    "ovsm1." +
    deflateRawSync(
      JSON.stringify({ ...data, k: "ovsm.backend", tr: "iroh", v: 1 }),
    ).toString("base64url");
  expect(importHost(qr)).toEqual(data);
  expect(() => validateHost({ ...data, url: "ws://localhost" })).toThrow();
  expect(() =>
    importHost(
      JSON.stringify({
        token: "secret",
        iroh: { ticket: "x", relay: { mode: "custom", relays: [] } },
      }),
    ),
  ).toThrow("Invalid Iroh pairing data");
  expect(() => importHost("invalid secret input")).toThrow(
    "Invalid Iroh pairing data",
  );
});

it("connects the real Iroh client to the server dispatcher, authenticates, replays and reconnects a PTY", async () => {
  const dir = mkdtempSync(join(tmpdir(), "ovsm-iroh-"));
  const state = new ProcessState();
  const builder = iroh.Endpoint.builder();
  builder.applyMinimal();
  builder.alpns([Array.from(Buffer.from("openvsmobile.rpc.v1"))]);
  builder.relayMode(iroh.RelayMode.disabled());
  builder.bindAddr("127.0.0.1:0");
  const endpoint = await builder.bind();
  const addr = new iroh.EndpointAddr(
    endpoint.id(),
    null,
    endpoint.boundSockets(),
  );
  const host: Host = {
    token: "iroh-secret",
    iroh: {
      ticket: iroh.EndpointTicket.fromAddr(addr).toString(),
      relay: { mode: "disabled" },
    },
  };
  const sockets = new Set<IrohRpcSocket>();
  const accepting = (async () => {
    while (!endpoint.isClosed()) {
      const incoming = await endpoint.acceptNext();
      if (!incoming) break;
      const conn = await (await incoming.accept()).connect();
      const stream = await conn.acceptBi();
      const socket = new IrohRpcSocket(stream, conn);
      sockets.add(socket);
      socket.once("close", () => sockets.delete(socket));
      new Connection(socket as unknown as WebSocket, {
        state,
        expectedToken: host.token,
        serverVersion: "test",
      });
      socket.start();
    }
  })();
  void accepting.catch(() => {});
  const configPath = join(dir, "client.json");
  const env = { ...process.env, OPENVSMOBILE_CLIENT_CONFIG: configPath };
  delete env.OPENVSMOBILE_URL;
  delete env.OPENVSMOBILE_TOKEN;
  const entry = resolve("src/cli/main.ts");
  async function cli(args: string[], input = "") {
    const child = spawn(process.execPath, ["--import", "tsx", entry, ...args], {
      env,
    });
    let stdout = "",
      stderr = "";
    child.stdout.on("data", (data) => {
      stdout += data;
    });
    child.stderr.on("data", (data) => {
      stderr += data;
    });
    child.stdin.end(input);
    const code = await new Promise((resolve, reject) => {
      child.on("close", resolve);
      child.on("error", reject);
    });
    return { code, stdout, stderr };
  }
  const client = new RpcClient();
  let sessionId: string | undefined;
  try {
    const denied = new RpcClient();
    await expect(
      denied.connect({ ...host, token: "wrong" }),
    ).rejects.toBeInstanceOf(ClientRpcError);
    await client.connect(host);
    expect(await client.call("system.ping")).toHaveProperty("now");
    // Cross several native read boundaries in a non-ASCII JSON string.
    const method = "unknown." + "你".repeat(12000);
    await expect(client.call(method)).rejects.toThrow(method);
    const created = await client.call<{ sessionId: string }>(
      "terminal.create",
      { cols: 80, rows: 24, cwd: dir },
    );
    sessionId = created.sessionId;
    await client.call("terminal.rename", { sessionId, title: "IROH_SENTINEL" });
    const imported = await cli(
      ["host", "import", "remote"],
      JSON.stringify(host),
    );
    expect(imported.code).toBe(0);
    expect(loadConfig(configPath).hosts.remote).toEqual(host);
    expect(statSync(configPath).mode & 0o777).toBe(0o600);
    const listed = await cli(["--host", "remote", "--json", "session", "list"]);
    expect(listed.code).toBe(0);
    expect(JSON.parse(listed.stdout).sessions[0].id).toBe(sessionId);
    const publicHosts = await cli(["host", "list"]);
    expect(publicHosts.stdout).toContain('"iroh"');
    expect(publicHosts.stdout).not.toContain("iroh-secret");
    const sent = await cli(
      ["--host", "remote", "--json", "session", "send", sessionId, "--enter"],
      "printf 'IROH_OUTPUT\\n'",
    );
    expect(sent.code).toBe(0);
    const history = await cli([
      "--host",
      "remote",
      "--json",
      "session",
      "history",
      sessionId,
    ]);
    expect(history.code).toBe(0);
    expect(
      Buffer.from(
        JSON.parse(history.stdout).scrollbackBase64,
        "base64",
      ).toString(),
    ).toContain("IROH_OUTPUT");
    const tty = spawnPty(
      process.execPath,
      [
        "--import",
        "tsx",
        entry,
        "--host",
        "remote",
        "session",
        "attach",
        sessionId,
      ],
      {
        name: "xterm-256color",
        cols: 90,
        rows: 30,
        cwd: process.cwd(),
        env,
      },
    );
    let phase = 0;
    let transcript = "";
    const exit = await new Promise<number>((resolve, reject) => {
      const timer = setTimeout(() => {
        tty.kill();
        reject(new Error("Iroh attach timed out"));
      }, 12000);
      tty.onData((data) => {
        transcript += data;
        if (phase === 0 && transcript.includes("IROH_OUTPUT")) {
          phase = 1;
          Array.from(sockets).at(-1)!.terminate();
        } else if (
          phase === 1 &&
          transcript.includes("Reconnecting") &&
          data.includes("IROH_OUTPUT")
        ) {
          phase = 2;
          tty.write("\x1d");
        }
      });
      tty.onExit(({ exitCode }) => {
        clearTimeout(timer);
        resolve(exitCode);
      });
    });
    expect(exit).toBe(0);
    expect(phase).toBe(2);
    expect(transcript).toContain("Detached.");
    expect(
      (
        await client.call<{ sessions: { id: string }[] }>("terminal.list")
      ).sessions.some((session) => session.id === sessionId),
    ).toBe(true);
  } finally {
    client.close();
    if (sessionId) state.terminals.dispose(sessionId);
    state.shutdownAll();
    for (const socket of sockets) socket.terminate();
    await endpoint.close();
    await accepting.catch(() => {});
    rmSync(dir, { recursive: true, force: true });
  }
});
