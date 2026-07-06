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
import { HookHandler } from "./hookHttp.js";
import { PluginHost } from "./plugins/host.js";
import { probeMultiplexer } from "./multiplexer.js";
import { TerminalPersistence } from "./terminalPersistence.js";
import {
  runtimeInfoPath,
  unlinkRuntimeInfo,
  writeRuntimeInfo,
} from "./runtimeInfo.js";
import { readPackageVersion } from "./version.js";
import { initNtfySender } from "./ntfy.js";
import { MdnsAdvertiser } from "./mdnsAdvertiser.js";
import {
  startIrohRpcServer,
  type IrohRpcServer,
} from "./irohTransport.js";

const DEFAULT_PORT = 7860;
// Plugin shutdown uses a SIGTERM -> grace -> SIGKILL path with a 10s default
// grace window. The backend hard deadline must be longer than that; otherwise
// normal systemd stop/restart turns into exit(1), which systemd treats as a
// crash and loops until StartLimitBurst is hit.
const SHUTDOWN_HARD_EXIT_MS = 15_000;

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

  // Probe for a terminal multiplexer. When zellij is available, every
  // terminal spawned through `terminal.create` is wrapped in
  // `zellij attach --create <name>` so the kernel-side PTY survives a
  // backend restart — the zellij server holds the slave, the backend's
  // PTY child is the zellij CLIENT. Missing zellij is fine; the probe
  // returns `{ kind: "none" }` and terminal.ts transparently spawns
  // the user's shell directly. The probe logs a single stderr line on
  // failure, never throws, and is hard-bounded by a 2s timeout.
  const multiplexer = await probeMultiplexer();
  if (multiplexer.kind === "zellij") {
    console.error(
      `[openvsmobile-next] multiplexer: zellij (${multiplexer.version})`,
    );
  }

  // Durable record of (terminalId → multiplexer session) pairs. Writes
  // on terminal.create / dispose; nothing in v0 reads back from it. The
  // column exists so a future "list resurrectable sessions" surface
  // doesn't need a schema migration when it lands.
  const terminalPersistence = new TerminalPersistence();

  const state = new ProcessState({ multiplexer, terminalPersistence });

  // ntfy is the notification transport for background delivery. Gated by
  // $NTFY_URL + $NTFY_TOPIC. Backends without ntfy configured still
  // deliver via the in-process client fan-out while the app is connected.
  const ntfySender = initNtfySender();
  if (ntfySender !== null) {
    state.notificationHub.attachNtfySender(ntfySender);
  }

  // Plugin host. Discovers plugins on disk and spawns the ones with
  // `onStartup` activation; calls from plugins are capability-gated
  // before reaching any host method. The frontend reaches the host
  // through the `plugin.*` RPCs in `rpc.ts`; state transitions fan out
  // through `plugin.stateChanged`. UI descriptor pushes (`ui.tree`)
  // also flow through the host. Late-assigned to `state` because the
  // host's `onStateChanged` needs `state.broadcastPluginStateChanged`
  // (chicken-and-egg). See docs/design/mobile-code-platform.md §3.
  const pluginHost = new PluginHost({
    onStateChanged: (change) => state.broadcastPluginStateChanged(change),
    // Active-workspace lookup for Batch-3 `file://` URL gating in
    // `ui.render`. The host invokes this on every render carrying an
    // `Image` / `Avatar` with a `file://` src; resolves to the same
    // path the read-only `fs.*` RPCs rely on for isolation.
    workspaceRootResolver: () => state.workspaces.current()?.root ?? null,
    // Phase-0 repo-aware plugin surface: backs the `workspace.current`
    // plugin-host RPC with the registry's current workspace. Projected
    // down to the SDK's `WorkspaceRef` shape (id / root / label) so
    // `createdAt` doesn't leak into the plugin contract.
    workspaceResolver: () => {
      const ws = state.workspaces.current();
      if (ws === null) return null;
      return { id: ws.id, root: ws.root, label: ws.label };
    },
    // Phase-6A `notify.show`: plugins fire user-facing notifications
    // through the existing §4.5 store + client fan-out. The host has
    // already overridden `input.source` to the plugin id before
    // calling us, so `publish` runs unchanged.
    notificationPublisher: (input) => state.notificationHub.publish(input),
  });
  // Phase-0 fan-out: when the user switches workspaces, push
  // `workspace.activated` to every active plugin process so repo-aware
  // plugins react without polling. Wired here (not in ProcessState's
  // constructor) because the registry is owned by ProcessState but the
  // host is constructed afterwards.
  state.workspaces.setActivatedHook((ws) => {
    pluginHost.fanOutWorkspaceActivated(
      ws === null ? null : { id: ws.id, root: ws.root, label: ws.label },
    );
  });
  state.pluginHost = pluginHost;
  await pluginHost.start();

  const hookHandler = new HookHandler({
    expectedToken: token,
    hub: state.notificationHub,
    tokenStore: state.tokenStore,
  });

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
        tokenStore: state.tokenStore,
      }).catch((err) => {
        console.error("[notify] handler error:", err);
        if (!res.headersSent) {
          res.statusCode = 500;
          res.end();
        }
      });
      return;
    }
    // Permissive sender endpoint — see hookHttp.ts. Same security
    // perimeter as /notify (auth or publish token), but accepts
    // path-segment auth + JSON/form/plain bodies for paste-friendly
    // third-party webhook URLs.
    if (req.url !== undefined && req.url.startsWith("/hook/")) {
      hookHandler.handle(req, res).catch((err) => {
        console.error("[hook] handler error:", err);
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

  let irohServer: IrohRpcServer | null = await startIrohRpcServer({
    expectedToken: token,
    serverVersion: version,
    state,
  });

  let runtimeFile: string | null = null;
  let mdnsAdvertiser: MdnsAdvertiser | null = null;
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
        ...(irohServer === null ? {} : { iroh: irohServer.info }),
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
    if (irohServer !== null) {
      console.error(
        `[openvsmobile-next] Iroh endpoint: ${irohServer.info.endpointId}`,
      );
      console.error(
        `[openvsmobile-next] Iroh ticket: ${irohServer.info.ticket}`,
      );
    }
    // Start mDNS advertisement so LAN clients can discover us.
    mdnsAdvertiser = new MdnsAdvertiser({ port: boundPort, version });
    mdnsAdvertiser.start().catch((err) => {
      console.error("[openvsmobile-next] mDNS advertise failed:", err);
    });
  });

  let shuttingDown = false;
  const shutdown = async (sig: string): Promise<void> => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.error(`[openvsmobile-next] ${sig} received, shutting down`);
    // Hard deadline — if any step hangs we exit anyway. Armed first so the
    // process can't get stuck even if the awaits below throw or stall.
    setTimeout(() => process.exit(1), SHUTDOWN_HARD_EXIT_MS).unref();
    try {
      state.shutdownAll();
    } catch (err) {
      console.error("[openvsmobile-next] shutdown error:", err);
    }
    // Wait for plugin processes to actually die (SIGTERM → grace → SIGKILL)
    // before closing the HTTP server; otherwise plugins outlive the socket
    // they were notifying through.
    try {
      await pluginHost.shutdown();
    } catch (err) {
      console.error("[openvsmobile-next] plugin shutdown error:", err);
    }
    try {
      terminalPersistence.close();
    } catch (err) {
      console.error("[openvsmobile-next] terminal DB close error:", err);
    }
    if (mdnsAdvertiser) {
      await mdnsAdvertiser.stop().catch(() => {});
    }
    if (irohServer !== null) {
      await irohServer.close().catch((err) => {
        console.error("[openvsmobile-next] Iroh shutdown error:", err);
      });
      irohServer = null;
    }
    unlinkRuntimeInfo();
    for (const client of wss.clients) {
      client.close(1001, "server shutdown");
    }
    const forceCloseClients = setTimeout(() => {
      for (const client of wss.clients) {
        client.terminate();
      }
    }, 1000);
    forceCloseClients.unref();
    wss.close(() => {
      clearTimeout(forceCloseClients);
      httpServer.close(() => process.exit(0));
    });
  };
  process.on("SIGINT", () => void shutdown("SIGINT"));
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
}

main().catch((err) => {
  console.error("[openvsmobile-next] fatal:", err);
  process.exit(1);
});
