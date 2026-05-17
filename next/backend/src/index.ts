// Backend entrypoint. One HTTP server hosting one WebSocket at /rpc.
//
// We construct a single ProcessState at startup; every Connection is a
// thin authenticated subscriber pointed at it. That's what lets PTYs and
// workspaces survive a client disconnect — see docs/design/mobile-code-platform.md
// §5.1.

import { createServer } from "node:http";
import { WebSocketServer } from "ws";
import { resolveToken } from "./config.js";
import { Connection } from "./connection.js";
import { ProcessState } from "./state.js";
import { handleNotifyHttp } from "./notifyHttp.js";
import {
  runtimeInfoPath,
  unlinkRuntimeInfo,
  writeRuntimeInfo,
} from "./runtimeInfo.js";
import { readPackageVersion } from "./version.js";
import { initNtfySender } from "./ntfy.js";

const DEFAULT_PORT = 7860;
const SHUTDOWN_HARD_EXIT_MS = 3000;

function parsePort(): number {
  const raw = process.env.PORT;
  if (!raw) return DEFAULT_PORT;
  const n = Number(raw);
  // PORT=0 means "ask the OS for a free port" — supported so install.sh can
  // let the kernel pick and then read the actual bound port out of
  // runtime.json.
  if (!Number.isInteger(n) || n < 0 || n > 65535) {
    throw new Error(`invalid PORT: ${raw}`);
  }
  return n;
}

async function main(): Promise<void> {
  const port = parsePort();
  const { token, source } = resolveToken();
  const version = readPackageVersion();

  const state = new ProcessState();

  // ntfy is the notification transport for background delivery. Gated by
  // $NTFY_URL + $NTFY_TOPIC. Backends without ntfy configured still
  // deliver via the in-process WS fan-out while the app is connected.
  const ntfySender = initNtfySender();
  if (ntfySender !== null) {
    state.notificationHub.attachNtfySender(ntfySender);
  }

  const httpServer = createServer((req, res) => {
    if (req.url === "/healthz") {
      res.statusCode = 200;
      res.setHeader("content-type", "text/plain");
      res.end("ok");
      return;
    }
    // POST /notify — sender API for the notification system (§4.5). Mounted
    // on the same server as /rpc; same bearer token. Async handler returns
    // true once it has written a response.
    if (req.url === "/notify") {
      handleNotifyHttp(req, res, {
        expectedToken: token,
        hub: state.notificationHub,
      }).catch((err) => {
        console.error("[notify] handler error:", err);
        if (!res.headersSent) {
          res.statusCode = 500;
          res.end();
        }
      });
      return;
    }
    res.statusCode = 404;
    res.end("not found");
  });

  const wss = new WebSocketServer({ server: httpServer, path: "/rpc" });
  wss.on("connection", (ws) => {
    new Connection(ws, {
      expectedToken: token,
      serverVersion: version,
      state,
    });
  });

  let runtimeFile: string | null = null;
  httpServer.listen(port, () => {
    const addr = httpServer.address();
    const boundPort =
      typeof addr === "object" && addr !== null ? addr.port : port;
    console.error(
      `[openvsmobile-next] listening on 0.0.0.0:${boundPort} (ws path: /rpc)`,
    );
    // Never log the token. It's exposed through runtime.json (mode 0600).
    console.error(`[openvsmobile-next] token source: ${source}`);
    try {
      runtimeFile = writeRuntimeInfo({
        schema: 1,
        pid: process.pid,
        port: boundPort,
        token,
        startedAt: new Date().toISOString(),
        version,
      });
      console.error(`[openvsmobile-next] runtime info: ${runtimeFile}`);
    } catch (err) {
      // If we can't write the runtime file, the wrapper has no way to learn
      // our port — but a running backend is still useful to a client that
      // already knows the token. Log loudly and continue.
      console.error(
        `[openvsmobile-next] WARN: failed to write runtime info at ${runtimeInfoPath()}:`,
        err,
      );
    }
  });

  let shuttingDown = false;
  const shutdown = (sig: string): void => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.error(`[openvsmobile-next] ${sig} received, shutting down`);
    // Kill all PTYs and notify any still-attached subscribers before tearing
    // down the socket. Best-effort: if a subscriber's send queue is full we
    // just move on.
    try {
      state.shutdownAll();
    } catch (err) {
      console.error("[openvsmobile-next] shutdown error:", err);
    }
    // Best-effort unlink — if the file is already gone (or was never
    // written), we don't block shutdown on it.
    unlinkRuntimeInfo();
    wss.close();
    httpServer.close(() => process.exit(0));
    // One-shot deadline — if httpServer.close hasn't drained in time, exit
    // hard. This is the only `setTimeout` in the backend hot path; it's
    // explicitly allowed by §1 as a shutdown deadline (not a recurring poll).
    setTimeout(() => process.exit(1), SHUTDOWN_HARD_EXIT_MS).unref();
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

main().catch((err) => {
  console.error("[openvsmobile-next] fatal:", err);
  process.exit(1);
});
