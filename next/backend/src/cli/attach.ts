import { setTimeout as delay } from "node:timers/promises";
import type { Host } from "./config.js";
import {
  ClientRpcError,
  RpcClient,
  TerminalReplay,
  type History,
  type OutputChunk,
} from "./client.js";

const MAX_PENDING_BYTES = 2 * 1024 * 1024;
const RECONNECT_DELAYS_MS = [500, 1000, 2000, 4000, 8000];

/** Ctrl-] detaches locally; closing this connection never disposes a PTY. */
export async function attach(host: Host, sessionId: string): Promise<void> {
  if (!process.stdin.isTTY || !process.stdout.isTTY)
    throw new Error(
      "attach requires a TTY; use session history/send for scripts",
    );
  const input = process.stdin;
  const output = process.stdout;
  const abort = new AbortController();
  let client: RpcClient | undefined;
  let ready = false;
  let resolveDone!: () => void;
  let rejectDone!: (error: Error) => void;
  const done = new Promise<void>((resolve, reject) => {
    resolveDone = resolve;
    rejectDone = reject;
  });
  // Establish the rejection handler before asynchronous setup starts.
  void done.catch(() => {});
  const finish = () => {
    abort.abort();
    ready = false;
    resolveDone();
  };
  const fail = (error: Error) => {
    abort.abort();
    ready = false;
    rejectDone(error);
  };
  const resize = () => {
    if (ready)
      void client!
        .call("terminal.resize", {
          sessionId,
          cols: output.columns || 80,
          rows: output.rows || 24,
        })
        .catch((error: Error) => {
          if (ready) fail(error);
        });
  };
  const onInput = (data: Buffer) => {
    const detachAt = data.indexOf(0x1d);
    if (detachAt !== -1) {
      finish();
      return;
    }
    if (!ready) return; // Never replay keystrokes after an uncertain write.
    void client!
      .call("terminal.write", {
        sessionId,
        dataBase64: data.toString("base64"),
      })
      .catch((error: Error) => {
        if (!ready) return;
        fail(error);
      });
  };
  let reconnecting = false;
  async function establish(): Promise<void> {
    const next = new RpcClient();
    client = next;
    let syncing = true;
    let queued: OutputChunk[] = [];
    let queuedBytes = 0;
    const replay = new TerminalReplay();
    next.on(
      "notification",
      (
        method: string,
        params: OutputChunk & { sessionId: string; exitCode?: number },
      ) => {
        if (params.sessionId !== sessionId) return;
        if (method === "terminal.exit") {
          process.exitCode = params.exitCode ?? 0;
          finish();
        }
        if (method === "terminal.detached") {
          process.stderr.write("\r\nRemote terminal detached.\r\n");
          finish();
        }
        if (method !== "terminal.data") return;
        if (syncing) {
          queuedBytes += Buffer.byteLength(params.dataBase64, "base64");
          if (queuedBytes > MAX_PENDING_BYTES) {
            fail(new Error("Terminal output exceeded resync buffer"));
            return;
          }
          queued.push(params);
        } else output.write(replay.chunk(params));
      },
    );
    next.on("disconnected", () => {
      ready = false;
      if (!syncing && !abort.signal.aborted) void reconnect();
    });
    await next.connect(host);
    if (abort.signal.aborted) {
      next.close();
      return;
    }
    await next.call("terminal.subscribe", { ids: [sessionId] });
    await next.call("terminal.resize", {
      sessionId,
      cols: output.columns || 80,
      rows: output.rows || 24,
    });
    const history = await next.call<History>("terminal.history", { sessionId });
    if (abort.signal.aborted) return;
    if (history.bytesDropped)
      process.stderr.write("\r\n[Older output is no longer available.]\r\n");
    // A new screen baseline also works when zellij reset its byte counter.
    output.write("\x1b[0m\x1b[2J\x1b[H");
    output.write(replay.snapshot(history));
    for (const chunk of queued) output.write(replay.chunk(chunk));
    queued = [];
    syncing = false;
    ready = true;
  }
  async function reconnect(): Promise<void> {
    if (reconnecting) return;
    reconnecting = true;
    process.stderr.write(
      "\r\nDisconnected. Reconnecting; input paused (Ctrl-] to leave).\r\n",
    );
    try {
      for (const wait of RECONNECT_DELAYS_MS) {
        await delay(wait, undefined, { signal: abort.signal });
        try {
          await establish();
          return;
        } catch (error) {
          client?.close();
          if (error instanceof ClientRpcError) throw error;
        }
      }
      throw new Error(
        "Reconnect failed; attach again to resume the remote session",
      );
    } catch (error) {
      if (!abort.signal.aborted) fail(error as Error);
    } finally {
      reconnecting = false;
    }
  }
  const previousRaw = input.isRaw;
  input.setRawMode(true);
  input.resume();
  input.on("data", onInput);
  output.on("resize", resize);
  process.on("SIGTERM", finish);
  process.on("SIGINT", finish);
  process.stderr.write(
    "Ctrl-] detaches locally. Remote session keeps running.\r\n",
  );
  try {
    // Race permits local detach even while the initial handshake is pending.
    await Promise.race([establish(), done]);
    await done;
  } finally {
    abort.abort();
    ready = false;
    client?.close();
    input.off("data", onInput);
    output.off("resize", resize);
    process.off("SIGTERM", finish);
    process.off("SIGINT", finish);
    input.setRawMode(previousRaw);
    input.pause();
    output.write(
      "\x1b[0m\x1b[?25h\x1b[?2004l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1049l",
    );
    process.stderr.write("\r\nDetached.\r\n");
  }
}
