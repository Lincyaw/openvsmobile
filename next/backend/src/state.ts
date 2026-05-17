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
import {
  NotificationHub,
  NotificationStore,
} from "./notifications.js";
import type {
  PluginHost,
  PluginStateChange,
} from "./plugins/host.js";

/// Each authenticated WebSocket registers a Subscriber. The connection is
/// responsible for unregistering when the socket closes.
///
/// `notificationDeviceId` is set during handshake when the client supplies
/// `client.deviceId`. Older clients omit it and get an ephemeral per-
/// connection id so `markRead` calls don't silently no-op — but those reads
/// don't sync to future deviceId-aware sessions (acceptable transition; see
/// task brief §5).
///
/// `notificationsSubscribed` toggles via `notification.subscribe` /
/// `unsubscribe`. The fan-out helper consults it on every emit so a freshly-
/// authenticated connection that hasn't subscribed receives nothing.
///
/// `pluginsSubscribed` is the same pattern for `plugin.stateChanged` pushes;
/// off by default so a connection that doesn't care about the plugin surface
/// (e.g. an older client) doesn't get the frames.
export interface Subscriber {
  readonly ws: WebSocket;
  notificationDeviceId?: string;
  notificationsSubscribed?: boolean;
  pluginsSubscribed?: boolean;
}

export interface ProcessStateOptions {
  /// Override the notifications DB path. Tests pass a temp dir; production
  /// callers leave this undefined and let `notifications.ts` resolve from
  /// $OPENVSMOBILE_NOTIFICATIONS_DB or the default location.
  notificationDbPath?: string;
}

export interface AttachPluginHostFanOut {
  /// `plugin.stateChanged` fan-out target. The host calls this on every
  /// state transition; ProcessState filters down to subscribed peers.
  readonly emitStateChanged: (change: PluginStateChange) => void;
}

export class ProcessState {
  /// The single workspace registry shared by every Connection. Terminal
  /// sinks are wired through this class so the registry stays unaware of
  /// individual subscribers.
  public readonly workspaces: WorkspaceRegistry;
  /// Process-global diff cache keyed by
  /// `<workspaceId> <path> <baseSha|WT> <workingHash>`. LRU-evicted at 64
  /// entries (see BoundedMap below). Invalidated by the drain loop when
  /// affected paths show up in `tree.delta` / when HEAD changes for that
  /// workspace. Diff bodies are bounded at 500KB upstream and we expect
  /// single-digit concurrent file viewings on the phone, so a small cap is
  /// fine.
  public readonly diffCache = new BoundedMap<string, unknown>(64);

  /// Notification persistence + fan-out hub. Survives client disconnects
  /// (like everything else owned by ProcessState).
  public readonly notificationHub: NotificationHub;

  /// Plugin host reference. Wired by `index.ts` after construction so
  /// `ProcessState` doesn't have to know about plugin-host options.
  /// `rpc.ts` reaches for this via `ctx.state.pluginHost` to satisfy
  /// `plugin.list / enable / disable / invokeCommand`.
  public pluginHost: PluginHost | null = null;

  private readonly subscribers = new Set<Subscriber>();

  constructor(opts: ProcessStateOptions = {}) {
    const storeOpts = opts.notificationDbPath
      ? { dbPath: opts.notificationDbPath }
      : {};
    const store = new NotificationStore(storeOpts);
    this.notificationHub = new NotificationHub(store);
    this.notificationHub.attachFanOut({
      show: (n) => this.broadcastNotification("notification.show", { notification: n }),
      superseded: (oldId, newId) =>
        this.broadcastNotification("notification.superseded", { oldId, newId }),
      readChanged: (ids, readByDevice, ts) =>
        this.broadcastNotification("notification.readChanged", {
          ids,
          readByDevice,
          ts,
        }),
      deleted: (ids) => this.broadcastNotification("notification.deleted", { ids }),
    });

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
    this.notificationHub.close();
  }

  /// Drop every cached diff that mentions the given workspace. Called from
  /// the workspace model's drain loop on head.changed / tree.delta — we
  /// can't keep diff results valid past a HEAD move because git-diff's
  /// output depends on every blob in the working tree.
  public invalidateDiffsForWorkspace(workspaceId: string): void {
    this.diffCache.deleteWhere((key) => key.startsWith(`${workspaceId} `));
  }

  /// Broadcast a `notification.*` push frame to every subscriber that has
  /// called `notification.subscribe`. Unsubscribed connections never see
  /// these frames — that's how a foreground service can drop notifications
  /// (e.g. when the user toggles the Settings off) without dropping the
  /// connection.
  private broadcastNotification(method: string, params: unknown): void {
    for (const sub of this.subscribers) {
      if (sub.notificationsSubscribed !== true) continue;
      sendNotification(sub.ws, method, params);
    }
  }

  /// `plugin.stateChanged` fan-out — same per-subscriber subscription
  /// gate as the notification surface. Exposed for the host to call via
  /// the `onStateChanged` constructor hook (see `index.ts`).
  public broadcastPluginStateChanged(change: PluginStateChange): void {
    for (const sub of this.subscribers) {
      if (sub.pluginsSubscribed !== true) continue;
      sendNotification(sub.ws, "plugin.stateChanged", change);
    }
  }
}

/// Bounded LRU map. `get` re-inserts the hit key so recency is honored —
/// a hot diff stays warm even after 64 cold lookups slide past. Eviction
/// fires on `set` when size exceeds cap; the oldest (least-recently-touched)
/// entry goes. O(1) per op via `Map`'s insertion-order semantics.
export class BoundedMap<K, V> {
  private readonly map = new Map<K, V>();
  private readonly cap: number;

  constructor(cap: number) {
    this.cap = cap;
  }

  public get(key: K): V | undefined {
    // Re-insert on hit so this key becomes the newest in iteration order.
    // Cheap because Map.delete + Map.set are both O(1) and we already had
    // the key in hand.
    if (!this.map.has(key)) return undefined;
    const value = this.map.get(key) as V;
    this.map.delete(key);
    this.map.set(key, value);
    return value;
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
