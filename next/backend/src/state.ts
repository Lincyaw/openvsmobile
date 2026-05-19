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
import type {
  TerminalSnapshot,
  TerminalPersistenceHook,
} from "./terminal.js";
import type { MultiplexerInfo } from "./multiplexer.js";
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
  /// Per-connection terminal subscription. `true` (or unset, see default
  /// below) means subscribe-all — every `terminal.data` / `terminal.exit`
  /// fans out to this peer. An explicit `terminal.subscribe(ids: string[])`
  /// flips this to a `Set<string>` filtering to a specific set of sessions;
  /// `false` opts out entirely.
  ///
  /// v0 default is implicit subscribe-all: legacy single-client setups that
  /// never call `terminal.subscribe` keep receiving every frame, matching
  /// the prior behavior. Connections that explicitly subscribe to a scoped
  /// set get filtered fan-out per first principle #5.
  terminalsSubscribed?: true | false | Set<string>;
}

export interface ProcessStateOptions {
  /// Override the notifications DB path. Tests pass a temp dir; production
  /// callers leave this undefined and let `notifications.ts` resolve from
  /// $OPENVSMOBILE_NOTIFICATIONS_DB or the default location.
  notificationDbPath?: string;
  /// Plugin host. Optional so unit tests that exercise non-plugin RPCs
  /// can construct a bare ProcessState without spinning up a host. The
  /// production wiring in index.ts always supplies one; UI-related
  /// handlers (`ui.subscribe`, `ui.event`) check for presence and surface
  /// `notReady` when the host is missing.
  pluginHost?: PluginHost;
  /// Multiplexer probe result. When provided and zellij-backed, new
  /// terminals are spawned through `zellij attach --create` so they
  /// survive a backend restart. Defaults to `{ kind: "none" }` — every
  /// non-production caller (tests) gets direct-shell behavior.
  multiplexer?: MultiplexerInfo;
  /// Durable record of (terminalId → external session) pairs. Optional;
  /// when omitted, terminals work but nothing about them is persisted to
  /// disk. Production wires a `TerminalPersistence` here in index.ts.
  terminalPersistence?: TerminalPersistenceHook;
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

  /// Plugin host reference. Optionally seeded via the constructor
  /// (`new ProcessState({ pluginHost })`) for unit tests; production
  /// wires it via late assignment in `index.ts` because the host needs
  /// `state.broadcastPluginStateChanged` for its `onStateChanged` hook
  /// (chicken-and-egg). `rpc.ts` reaches for this via
  /// `ctx.state.pluginHost` to satisfy `plugin.*` and `ui.*` handlers.
  public pluginHost: PluginHost | null = null;

  private readonly subscribers = new Set<Subscriber>();

  constructor(opts: ProcessStateOptions = {}) {
    this.pluginHost = opts.pluginHost ?? null;
    const storeOpts = opts.notificationDbPath
      ? { dbPath: opts.notificationDbPath }
      : {};
    const store = new NotificationStore(storeOpts);
    this.notificationHub = new NotificationHub(store);
    const notifPred = (sub: Subscriber): boolean =>
      sub.notificationsSubscribed === true;
    this.notificationHub.attachFanOut({
      show: (n) =>
        this.broadcast("notification.show", { notification: n }, notifPred),
      superseded: (oldId, newId) =>
        this.broadcast(
          "notification.superseded",
          { oldId, newId },
          notifPred,
        ),
      readChanged: (ids, readByDevice, ts) =>
        this.broadcast(
          "notification.readChanged",
          { ids, readByDevice, ts },
          notifPred,
        ),
      deleted: (ids) => this.broadcast("notification.deleted", { ids }, notifPred),
    });

    const multiplexer: MultiplexerInfo = opts.multiplexer ?? { kind: "none" };
    const terminalPersistence: TerminalPersistenceHook | null =
      opts.terminalPersistence ?? null;
    this.workspaces = new WorkspaceRegistry(
      // terminal data → broadcast filtered by per-connection terminal scope.
      (sessionId, data, seqEnd) => {
        const wsId = this.workspaceIdForTerminal(sessionId);
        if (wsId === null) return;
        const params = {
          sessionId,
          workspaceId: wsId,
          dataBase64: data.toString("base64"),
          seqEnd,
        };
        this.broadcast("terminal.data", params, (sub) =>
          terminalSubscriberMatches(sub, sessionId),
        );
      },
      // terminal exit → broadcast filtered by per-connection terminal scope.
      (sessionId, exitCode) => {
        const wsId = this.workspaceIdForTerminal(sessionId);
        const params = {
          sessionId,
          workspaceId: wsId, // may be null if workspace was already closed
          exitCode,
        };
        this.broadcast("terminal.exit", params, (sub) =>
          terminalSubscriberMatches(sub, sessionId),
        );
      },
      multiplexer,
      terminalPersistence,
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
    // Same shape for the UI panel fan-out — a dropped socket must not
    // continue receiving `ui.tree` pushes.
    if (this.pluginHost !== null) {
      this.pluginHost.uiUnsubscribe(s.ws);
    }
  }

  /// Broadcast a workspace.closed notification to every subscriber. Used both
  /// for user-initiated closes (so two-client scenarios stay in sync) and for
  /// the process-exit graceful shutdown path.
  public broadcastWorkspaceClosed(id: string): void {
    this.broadcast("workspace.closed", { id });
  }

  /// Single fan-out helper. Walks the subscriber set and sends `params`
  /// under `method` to every peer for which `predicate` returns true
  /// (default: every peer). Per-namespace gates collapse into one-line
  /// predicates at the call site — see `broadcastWorkspaceClosed`,
  /// `broadcastPluginStateChanged`, and the notification / terminal
  /// fan-out wiring above.
  public broadcast(
    method: string,
    params: unknown,
    predicate?: (sub: Subscriber) => boolean,
  ): void {
    for (const sub of this.subscribers) {
      if (predicate !== undefined && !predicate(sub)) continue;
      sendNotification(sub.ws, method, params);
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

  /// Walk every active workspace, detach its PTY clients, and emit
  /// workspace.closed for each. Used by the SIGINT/SIGTERM handler in
  /// index.ts. Detach (not destroy) is the right semantic for a
  /// process shutdown: any zellij-backed terminals must keep their DB
  /// rows so the next backend boot can hydrate them. Workspaces
  /// themselves are not persisted, so wiping the in-memory map is
  /// fine.
  public shutdownAll(): void {
    const ids = this.workspaces.detachAllForShutdown();
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

  /// `plugin.stateChanged` fan-out — same per-subscriber subscription
  /// gate as the notification surface. Exposed for the host to call via
  /// the `onStateChanged` constructor hook (see `index.ts`).
  public broadcastPluginStateChanged(change: PluginStateChange): void {
    this.broadcast(
      "plugin.stateChanged",
      change,
      (sub) => sub.pluginsSubscribed === true,
    );
  }
}

/// True when a `terminal.data`/`terminal.exit` frame for `sessionId` should
/// reach `sub`. Default (no explicit subscribe) is subscribe-all — preserves
/// v0 single-client behavior for legacy peers. A `Set<string>` opts into a
/// specific session list; explicit `false` opts out entirely.
function terminalSubscriberMatches(
  sub: Subscriber,
  sessionId: string,
): boolean {
  const t = sub.terminalsSubscribed;
  if (t === undefined || t === true) return true;
  if (t === false) return false;
  if (t.size === 0) return true; // empty set === subscribe-all, see terminal.subscribe
  return t.has(sessionId);
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
