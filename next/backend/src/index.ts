// Backend entrypoint. One HTTP server hosting one WebSocket at /rpc.

import { createServer } from "node:http";
import { WebSocketServer } from "ws";
import { resolveToken } from "./config.js";
import { Connection } from "./connection.js";

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
    new Connection(ws, { expectedToken: token });
  });

  httpServer.listen(port, () => {
    console.error(
      `[openvsmobile-next] listening on 0.0.0.0:${port} (ws path: /rpc)`,
    );
    console.error(`[openvsmobile-next] token source: ${source}`);
    if (source !== "env") {
      // Surface the token to the dev. When the source is env we assume the
      // user already knows it; printing it then would leak secrets to logs.
      console.error(`[openvsmobile-next] token: ${token}`);
    }
  });

  const shutdown = (sig: string): void => {
    console.error(`[openvsmobile-next] ${sig} received, shutting down`);
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
