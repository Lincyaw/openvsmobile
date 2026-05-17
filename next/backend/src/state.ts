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
  /// Process-global diff cache keyed by
  /// `<workspaceId> <path> <baseSha|WT> <workingHash>`. Invalidated by the
  /// drain loop when affected paths show up in `tree.delta` / when HEAD
  /// changes for that workspace.
  ///
  /// Cap is intentionally modest — diff bodies are bounded at 500KB upstream
  /// and we expect single-digit concurrent file viewings on the phone.
  public readonly diffCache = new BoundedMap<string, unknown>(64);

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
    this.workspaces.setInvalidateHook((workspaceId) => {
      this.invalidateDiffsForWorkspace(workspaceId);
    });
  }

  public addSubscriber(s: Subscriber): void {
    this.subscribers.add(s);
  }

  public removeSubscriber(s: Subscriber): void {
    this.subscribers.delete(s);
    // Auto-unsubscribe this ws from every workspace's resident model so we
    // don't leak entries that point at a dead WebSocket.
    for (const info of this.workspaces.listActive()) {
      const ws = this.workspaces.get(info.id);
      if (ws.model !== null) {
        ws.model.removeSubscriber(s.ws);
      }
    }
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

  /// Drop every cached diff that mentions the given workspace. Called from
  /// the workspace model's drain loop on head.changed / tree.delta — we
  /// can't keep diff results valid past a HEAD move because git-diff's
  /// output depends on every blob in the working tree.
  public invalidateDiffsForWorkspace(workspaceId: string): void {
    this.diffCache.deleteWhere((key) => key.startsWith(`${workspaceId} `));
  }
}

/// Insertion-ordered map with a maximum entry count. When `set` would push us
/// past the cap, the oldest entry is evicted. Good-enough LRU substitute when
/// "everything we evict is cheap to recompute".
export class BoundedMap<K, V> {
  private readonly map = new Map<K, V>();
  private readonly cap: number;

  constructor(cap: number) {
    this.cap = cap;
  }

  public get(key: K): V | undefined {
    return this.map.get(key);
  }

  public set(key: K, value: V): void {
    if (this.map.has(key)) this.map.delete(key);
    this.map.set(key, value);
    if (this.map.size > this.cap) {
      const oldest = this.map.keys().next().value;
      if (oldest !== undefined) this.map.delete(oldest);
    }
  }

  public deleteWhere(predicate: (key: K) => boolean): void {
    for (const k of [...this.map.keys()]) {
      if (predicate(k)) this.map.delete(k);
    }
  }

  public size(): number {
    return this.map.size;
  }
}
