// Process-global state. One ProcessState per backend process; every
// Connection is a thin authenticated subscriber to the shared registries.
//
// Why this lives separately from connection.ts:
//   * Workspaces and PTYs survive client disconnects. They are owned by the
//     process, not the WebSocket. Closing the socket detaches a subscriber;
//     it does not dispose anything.
//   * Terminal output fans out to every connected subscriber. The sinks live
//     here so they capture the subscriber set, not a single connection.
//   * Two simultaneous clients (phone + laptop, or two phones) see the same
//     registries. PTY input is interleaved at the kernel; output goes to both.
//
// See docs/design/mobile-code-platform.md §5.1.

import type { WebSocket } from "ws";
import { sendNotification } from "./rpc.js";
import {
  WorkspaceRegistry,
  type ActiveWorkspace,
} from "./workspace.js";
import type { TerminalSnapshot } from "./terminal.js";

/// Each authenticated WebSocket registers a Subscriber. The connection is
/// responsible for unregistering when the socket closes.
export interface Subscriber {
  readonly ws: WebSocket;
}

export class ProcessState {
  /// The single workspace registry shared by every Connection. Terminal
  /// sinks are wired through this class so the registry stays unaware of
  /// individual subscribers.
  public readonly workspaces: WorkspaceRegistry;

  private readonly subscribers = new Set<Subscriber>();

  constructor() {
    this.workspaces = new WorkspaceRegistry(
      // terminal data → broadcast to every subscriber.
      (sessionId, data, seqEnd) => {
        const wsId = this.workspaceIdForTerminal(sessionId);
        if (wsId === null) return;
        const params = {
          sessionId,
          workspaceId: wsId,
          dataBase64: data.toString("base64"),
          seqEnd,
        };
        for (const sub of this.subscribers) {
          sendNotification(sub.ws, "terminal.data", params);
        }
      },
      // terminal exit → broadcast.
      (sessionId, exitCode) => {
        const wsId = this.workspaceIdForTerminal(sessionId);
        const params = {
          sessionId,
          workspaceId: wsId, // may be null if workspace was already closed
          exitCode,
        };
        for (const sub of this.subscribers) {
          sendNotification(sub.ws, "terminal.exit", params);
        }
      },
    );
  }

  public addSubscriber(s: Subscriber): void {
    this.subscribers.add(s);
  }

  public removeSubscriber(s: Subscriber): void {
    this.subscribers.delete(s);
  }

  /// Broadcast a workspace.closed notification to every subscriber. Used both
  /// for user-initiated closes (so two-client scenarios stay in sync) and for
  /// the process-exit graceful shutdown path.
  public broadcastWorkspaceClosed(id: string): void {
    for (const sub of this.subscribers) {
      sendNotification(sub.ws, "workspace.closed", { id });
    }
  }

  /// Find the owning workspace for a terminal session id, or null if the
  /// session was just removed (e.g. exit fired during workspace close).
  public workspaceIdForTerminal(sessionId: string): string | null {
    for (const info of this.workspaces.listActive()) {
      const ws = this.workspaces.get(info.id);
      if (ws.terminals.has(sessionId)) return ws.id;
    }
    return null;
  }

  public findSession(sessionId: string): ActiveWorkspace | null {
    for (const info of this.workspaces.listActive()) {
      const ws = this.workspaces.get(info.id);
      if (ws.terminals.has(sessionId)) return ws;
    }
    return null;
  }

  /// Flat list of every terminal session across every active workspace, each
  /// annotated with its owning workspaceId. Used by `terminal.list` when the
  /// caller omits a workspaceId filter.
  public listAllTerminals(): Array<TerminalSnapshot & { workspaceId: string }> {
    const out: Array<TerminalSnapshot & { workspaceId: string }> = [];
    for (const info of this.workspaces.listActive()) {
      const ws = this.workspaces.get(info.id);
      for (const t of ws.terminals.list()) {
        out.push({ ...t, workspaceId: ws.id });
      }
    }
    return out;
  }

  /// Walk every active workspace, kill its PTYs, and emit workspace.closed
  /// for each. Used by the SIGINT/SIGTERM handler in index.ts.
  public shutdownAll(): void {
    const ids = this.workspaces.disposeAll();
    for (const id of ids) {
      this.broadcastWorkspaceClosed(id);
    }
  }
}
