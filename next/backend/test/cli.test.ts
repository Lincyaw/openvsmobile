import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { spawn as spawnPty } from "node-pty";
import { WebSocketServer } from "ws";
import { Connection } from "../src/connection.js";
import { ProcessState } from "../src/state.js";
import { loadConfig, normalizeUrl, saveConfig } from "../src/cli/config.js";
import {
  ClientRpcError,
  RpcClient,
  TerminalReplay,
} from "../src/cli/client.js";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ovsm-cli-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("CLI credentials and replay", () => {
  it("normalizes endpoints, rejects credential URLs and never replaces corrupt config", () => {
    expect(normalizeUrl("https://example.com:7860")).toBe(
      "wss://example.com:7860/rpc",
    );
    expect(() => normalizeUrl("ws://user:secret@example.com")).toThrow();
    expect(() => normalizeUrl("ws://example.com?token=secret")).toThrow();
    const path = join(dir, "client.json");
    saveConfig(
      { hosts: { work: { url: "ws://localhost:7860/rpc", token: "secret" } } },
      path,
    );
    expect(statSync(path).mode & 0o777).toBe(0o600);
    expect(loadConfig(path).hosts.work.token).toBe("secret");
    writeFileSync(path, "broken");
    expect(() => loadConfig(path)).toThrow("Invalid client config");
    expect(readFileSync(path, "utf8")).toBe("broken");
  });
  it("deduplicates overlapping history in bytes and accepts a new counter baseline", () => {
    const replay = new TerminalReplay();
    const bytes = Buffer.from("你好!");
    expect(
      replay.snapshot({
        scrollbackBase64: bytes.subarray(0, 4).toString("base64"),
        scrollbackOffsetEnd: 4,
        bytesDropped: 0,
      }),
    ).toEqual(bytes.subarray(0, 4));
    expect(
      replay.chunk({ dataBase64: bytes.toString("base64"), seqEnd: 7 }),
    ).toEqual(bytes.subarray(4));
    expect(
      replay.chunk({ dataBase64: bytes.toString("base64"), seqEnd: 7 }).length,
    ).toBe(0);
    replay.snapshot({
      scrollbackBase64: "",
      scrollbackOffsetEnd: 0,
      bytesDropped: 0,
    });
    expect(
      replay.chunk({ dataBase64: bytes.toString("base64"), seqEnd: 7 }),
    ).toEqual(bytes);
  });
});

it("uses the real dispatcher and PTY, supports JSON automation and local attach/detach", async () => {
  const state = new ProcessState();
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
  await new Promise<void>((resolve) => server.once("listening", resolve));
  server.on(
    "connection",
    (ws) =>
      new Connection(ws, {
        state,
        expectedToken: "secret",
        serverVersion: "test",
      }),
  );
  const address = server.address() as { port: number };
  const host = { url: `ws://127.0.0.1:${address.port}/rpc`, token: "secret" };
  const configFile = join(dir, "client.json");
  saveConfig(
    { hosts: { test: host, other: { url: host.url, token: "other-secret" } } },
    configFile,
  );
  const env = { ...process.env, OPENVSMOBILE_CLIENT_CONFIG: configFile };
  delete env.OPENVSMOBILE_URL;
  delete env.OPENVSMOBILE_TOKEN;
  const entry = resolve("src/cli/main.ts");
  async function cli(
    args: string[],
    input = "",
  ): Promise<{ code: number | null; stdout: string; stderr: string }> {
    const child = spawn(process.execPath, ["--import", "tsx", entry, ...args], {
      env,
    });
    let stdout = "",
      stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.stdin.end(input);
    return new Promise((resolve, reject) => {
      child.on("error", reject);
      child.on("close", (code) => resolve({ code, stdout, stderr }));
    });
  }
  const client = new RpcClient();
  let terminalId: string | undefined;
  try {
    const denied = new RpcClient();
    await expect(
      denied.connect({ ...host, token: "wrong" }),
    ).rejects.toBeInstanceOf(ClientRpcError);
    await client.connect(host);
    const created = await client.call<{ sessionId: string }>(
      "terminal.create",
      { cols: 80, rows: 24, cwd: dir },
    );
    terminalId = created.sessionId;
    const listed = await cli(["--host", "test", "--json", "session", "list"]);
    expect(listed.code).toBe(0);
    expect(JSON.parse(listed.stdout).sessions[0].id).toBe(terminalId);
    const hosts = await cli(["host", "list"]);
    expect(hosts.stdout).not.toContain("secret");
    const invalid = await cli([
      "--host",
      "test",
      "--json",
      "session",
      "send",
      terminalId,
      "unexpected",
    ]);
    expect(invalid.code).toBe(1);
    expect(JSON.parse(invalid.stderr).error.code).toBe("CLI_ERROR");
    const sent = await cli(
      ["--host", "test", "--json", "session", "send", terminalId, "--enter"],
      "printf 'CLI_SENTINEL\\n'",
    );
    expect(sent.code).toBe(0);
    // Read the PTY through the actual CLI. The send command is acknowledged
    // before shell execution, so wait on a semantic terminal.data push.
    const history = await cli([
      "--host",
      "test",
      "--json",
      "session",
      "history",
      terminalId,
    ]);
    expect(
      Buffer.from(
        JSON.parse(history.stdout).scrollbackBase64,
        "base64",
      ).toString(),
    ).toContain("CLI_SENTINEL");

    const tty = spawnPty(
      process.execPath,
      [
        "--import",
        "tsx",
        entry,
        "--host",
        "test",
        "session",
        "attach",
        terminalId,
      ],
      {
        name: "xterm-256color",
        cols: 90,
        rows: 30,
        cwd: process.cwd(),
        env,
      },
    );
    let transcript = "";
    let phase: "initial" | "reconnecting" | "done" = "initial";
    const ttyDone = new Promise<number>((resolve, reject) => {
      const timer = setTimeout(() => {
        tty.kill();
        reject(new Error("attach timed out"));
      }, 8000);
      tty.onData((data) => {
        transcript += data;
        if (phase === "initial" && transcript.includes("CLI_SENTINEL")) {
          phase = "reconnecting";
          // Drop the attachment transport while keeping the server and PTY alive.
          Array.from(server.clients).at(-1)!.terminate();
        } else if (
          phase === "reconnecting" &&
          transcript.includes("Reconnecting") &&
          data.includes("CLI_SENTINEL")
        ) {
          phase = "done";
          tty.write("\x1d");
        }
      });
      tty.onExit(({ exitCode }) => {
        clearTimeout(timer);
        resolve(exitCode);
      });
    });
    expect(await ttyDone).toBe(0);
    expect(transcript).toContain("Detached.");
    expect(transcript).toContain("Reconnecting");
    expect(phase).toBe("done");
    expect(
      (
        await client.call<{ sessions: { id: string }[] }>("terminal.list")
      ).sessions.some((s) => s.id === terminalId),
    ).toBe(true);
    client.close();
    const resumed = new RpcClient();
    await resumed.connect(host);
    expect(
      await resumed.call("terminal.history", { sessionId: terminalId }),
    ).toHaveProperty("scrollbackOffsetEnd");
    resumed.close();
  } finally {
    if (terminalId) state.terminals.dispose(terminalId);
    client.close();
    state.shutdownAll();
    for (const ws of server.clients) ws.terminate();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
