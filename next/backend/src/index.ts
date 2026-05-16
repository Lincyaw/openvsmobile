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

const DEFAULT_PORT = 7860;

function parsePort(): number {
  const raw = process.env.PORT;
  if (!raw) return DEFAULT_PORT;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > 65535) {
    throw new Error(`invalid PORT: ${raw}`);
  }
  return n;
}

async function main(): Promise<void> {
  const port = parsePort();
  const { token, source } = resolveToken();

  const state = new ProcessState();

  const httpServer = createServer((req, res) => {
    if (req.url === "/healthz") {
      res.statusCode = 200;
      res.setHeader("content-type", "text/plain");
      res.end("ok");
      return;
    }
    res.statusCode = 404;
    res.end("not found");
  });

  const wss = new WebSocketServer({ server: httpServer, path: "/rpc" });
  wss.on("connection", (ws) => {
    new Connection(ws, { expectedToken: token, state });
  });

  httpServer.listen(port, () => {
    console.error(
      `[openvsmobile-next] listening on 0.0.0.0:${port} (ws path: /rpc)`,
    );
    console.error(`[openvsmobile-next] token source: ${source}`);
    if (source !== "env") {
      console.error(`[openvsmobile-next] token: ${token}`);
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
    wss.close();
    httpServer.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 3000).unref();
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

main().catch((err) => {
  console.error("[openvsmobile-next] fatal:", err);
  process.exit(1);
});
