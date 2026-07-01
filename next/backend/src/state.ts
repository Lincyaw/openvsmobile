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
import { WorkspaceRegistry } from "./workspace.js";
import type {
  TerminalSnapshot,
  TerminalPersistenceHook,
} from "./terminal.js";
import { TerminalRegistry } from "./terminal.js";
import {
  listZellijSessions,
  type ExecRunner,
  type ExternalSession,
  type MultiplexerInfo,
} from "./multiplexer.js";
import {
  NotificationHub,
  NotificationStore,
} from "./notifications.js";
import { TokenStore } from "./tokenStore.js";
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
  /// Override the publish-tokens DB path. Same shape as
  /// `notificationDbPath` — tests pass a temp dir; production leaves it
  /// undefined and `tokenStore.ts` resolves from $OPENVSMOBILE_TOKENS_DB
  /// or the default `~/.config/openvsmobile-next/tokens.db`.
  tokensDbPath?: string;
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
  /// Test injection point for zellij CLI calls made from RPC handlers
  /// (currently `terminal.listExternalSessions`). Production leaves this
  /// undefined and the real `execFile`-backed runner kicks in.
  execRunner?: ExecRunner;
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

  /// Process-global terminal registry. Terminal sessions are not owned by
  /// workspaces; a session only carries an optional `workspaceRoot` locator
  /// so the app can jump from Terminal to Files when a matching workspace is
  /// open or can be opened.
  public readonly terminals: TerminalRegistry;
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

  /// Publish-token store. Backs the `auth.publishTokens.*` admin RPCs and
  /// the publish-token auth branch of `/notify` + `/hook`. Separate DB
  /// from notifications: revoking a token must not touch notification
  /// history, and notification GC must not touch tokens.
  public readonly tokenStore: TokenStore;

  /// Plugin host reference. Optionally seeded via the constructor
  /// (`new ProcessState({ pluginHost })`) for unit tests; production
  /// wires it via late assignment in `index.ts` because the host needs
  /// `state.broadcastPluginStateChanged` for its `onStateChanged` hook
  /// (chicken-and-egg). `rpc.ts` reaches for this via
  /// `ctx.state.pluginHost` to satisfy `plugin.*` and `ui.*` handlers.
  public pluginHost: PluginHost | null = null;

  /// Probe result captured at construction. `listExternalSessions` short-
  /// circuits to an empty array when the multiplexer is "none" — there's
  /// nothing to list on a host without zellij.
  public readonly multiplexer: MultiplexerInfo;
  /// Test injection for the zellij CLI; production callers leave this
  /// unset and the real runner kicks in inside `multiplexer.ts`.
  public readonly execRunner: ExecRunner | undefined;

  private readonly subscribers = new Set<Subscriber>();

  constructor(opts: ProcessStateOptions = {}) {
    this.pluginHost = opts.pluginHost ?? null;
    const storeOpts = opts.notificationDbPath
      ? { dbPath: opts.notificationDbPath }
      : {};
    const store = new NotificationStore(storeOpts);
    this.notificationHub = new NotificationHub(store);
    this.tokenStore = new TokenStore(
      opts.tokensDbPath ? { dbPath: opts.tokensDbPath } : {},
    );
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
    this.multiplexer = multiplexer;
    this.execRunner = opts.execRunner;
    const terminalPersistence: TerminalPersistenceHook | null =
      opts.terminalPersistence ?? null;
    const onTerminalDetached = (sessionId: string): void => {
      // `wsId` may be null when the workspace was closed mid-probe (PTY
      // exit fires the probe; user/teardown removes the workspace before
      // it resolves). The wire shape tolerates that — clients consume
      // `workspaceId` as informational only and look the chip up by
      // `sessionId`. Routing is per-session (see `terminalSubscriberMatches`
      // below): the filter only checks the session id, NEVER the
      // workspaceId, so a null workspaceId neither over-delivers to
      // workspace-scoped subscribers (there are none in this codepath)
      // nor under-delivers to per-session subscribers that explicitly
      // asked for this session. Keep that invariant if you ever
      // repurpose `terminalsSubscribed` — workspaceId in the push body
      // is informational, not a routing key.
      const wsId = this.workspaceIdForTerminal(sessionId);
      this.broadcast(
        "terminal.detached",
        {
          sessionId,
          workspaceId: wsId,
          workspaceRoot: this.terminalWorkspaceRoot(sessionId),
        },
        (sub) => terminalSubscriberMatches(sub, sessionId),
      );
    };
    this.terminals = new TerminalRegistry(
      (sessionId, data, seqEnd) => {
        const params = {
          sessionId,
          workspaceId: this.workspaceIdForTerminal(sessionId),
          workspaceRoot: this.terminalWorkspaceRoot(sessionId),
          dataBase64: data.toString("base64"),
          seqEnd,
        };
        this.broadcast("terminal.data", params, (sub) =>
          terminalSubscriberMatches(sub, sessionId),
        );
      },
      (sessionId, exitCode) => {
        const params = {
          sessionId,
          workspaceId: this.workspaceIdForTerminal(sessionId),
          workspaceRoot: this.terminalWorkspaceRoot(sessionId),
          exitCode,
        };
        this.broadcast("terminal.exit", params, (sub) =>
          terminalSubscriberMatches(sub, sessionId),
        );
      },
      {
        multiplexer,
        ...(terminalPersistence !== null
          ? { persistence: terminalPersistence }
          : {}),
        ...(opts.execRunner !== undefined
          ? { execRunner: opts.execRunner }
          : {}),
        onDetached: onTerminalDetached,
      },
    );
    this.terminals.hydrateAllFromPersistence(new Set());
    this.workspaces = new WorkspaceRegistry(
      // Legacy workspace-scoped terminal sinks. Production RPC no longer
      // creates terminals through ActiveWorkspace.terminals; keeping the
      // no-op-compatible sinks preserves older tests and private helpers.
      (sessionId, data, seqEnd) => {
        const params = {
          sessionId,
          workspaceId: this.workspaceIdForTerminal(sessionId),
          workspaceRoot: this.terminalWorkspaceRoot(sessionId),
          dataBase64: data.toString("base64"),
          seqEnd,
        };
        this.broadcast("terminal.data", params, (sub) =>
          terminalSubscriberMatches(sub, sessionId),
        );
      },
      (sessionId, exitCode) => {
        const params = {
          sessionId,
          workspaceId: this.workspaceIdForTerminal(sessionId),
          workspaceRoot: this.terminalWorkspaceRoot(sessionId),
          exitCode,
        };
        this.broadcast("terminal.exit", params, (sub) =>
          terminalSubscriberMatches(sub, sessionId),
        );
      },
      multiplexer,
      null,
      onTerminalDetached,
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
    const snap = this.terminals.getSnapshot(sessionId);
    if (snap === null) return null;
    return this.workspaceIdForRoot(snap.workspaceRoot);
  }

  public terminalWorkspaceRoot(sessionId: string): string | null {
    return this.terminals.getSnapshot(sessionId)?.workspaceRoot ?? null;
  }

  public workspaceIdForRoot(workspaceRoot: string | null): string | null {
    if (workspaceRoot === null) return null;
    for (const info of this.workspaces.listActive()) {
      if (info.root === workspaceRoot) return info.id;
    }
    return null;
  }

  public findSession(sessionId: string): TerminalSnapshot | null {
    return this.terminals.getSnapshot(sessionId);
  }

  public renameTerminal(
    sessionId: string,
    title: string | null,
  ): TerminalSnapshot & { workspaceId: string | null } {
    const snap = this.terminals.rename(sessionId, title);
    const enriched = {
      ...snap,
      workspaceId: this.workspaceIdForRoot(snap.workspaceRoot),
    };
    this.broadcast(
      "terminal.renamed",
      {
        sessionId: snap.id,
        title: snap.title,
        workspaceId: enriched.workspaceId,
        workspaceRoot: snap.workspaceRoot,
      },
      (sub) => terminalSubscriberMatches(sub, sessionId),
    );
    return enriched;
  }

  /// Flat list of every terminal session, each annotated with the currently
  /// open workspaceId matching its workspaceRoot locator, if one exists.
  public listAllTerminals(): Array<
    TerminalSnapshot & { workspaceId: string | null }
  > {
    return this.terminals.list().map((t) => ({
      ...t,
      workspaceId: this.workspaceIdForRoot(t.workspaceRoot),
    }));
  }

  public listTerminalsForWorkspace(workspaceId: string): Array<
    TerminalSnapshot & { workspaceId: string | null }
  > {
    const ws = this.workspaces.get(workspaceId);
    return this.listAllTerminals().filter((t) => t.workspaceRoot === ws.root);
  }

  /// Walk every active workspace, detach its PTY clients, and emit
  /// workspace.closed for each. Used by the SIGINT/SIGTERM handler in
  /// index.ts. Detach (not destroy) is the right semantic for a
  /// process shutdown: any zellij-backed terminals must keep their DB
  /// rows so the next backend boot can hydrate them. Workspaces
  /// themselves are not persisted, so wiping the in-memory map is
  /// fine.
  public shutdownAll(): void {
    this.terminals.detachAll();
    const ids = this.workspaces.detachAllForShutdown();
    for (const id of ids) {
      this.broadcastWorkspaceClosed(id);
    }
    this.notificationHub.close();
    this.tokenStore.close();
  }

  /// Drop every cached diff that mentions the given workspace. Called from
  /// the workspace model's drain loop on head.changed / tree.delta — we
  /// can't keep diff results valid past a HEAD move because git-diff's
  /// output depends on every blob in the working tree.
  public invalidateDiffsForWorkspace(workspaceId: string): void {
    this.diffCache.deleteWhere((key) => key.startsWith(`${workspaceId} `));
  }

  /// External-session discovery for `terminal.listExternalSessions`.
  /// Returns `[]` when the multiplexer probe was "none" — nothing to
  /// list on a host without zellij. Each session is annotated with
  /// `adopted: true` when ANY active workspace's TerminalRegistry has
  /// claimed that name as an externalSessionId; adopted rows render
  /// disabled in the discovery sheet.
  public async listExternalSessions(): Promise<
    Array<ExternalSession & { adopted: boolean }>
  > {
    if (this.multiplexer.kind !== "zellij") return [];
    const sessions = await listZellijSessions(this.execRunner);
    const claimed = new Set<string>();
    for (const name of this.terminals.externalSessionIds()) claimed.add(name);
    return sessions.map((s) => ({ ...s, adopted: claimed.has(s.name) }));
  }

  /// Return true when `sessionName` is currently bound to a terminal in
  /// ANY active workspace's registry. Used by the adoption handler to
  /// refuse double-adoption per the task brief.
  public isExternalSessionAdopted(sessionName: string): boolean {
    return this.terminals.externalSessionIds().includes(sessionName);
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
