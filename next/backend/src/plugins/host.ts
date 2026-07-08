// Plugin host: discovery, registry, capability-gated dispatch.
//
// One PluginHost per backend process. Scans `OPENVSMOBILE_PLUGINS_DIR`
// (default ~/.local/share/openvsmobile-next/plugins/), parses manifests,
// spawns `onStartup`-activated plugins, and dispatches host-bound JSON-RPC
// calls from each plugin. Everything plugin-related stays in this folder;
// the rest of the backend reaches in via PluginHost only.
//
// Host methods exposed to plugins today: `host.log({ level, msg })`. Any
// other namespace from a plugin gets capability-gated and (since no
// other host RPCs are wired yet) ultimately resolves to either
// `-32011 capabilityNotDeclared` (manifest didn't ask for the capability)
// or `-32601 methodNotFound` (manifest declared it but the host has not
// implemented the method yet — landing in C3/C4/C5). The capability
// check runs first, per the conventions doc.
//
// Surface exposed to the frontend (via `rpc.ts`): `plugin.list`,
// `plugin.enable`, `plugin.disable`, `plugin.invokeCommand`, `plugin.log`. Each
// frontend-visible state transition fans a `plugin.stateChanged`
// notification out through the host's onStateChanged callback.

import { existsSync } from "node:fs";
import { open, readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { WebSocket } from "ws";
import { RPC_ERR, RpcError, sendNotification } from "../rpc.js";
import {
  validateNotificationInput,
  type NotificationInput,
} from "../notifications.js";
import {
  loadManifest,
  type ManifestCapabilities,
  type ManifestThemeColor,
  type PluginManifest,
} from "./manifest.js";
import {
  PluginProcess,
  PluginSpawnError,
  type JsonRpcInbound,
} from "./process.js";
import {
  loadPluginState,
  resolveDefaultStateFile,
  savePluginState,
} from "./persistence.js";
import { StderrLog } from "./stderrLog.js";
import {
  UiPanelRegistry,
  UiValidationError,
  validateActionSheet,
  validateAlertDialog,
  validateBottomSheet,
  validateFileUrlsAgainstWorkspace,
  validateUiTree,
  type UiActionSheet,
  type UiAlertDialog,
  type UiBottomSheet,
  type UiNotifier,
  type UiPanelSnapshot,
} from "./ui.js";

export type PluginState =
  | "registered"
  | "active"
  | "crashed"
  | "errored"
  | "disabled";

/// Vocabulary the frontend sees on `plugin.list` and `plugin.stateChanged`.
/// Internal `registered` / `errored` collapse into "stopped" / "crashed" at
/// the wire boundary — the wider internal vocabulary is for host
/// bookkeeping, the wire surface is what the user can act on.
export type WirePluginState = "running" | "stopped" | "crashed" | "disabled";

export interface PluginRegistryEntry {
  id: string;
  dir: string;
  manifest: PluginManifest;
  state: PluginState;
  /// Set when `state === "crashed" | "errored"`. Human-readable.
  reason?: string;
  /// Set when `state === "crashed"`. Last exit code/signal as observed.
  exit?: { code: number | null; signal: NodeJS.Signals | null };
  process?: PluginProcess;
}

export type HostLogLevel = "info" | "warn" | "error";

export interface HostLogEntry {
  pluginId: string;
  level: HostLogLevel;
  msg: string;
  ts: number;
}

/// Wire-shape entry returned by `plugin.list`. Mirrors the structure agreed
/// in the issue ticket; mapping from the internal entry happens in
/// `toWireInfo()` so the shape stays in one place.
export interface PluginInfo {
  id: string;
  name: string;
  version: string;
  state: WirePluginState;
  capabilities: ManifestCapabilities;
  contributes: Record<string, unknown>;
  /// Optional plugin-level brand color (Batch 1 — §4.3). The Flutter host
  /// scopes a Theme override around the plugin's panels so the `brand`
  /// AccentToken resolves to this color inside the panel only.
  themeColor?: ManifestThemeColor;
  crashReason?: string;
}

export interface PluginLogTail {
  id: string;
  path: string;
  text: string;
  bytes: number;
  truncated: boolean;
}

/// Payload emitted to subscribers on every state transition.
export interface PluginStateChange {
  id: string;
  state: WirePluginState;
  crashReason?: string;
}

export interface PluginHostOptions {
  /// Override discovery root. Tests point this at a tempdir; production
  /// reads it from `OPENVSMOBILE_PLUGINS_DIR` and falls back to the
  /// XDG-style default.
  pluginsDir?: string;
  /// Directory for plugin stderr logs. Default
  /// `~/.local/state/openvsmobile-next/plugins/`.
  logDir?: string;
  /// Override the persistence file. Tests point this at a tempfile so they
  /// don't read or write the user's real disabled list.
  stateFile?: string;
  /// SIGTERM-to-SIGKILL grace window (ms) for `disable()`. Default 10000,
  /// per the issue spec. Tunable for tests.
  killGraceMs?: number;
  /// Timeout (ms) for a `plugin.invokeCommand` round-trip. Default 30000.
  /// Tunable for tests.
  invokeTimeoutMs?: number;
  /// Diagnostic logger. Defaults to console.error.
  logger?: (line: string) => void;
  /// Sink for `host.log` calls. The default fan-out routes them through
  /// `logger`. Tests pass a collector to assert delivery.
  onHostLog?: (entry: HostLogEntry) => void;
  /// Called every time a registry entry's wire-state changes. The host
  /// computes the wire state from the internal state + reason; downstream
  /// fan-out lives in `ProcessState`.
  onStateChanged?: (change: PluginStateChange) => void;
  /// Override the `ui.tree` push transport. Tests substitute a recorder
  /// so they can assert which sockets received which pushes without
  /// running a real WebSocket. Defaults to `sendNotification` from rpc.ts.
  uiNotifier?: UiNotifier;
  /// Resolve the currently active workspace root. Used by `ui.render`'s
  /// `file://` URL gate: a `UiImage` / `UiAvatar` with a `file://` src
  /// must resolve inside this directory or the entire render is rejected.
  /// Returning `null` means "no active workspace" — every `file://` URL
  /// is rejected. Tests substitute a fixed string; production wires this
  /// to `ProcessState.workspaces.current()?.root`.
  workspaceRootResolver?: () => string | null;
  /// Resolve the full active workspace descriptor for the `workspace.*`
  /// SDK surface (Phase 0 of the repo-aware plugin work). Returns
  /// `null` when no workspace is active. Production wires this to
  /// `ProcessState.workspaces.current()` projected to `WorkspaceRef`;
  /// tests substitute a stub. Defaults to "no active workspace" so the
  /// host stays usable in isolation (e.g. SDK-only test harnesses).
  workspaceResolver?: () => WorkspaceRef | null;
  /// Sink for plugin-fired notifications (Phase 6A). Receives an
  /// already-source-overridden `NotificationInput`; returns the
  /// store-assigned id. Production wires this to
  /// `state.notificationHub.publish(input)` so the row lands in the
  /// SQLite store and fans out through the existing
  /// `notification.show` WS broadcast. Default is a no-op that returns
  /// a synthetic id so the host stays usable in isolation
  /// (SDK-only test harnesses); production callers always supply one.
  notificationPublisher?: (input: NotificationInput) => { id: string };
}

/// Minimal workspace shape pushed to plugins. Matches the SDK's
/// `WorkspaceRef` interface — id (UUID), absolute root path, label.
/// Carried by the `workspace.current` response and the
/// `workspace.activated` notification.
export interface WorkspaceRef {
  id: string;
  root: string;
  label: string;
}

const DEFAULT_PLUGINS_DIR_REL = [".local", "share", "openvsmobile-next", "plugins"];
const DEFAULT_LOG_DIR_REL = [".local", "state", "openvsmobile-next", "plugins"];

const DEFAULT_KILL_GRACE_MS = 10_000;
const DEFAULT_INVOKE_TIMEOUT_MS = 30_000;

/// Error subclass thrown by the public mutation methods (`enable`,
/// `disable`, `invokeCommand`) so the RPC layer can translate them to the
/// right JSON-RPC error code without leaking host internals. The `code` is
/// the JSON-RPC code; the message is human text.
export class PluginHostError extends Error {
  public readonly code: number;
  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

/// Capability key required by a method namespace.
///
///   * A `keyof ManifestCapabilities` value names a manifest key the
///     plugin must have declared.
///   * `null` means "no capability needed" — currently only `host.*`,
///     where the host log is intentionally always available.
///   * `"deny"` means "no capability can satisfy this method". Used for
///     unknown namespaces so a typo'd or unimplemented namespace doesn't
///     accidentally pass the gate just because the plugin happened to
///     declare some capability. The gate translates `"deny"` to
///     `-32011 capabilityNotDeclared`.
export type CapabilityRequirement = keyof ManifestCapabilities | "deny" | null;

function requiredCapability(method: string): CapabilityRequirement {
  // host.* — uncategorized, always allowed.
  if (method.startsWith("host.")) return null;
  // The plugin-side API surface from §3.6. The map below is the
  // authoritative source of "which capability key gates which method
  // namespace"; widen here when a new host RPC lands.
  if (method.startsWith("fs.") || method.startsWith("workspace.")) return "fs";
  if (method.startsWith("terminal.")) return "terminal";
  // NOTE: `git.*` is intentionally NOT mapped. v0 git is read-only and
  // not implemented at the host yet; when it lands, the author must
  // make an explicit decision about which capability gates it
  // (probably `fs`, but possibly its own key) and add the entry here.
  // Until then, unknown-namespace `"deny"` applies.
  if (method.startsWith("network.")) return "network";
  if (method.startsWith("secrets.")) return "secrets";
  if (method.startsWith("ui.") || method.startsWith("notify.")) return "ui";
  // Unknown namespace → no capability key satisfies it. Return the
  // explicit `"deny"` sentinel so the gate refuses the call instead of
  // falling back to a permissive default.
  return "deny";
}

function pluginHasCapability(
  caps: ManifestCapabilities,
  requirement: CapabilityRequirement,
): boolean {
  if (requirement === null) return true;
  if (requirement === "deny") return false;
  if (requirement === "fs") return caps.fs === "read" || caps.fs === "readwrite";
  return caps[requirement] === true;
}

/// Internal → wire-state collapse. The frontend only needs the four
/// outcomes a user can act on; the wider internal vocabulary stays inside
/// the host.
function toWireState(state: PluginState): WirePluginState {
  switch (state) {
    case "active":
      return "running";
    case "registered":
      return "stopped";
    case "disabled":
      return "disabled";
    case "crashed":
    case "errored":
      return "crashed";
  }
}

interface HostMethodEntry {
  capability: CapabilityRequirement;
  handler: (plugin: PluginProcess, params: unknown) => Promise<unknown>;
}

interface PendingInvoke {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
  pluginId: string;
  timer: NodeJS.Timeout;
}

export class PluginHost {
  private readonly pluginsDir: string;
  private readonly logDir: string;
  private readonly stateFile: string;
  private readonly killGraceMs: number;
  private readonly invokeTimeoutMs: number;
  private readonly logger: (line: string) => void;
  private readonly onHostLog: (entry: HostLogEntry) => void;
  private readonly onStateChanged?: (change: PluginStateChange) => void;
  private readonly plugins = new Map<string, PluginRegistryEntry>();
  /// Persistent disabled set. Loaded from disk on construction; mirrored to
  /// disk on every `enable` / `disable` call. The registry tracks both an
  /// in-memory entry state (which can be `disabled`) and this set so a
  /// plugin we discovered for the first time after a disable can still
  /// land as `disabled` instead of being auto-spawned by `onStartup`.
  private readonly disabled: Set<string>;
  /// Counter for outgoing requests we initiate toward plugins
  /// (`command.invoke`, `ui.event`, future `initialize`). One monotonic
  /// source covers every plugin.
  private nextOutboundId = 1;
  /// Pending `command.invoke` requests keyed by outbound id. The plugin
  /// must respond with the same id; we resolve / reject the awaiter and
  /// drop the entry.
  private readonly pendingInvokes = new Map<number, PendingInvoke>();
  /// UI descriptor cache + subscriber fan-out (design §4.3). Owned by the
  /// host because plugin lifecycle drives panel lifecycle: plugin exit /
  /// disable retires every panel the plugin had emitted.
  private readonly uiRegistry: UiPanelRegistry;
  /// Resolves the active workspace root for `file://` URL gating. See
  /// `PluginHostOptions.workspaceRootResolver`. Defaults to "no active
  /// workspace" — every `file://` URL is rejected until production wires
  /// `state.workspaces.current()?.root` here.
  private readonly workspaceRootResolver: () => string | null;
  /// Resolves the active workspace descriptor for the `workspace.current`
  /// plugin-host RPC. See `PluginHostOptions.workspaceResolver`. Defaults
  /// to "no active workspace" — production wires this to the workspace
  /// registry in `index.ts`.
  private readonly workspaceResolver: () => WorkspaceRef | null;
  /// Publishes a (source-overridden) notification into the host's store +
  /// fan-out. See `PluginHostOptions.notificationPublisher`. Defaults to
  /// a synthetic-id no-op so the host runs in isolation; production
  /// wires this to `state.notificationHub.publish` in `index.ts`.
  private readonly notificationPublisher: (
    input: NotificationInput,
  ) => { id: string };

  constructor(opts: PluginHostOptions = {}) {
    this.pluginsDir = opts.pluginsDir ?? resolveDefaultPluginsDir();
    this.logDir = opts.logDir ?? resolveDefaultLogDir();
    this.stateFile = opts.stateFile ?? resolveDefaultStateFile();
    this.killGraceMs = opts.killGraceMs ?? DEFAULT_KILL_GRACE_MS;
    this.invokeTimeoutMs = opts.invokeTimeoutMs ?? DEFAULT_INVOKE_TIMEOUT_MS;
    this.logger = opts.logger ?? ((line) => console.error(line));
    this.onHostLog =
      opts.onHostLog ??
      ((entry) =>
        this.logger(
          `[plugin:${entry.pluginId}] ${entry.level}: ${entry.msg}`,
        ));
    if (opts.onStateChanged !== undefined) {
      this.onStateChanged = opts.onStateChanged;
    }
    this.disabled = loadPluginState(this.stateFile, this.logger);
    const uiNotifier: UiNotifier =
      opts.uiNotifier ??
      ((ws, method, params) => sendNotification(ws, method, params));
    this.uiRegistry = new UiPanelRegistry(uiNotifier);
    this.workspaceRootResolver = opts.workspaceRootResolver ?? (() => null);
    this.workspaceResolver = opts.workspaceResolver ?? (() => null);
    this.notificationPublisher =
      opts.notificationPublisher ??
      ((_input) => ({ id: `unwired-${Date.now()}` }));
  }

  /// UI panel registry. Public so the RPC layer can route `ui.subscribe`
  /// and `state.removeSubscriber` to it.
  public get ui(): UiPanelRegistry {
    return this.uiRegistry;
  }

  /// Public read-only view of the registry. Tests + `plugin.list` reach
  /// for this. Note that callers receive live references, not copies — do
  /// not mutate.
  public list(): PluginRegistryEntry[] {
    return [...this.plugins.values()];
  }

  /// Wire-shape projection of the registry, exactly what `plugin.list`
  /// returns to the client.
  public listInfo(): PluginInfo[] {
    return this.list().map((e) => this.toWireInfo(e));
  }

  public get(id: string): PluginRegistryEntry | undefined {
    return this.plugins.get(id);
  }

  /// Read the tail of a plugin's stderr log. The caller must name a
  /// registered plugin id; this keeps the file read pinned to the host's
  /// own log directory instead of accepting arbitrary paths from the
  /// client. Missing log files are normal for never-started plugins and
  /// return an empty tail.
  public async readLogTail(id: string, maxBytes: number): Promise<PluginLogTail> {
    if (!this.plugins.has(id)) {
      throw new PluginHostError(RPC_ERR.invalidParams, `no such plugin: ${id}`);
    }
    const cap = Math.max(1, Math.min(Math.floor(maxBytes), 256 * 1024));
    const path = join(this.logDir, `${id}.stderr.log`);
    try {
      const info = await stat(path);
      const bytes = info.size;
      const start = Math.max(0, bytes - cap);
      const length = bytes - start;
      if (length === 0) {
        return { id, path, text: "", bytes, truncated: false };
      }
      const handle = await open(path, "r");
      try {
        const buffer = Buffer.alloc(length);
        await handle.read(buffer, 0, length, start);
        return {
          id,
          path,
          text: buffer.toString("utf8"),
          bytes,
          truncated: start > 0,
        };
      } finally {
        await handle.close();
      }
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") {
        return { id, path, text: "", bytes: 0, truncated: false };
      }
      throw err;
    }
  }

  /// Plugins directory the host is configured to scan. Lets tests
  /// confirm env-var override took effect.
  public dir(): string {
    return this.pluginsDir;
  }

  /// Persistence path. Exposed so tests can inspect the on-disk state
  /// after `enable`/`disable` mutations.
  public stateFilePath(): string {
    return this.stateFile;
  }

  /// Discover everything on disk and start `onStartup` plugins that have
  /// not been explicitly disabled. Safe to call once at backend boot. If
  /// the plugins directory is missing entirely we treat that as "no
  /// plugins installed" — not an error.
  public async start(): Promise<void> {
    await this.discover();
    for (const entry of this.plugins.values()) {
      if (entry.state !== "registered") continue;
      if (!entry.manifest.activation.includes("onStartup")) {
        this.logger(
          `[plugin:${entry.id}] lazy activation (events: ${entry.manifest.activation.join(",") || "(none)"})`,
        );
        continue;
      }
      await this.activate(entry);
    }
  }

  /// Tear every plugin process down. Sends SIGTERM and escalates to
  /// SIGKILL after `killGraceMs` so a wedged plugin doesn't block
  /// backend shutdown. Called from the backend's shutdown handler.
  ///
  /// Returns a promise that resolves once every child has actually
  /// exited. Synchronous callers (signal handlers) may fire-and-forget
  /// — the inner termination is still scheduled.
  public async shutdown(): Promise<void> {
    for (const [, pending] of this.pendingInvokes) {
      clearTimeout(pending.timer);
      pending.reject(new Error("backend shutting down"));
    }
    this.pendingInvokes.clear();
    const pending: Promise<void>[] = [];
    for (const entry of this.plugins.values()) {
      if (entry.process !== undefined) {
        // Reuse the same SIGTERM-then-SIGKILL escalation the disable
        // path uses, so shutdown can't hang on an uncooperative
        // plugin. We don't flip state to `disabled` here — the
        // process is exiting because the backend is, not because the
        // user disabled the plugin.
        pending.push(entry.process.terminate(this.killGraceMs));
      }
    }
    await Promise.all(pending);
  }

  /// Walk the plugins directory. Each direct child that contains a
  /// `plugin.json` becomes a `registered` entry (or `disabled` if the
  /// state file said so). Mismatched id, parse errors, and missing
  /// manifest files are surfaced through the entry state — invalid
  /// plugins land as `errored` so the host can still report them to the
  /// Plugins tab without erroring the whole backend.
  private async discover(): Promise<void> {
    let dirents: import("node:fs").Dirent[];
    try {
      dirents = await readdir(this.pluginsDir, { withFileTypes: true });
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (code === "ENOENT") {
        this.logger(
          `[plugins] plugins dir ${this.pluginsDir} does not exist; nothing to load`,
        );
        return;
      }
      this.logger(
        `[plugins] cannot read plugins dir ${this.pluginsDir}: ${(err as Error).message}`,
      );
      return;
    }
    for (const dirent of dirents) {
      if (!dirent.isDirectory() && !dirent.isSymbolicLink()) continue;
      const subdir = join(this.pluginsDir, dirent.name);
      // Resolve symlinks but be tolerant of dangling ones.
      try {
        const s = await stat(subdir);
        if (!s.isDirectory()) continue;
      } catch {
        continue;
      }
      await this.registerOne(dirent.name, subdir);
    }
  }

  private async registerOne(dirId: string, dir: string): Promise<void> {
    // No plugin.json → skip silently per §3.1. Check up front so the
    // parse path stays focused on real validation failures.
    if (!existsSync(join(dir, "plugin.json"))) return;
    try {
      const { manifest, warnings } = await loadManifest(dir, dirId);
      for (const w of warnings) {
        this.logger(`[plugin:${dirId}] ${w}`);
      }
      // Honor the persisted disabled set: if the user disabled this
      // plugin before the last restart, land it in `disabled` so
      // `onStartup` activation doesn't fire and the wire state reads
      // "disabled" from the first `plugin.list` call.
      const initialState: PluginState = this.disabled.has(dirId)
        ? "disabled"
        : "registered";
      this.plugins.set(dirId, {
        id: dirId,
        dir,
        manifest,
        state: initialState,
      });
    } catch (err) {
      // Synthesize a minimal "errored" entry so the future Plugins tab
      // sees the broken manifest instead of pretending the directory
      // doesn't exist. We don't have a manifest to attach, so this is a
      // sentinel-style entry: the registry consumer must tolerate
      // entries with `state === "errored"` and no live manifest.
      const reason = (err as Error).message;
      this.logger(`[plugin:${dirId}] manifest error: ${reason}`);
      this.plugins.set(dirId, {
        id: dirId,
        dir,
        // Placeholder — the manifest is missing/invalid. Consumers
        // check `state === "errored"` before using any other field.
        manifest: {
          id: dirId,
          name: dirId,
          version: "0.0.0",
          entry: { kind: "node", path: "" },
          activation: [],
          capabilities: {
            fs: "none",
            terminal: false,
            network: false,
            secrets: false,
            ui: false,
          },
          contributes: { commands: [], unknown: {} },
          unknown: {},
        },
        state: "errored",
        reason,
      });
    }
  }

  /// Spawn a plugin's process and wire its message handler. Idempotent on
  /// `active`: a re-activate on an already-active plugin is a no-op.
  /// Disabled / errored entries cannot be activated through this path —
  /// the caller is responsible for transitioning through `enable()`
  /// first.
  public async activate(entry: PluginRegistryEntry): Promise<void> {
    if (entry.state === "active") return;
    if (entry.state === "disabled") return;
    if (entry.state === "errored") return;
    const logPath = join(this.logDir, `${entry.id}.stderr.log`);
    const stderr = new StderrLog(logPath);
    const proc = new PluginProcess({
      manifest: entry.manifest,
      dir: entry.dir,
      stderr,
      onMessage: (p, msg) => this.handlePluginMessage(p, msg),
      onExit: (info) => this.handlePluginExit(entry, info),
      logger: this.logger,
    });
    try {
      await proc.start();
    } catch (err) {
      if (err instanceof PluginSpawnError) {
        this.setState(entry, "errored", err.message);
        this.logger(`[plugin:${entry.id}] refused to spawn: ${err.message}`);
        return;
      }
      throw err;
    }
    entry.process = proc;
    this.setState(entry, "active");
    this.logger(`[plugin:${entry.id}] spawned pid=${proc.pid() ?? "?"}`);
  }

  /// Transition state, clearing any stale `reason` unless the caller
  /// supplies a new one. Emits `onStateChanged` only when the wire-state
  /// actually changes — internal `registered` → `errored` collapses to
  /// `stopped` → `crashed`, but a `registered` → `registered` no-op is
  /// suppressed.
  private setState(
    entry: PluginRegistryEntry,
    next: PluginState,
    reason?: string,
  ): void {
    const wireBefore = toWireState(entry.state);
    const reasonBefore = entry.reason;
    entry.state = next;
    if (reason !== undefined) {
      entry.reason = reason;
    } else if (next !== "crashed" && next !== "errored") {
      // Leaving crashed/errored → reason is no longer meaningful.
      entry.reason = undefined;
    }
    const wireAfter = toWireState(next);
    if (this.onStateChanged !== undefined) {
      const reasonAfter = entry.reason;
      if (wireBefore !== wireAfter || reasonBefore !== reasonAfter) {
        const change: PluginStateChange = {
          id: entry.id,
          state: wireAfter,
        };
        if (entry.reason !== undefined) {
          change.crashReason = entry.reason;
        }
        this.onStateChanged(change);
      }
    }
  }

  private handlePluginExit(
    entry: PluginRegistryEntry,
    info: { code: number | null; signal: NodeJS.Signals | null },
  ): void {
    // No automatic restart (settled decision; CLAUDE.md). Disabled plugins
    // that were just terminated via `disable()` land here too — their
    // state has already been set to `disabled` so we leave it alone. A
    // crash of a previously-active plugin transitions to `crashed`.
    entry.exit = info;
    if (entry.state === "active") {
      this.setState(entry, "crashed", explainExit(info));
      this.logger(
        `[plugin:${entry.id}] crashed: ${entry.reason} (no automatic restart)`,
      );
    }
    entry.process = undefined;
    // Reject any pending invokes targeted at this plugin — without this
    // their await would block until the timeout fires.
    for (const [outboundId, pending] of this.pendingInvokes) {
      if (pending.pluginId !== entry.id) continue;
      clearTimeout(pending.timer);
      this.pendingInvokes.delete(outboundId);
      pending.reject(
        new PluginHostError(
          RPC_ERR.internal,
          `plugin ${entry.id} exited before responding to command.invoke`,
        ),
      );
    }
    // Retire any panels this plugin had emitted so the app drops its
    // cached UI. Safe to call even when the plugin never rendered — the
    // registry just returns an empty list.
    this.uiRegistry.retirePlugin(entry.id);
  }

  private handlePluginMessage(
    plugin: PluginProcess,
    msg: JsonRpcInbound,
  ): void {
    // Requests carry an id; notifications don't. Plugins may also send
    // responses to host-initiated requests (currently `command.invoke`,
    // and fire-and-forget `ui.event`); route those back to the pending
    // awaiter when one exists, otherwise log and drop.
    if (msg.method === undefined) {
      this.handlePluginResponse(plugin, msg);
      return;
    }
    void this.dispatchPluginRequest(plugin, msg);
  }

  private handlePluginResponse(
    plugin: PluginProcess,
    msg: JsonRpcInbound,
  ): void {
    const id = msg.id;
    if (typeof id !== "number") {
      this.logger(
        `[plugin:${plugin.manifest.id}] discarding response with non-numeric id`,
      );
      return;
    }
    const pending = this.pendingInvokes.get(id);
    if (pending === undefined) {
      this.logger(
        `[plugin:${plugin.manifest.id}] discarding response for unknown id ${id}`,
      );
      return;
    }
    // Cross-plugin spoofing guard: outbound ids are minted from a single
    // monotonic counter shared across every plugin, so plugin B could in
    // principle observe (via leaked logs, timing, or a malicious SDK
    // fork) plugin A's pending id and respond to it. Drop the response
    // — do NOT resolve plugin A's promise — and leave the pending entry
    // in place so the legitimate response (or timeout) still lands.
    if (pending.pluginId !== plugin.manifest.id) {
      this.logger(
        `[plugin:${plugin.manifest.id}] discarding response for id ${id}: belongs to plugin "${pending.pluginId}"`,
      );
      return;
    }
    clearTimeout(pending.timer);
    this.pendingInvokes.delete(id);
    if (msg.error !== undefined) {
      const code = msg.error.code ?? RPC_ERR.internal;
      pending.reject(
        new PluginHostError(
          code,
          msg.error.message ?? "plugin returned an error response",
        ),
      );
      return;
    }
    pending.resolve(msg.result);
  }

  private async dispatchPluginRequest(
    plugin: PluginProcess,
    msg: JsonRpcInbound,
  ): Promise<void> {
    const method = msg.method;
    if (typeof method !== "string") return; // already filtered, kept for narrowing
    // Capability gate first. The conventions doc is explicit: capability
    // gating is centralized, not scattered through handlers. The host
    // method table (`HOST_METHODS`) is the source of truth for declared
    // methods; unknown namespaces fall back to `requiredCapability`,
    // which returns `"deny"` so the gate refuses the call.
    const tableEntry = this.hostMethods.get(method);
    const required: CapabilityRequirement =
      tableEntry !== undefined
        ? tableEntry.capability
        : requiredCapability(method);
    if (!pluginHasCapability(plugin.manifest.capabilities, required)) {
      const label =
        required === "deny" ? `unknown namespace` : `capability "${required}"`;
      this.respond(plugin, msg.id, {
        code: RPC_ERR.capabilityNotDeclared,
        message: `capabilityNotDeclared: ${method} requires ${label}`,
      });
      return;
    }
    try {
      const result = await this.callHostMethod(
        plugin,
        method,
        msg.params,
        tableEntry,
      );
      this.respond(plugin, msg.id, undefined, result);
    } catch (err) {
      const code =
        err && typeof err === "object" && "code" in err
          ? (err as { code: number }).code
          : RPC_ERR.internal;
      const message = err instanceof Error ? err.message : String(err);
      this.respond(plugin, msg.id, { code, message });
    }
  }

  private respond(
    plugin: PluginProcess,
    id: string | number | undefined,
    error?: { code: number; message: string; data?: unknown },
    result?: unknown,
  ): void {
    if (id === undefined) return; // notification — no response expected
    if (error !== undefined) {
      plugin.send({ jsonrpc: "2.0", id, error });
    } else {
      plugin.send({ jsonrpc: "2.0", id, result: result ?? {} });
    }
  }

  /// Single source of truth for host-method dispatch. Each row pairs a
  /// `CapabilityRequirement` with a handler — `dispatchPluginRequest`
  /// reads BOTH from this map. There is no separate `if (method === …)`
  /// ladder, so adding a method here cannot fall out of sync with the
  /// capability gate by construction.
  ///
  /// The table is populated lazily in `ensureHostMethods()` because
  /// arrow-handler references to `this.*` are bound only after
  /// construction.
  private hostMethodsCache: Map<string, HostMethodEntry> | null = null;
  private get hostMethods(): Map<string, HostMethodEntry> {
    if (this.hostMethodsCache !== null) return this.hostMethodsCache;
    const t = new Map<string, HostMethodEntry>();
    t.set("host.log", {
      capability: null,
      handler: async (plugin, params) => {
        this.handleHostLog(plugin.manifest.id, params);
        return {};
      },
    });
    t.set("ui.render", {
      capability: "ui",
      handler: async (plugin, params) => {
        await this.handleUiRender(plugin, params);
        return {};
      },
    });
    t.set("ui.showAlert", {
      capability: "ui",
      handler: (plugin, params) => this.handleShowAlert(plugin, params),
    });
    t.set("ui.showActionSheet", {
      capability: "ui",
      handler: (plugin, params) => this.handleShowActionSheet(plugin, params),
    });
    t.set("ui.showBottomSheet", {
      capability: "ui",
      handler: (plugin, params) => this.handleShowBottomSheet(plugin, params),
    });
    t.set("workspace.current", {
      // Plugin-side analogue of the frontend's `workspace.current` RPC:
      // a content-free request that returns the active workspace
      // (`{ workspace: WorkspaceRef | null }`) so a repo-aware plugin
      // can do an initial read without waiting for the first
      // `workspace.activated` notification.
      capability: "fs",
      handler: async () => ({ workspace: this.workspaceResolver() }),
    });
    t.set("notify.show", {
      capability: "ui",
      handler: async (plugin, params) => this.handleNotifyShow(plugin, params),
    });
    this.hostMethodsCache = t;
    return t;
  }

  private async callHostMethod(
    plugin: PluginProcess,
    method: string,
    params: unknown,
    tableEntry: HostMethodEntry | undefined,
  ): Promise<unknown> {
    if (tableEntry !== undefined) {
      return await tableEntry.handler(plugin, params);
    }
    // Capability passed, but the method itself doesn't exist yet.
    // Surface as methodNotFound so a plugin author has a clear signal
    // that they declared a capability but the host hasn't wired the
    // corresponding API in this build.
    throw new RpcError(
      RPC_ERR.methodNotFound,
      `unknown host method: ${method}`,
    );
  }

  private handleHostLog(pluginId: string, params: unknown): void {
    if (!params || typeof params !== "object" || Array.isArray(params)) {
      const err = new Error("host.log params must be an object") as Error & {
        code: number;
      };
      err.code = RPC_ERR.invalidParams;
      throw err;
    }
    const p = params as Record<string, unknown>;
    const level = p.level;
    if (level !== "info" && level !== "warn" && level !== "error") {
      const err = new Error(
        'host.log level must be "info" | "warn" | "error"',
      ) as Error & { code: number };
      err.code = RPC_ERR.invalidParams;
      throw err;
    }
    const msg = p.msg;
    if (typeof msg !== "string") {
      const err = new Error("host.log msg must be a string") as Error & {
        code: number;
      };
      err.code = RPC_ERR.invalidParams;
      throw err;
    }
    this.onHostLog({ pluginId, level, msg, ts: Date.now() });
  }

  /// Plugin-fired notification (Phase 6A). Params shape:
  /// `{ input: NotificationInput }`. The capability gate (`ui` via the
  /// `notify.*` → `ui` mapping in `requiredCapability`) has already run
  /// upstream, so we know the plugin declared `ui`.
  ///
  /// Security: we override `input.source = plugin.id` BEFORE validation
  /// + publish. The hub's existing `add`/`publish` path trusts whatever
  /// `source` the caller passes, which is correct for host-invoked
  /// callers — but a plugin must NOT be able to claim
  /// `source: "system"` or another plugin's id. Overriding at the
  /// handler boundary keeps the change self-contained: no API
  /// modification to `NotificationStore.insert` or `NotificationHub.publish`.
  ///
  /// Validation errors propagate as `RpcError(invalidParams)` (the
  /// dispatcher reads `err.code` and rewrites the JSON-RPC error frame).
  /// Returns `{ id }` — the store-assigned notification id, so the
  /// plugin can correlate it with later `supersedes` calls.
  private handleNotifyShow(
    plugin: PluginProcess,
    params: unknown,
  ): { id: string } {
    if (!params || typeof params !== "object" || Array.isArray(params)) {
      throw new RpcError(
        RPC_ERR.invalidParams,
        "notify.show params must be an object",
      );
    }
    const p = params as Record<string, unknown>;
    const raw = p.input;
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new RpcError(
        RPC_ERR.invalidParams,
        "notify.show params.input must be an object",
      );
    }
    // Source override BEFORE validation. The validator requires
    // a non-empty string `source`; injecting the plugin id here means
    // a plugin that omits `source` (correct usage — the field is
    // host-overwritten anyway) still passes validation.
    const overridden = {
      ...(raw as Record<string, unknown>),
      source: plugin.manifest.id,
    };
    const input = validateNotificationInput(overridden);
    return this.notificationPublisher(input);
  }

  /// Reserve an outbound id for a host→plugin request. Used by
  /// `command.invoke` (whose response router uses `pendingInvokes`) and
  /// by `dispatchUiEvent` (fire-and-forget).
  public allocateOutboundId(): number {
    return this.nextOutboundId++;
  }

  /// @internal — test-only seam. Returns the id the next `allocateOutboundId`
  /// call will mint, without advancing the counter. Used by the
  /// id-collision test so it can tell a fixture which id to forge without
  /// hard-coding `1` (which silently lies if a future host change consumes
  /// an id between construction and the first invoke).
  public _peekNextOutboundIdForTests(): number {
    return this.nextOutboundId;
  }

  // ----- Frontend-facing surface: enable / disable / invokeCommand -----

  /// Project an internal registry entry to the wire-shape the frontend
  /// sees. `crashReason` shows up for `crashed` (which collapses internal
  /// `errored` too) so a broken manifest is observable on the UI.
  public toWireInfo(entry: PluginRegistryEntry): PluginInfo {
    const info: PluginInfo = {
      id: entry.id,
      name: entry.manifest.name,
      version: entry.manifest.version,
      state: toWireState(entry.state),
      capabilities: entry.manifest.capabilities,
      contributes: {
        ...entry.manifest.contributes.unknown,
        commands: entry.manifest.contributes.commands,
      },
    };
    if (entry.manifest.themeColor !== undefined) {
      info.themeColor = entry.manifest.themeColor;
    }
    if (info.state === "crashed" && entry.reason !== undefined) {
      info.crashReason = entry.reason;
    }
    return info;
  }

  /// Re-enable a plugin. Removes it from the persisted disabled set and,
  /// if it was in-memory `disabled`, transitions it back to `registered`
  /// (then immediately activates if the manifest declares `onStartup`).
  /// Calling on an already-enabled plugin is a no-op that still returns
  /// `{ ok: true }` so the client can fire-and-forget.
  public async enable(id: string): Promise<void> {
    const entry = this.plugins.get(id);
    if (entry === undefined) {
      throw new PluginHostError(
        RPC_ERR.invalidParams,
        `no such plugin: ${id}`,
      );
    }
    if (this.disabled.has(id)) {
      this.disabled.delete(id);
      this.persist();
    }
    if (entry.state !== "disabled") return;
    // Reset the entry to `registered` so the activation path sees a
    // valid starting state. `errored` plugins keep their original
    // disable→errored chain — we can't fix a broken manifest here.
    this.setState(entry, "registered");
    if (entry.manifest.activation.includes("onStartup")) {
      await this.activate(entry);
    }
  }

  /// Disable a plugin. Marks it disabled, persists, then terminates the
  /// child process if one is running. SIGTERM → 10s grace → SIGKILL. The
  /// `exit` handler will see `state === "disabled"` and leave it alone.
  public async disable(id: string): Promise<void> {
    const entry = this.plugins.get(id);
    if (entry === undefined) {
      throw new PluginHostError(
        RPC_ERR.invalidParams,
        `no such plugin: ${id}`,
      );
    }
    if (!this.disabled.has(id)) {
      this.disabled.add(id);
      this.persist();
    }
    if (entry.state === "disabled") return;
    const wasActive = entry.state === "active" && entry.process !== undefined;
    // Flip state BEFORE the kill so the exit handler doesn't transition
    // through `crashed` on the way out.
    this.setState(entry, "disabled");
    if (wasActive && entry.process !== undefined) {
      await entry.process.terminate(this.killGraceMs);
    }
  }

  /// Invoke a command on a plugin. Triggers `onCommand:<commandId>`
  /// activation if the plugin is in the `stopped` (registered) state and
  /// the activation event matches. Sends `command.invoke` to the plugin
  /// over its JSON-RPC channel; awaits the plugin's response.
  public async invokeCommand(
    id: string,
    commandId: string,
    args: unknown,
  ): Promise<unknown> {
    const entry = this.plugins.get(id);
    if (entry === undefined) {
      throw new PluginHostError(
        RPC_ERR.invalidParams,
        `no such plugin: ${id}`,
      );
    }
    if (entry.state === "disabled") {
      throw new PluginHostError(
        RPC_ERR.invalidParams,
        `plugin ${id} is disabled`,
      );
    }
    if (entry.state === "errored") {
      throw new PluginHostError(
        RPC_ERR.invalidParams,
        `plugin ${id} is in errored state: ${entry.reason ?? "unknown"}`,
      );
    }
    if (entry.state === "crashed") {
      // The settled "no automatic restart" decision means we can't
      // resurrect a crashed plugin even on an explicit command call.
      // The user must re-enable (or fix the underlying problem) first.
      throw new PluginHostError(
        RPC_ERR.invalidParams,
        `plugin ${id} crashed; restart it before invoking commands`,
      );
    }
    if (entry.state === "registered") {
      const matches = entry.manifest.activation.includes(
        `onCommand:${commandId}`,
      );
      if (!matches) {
        throw new PluginHostError(
          RPC_ERR.invalidParams,
          `plugin ${id} is not active and does not list onCommand:${commandId}`,
        );
      }
      await this.activate(entry);
      // Activation may have failed (errored after spawn). Re-check via
      // a fresh lookup so the type narrowing doesn't lie — the if-block
      // above gave the compiler "registered" but activate() mutates the
      // entry in place.
      const reread = this.plugins.get(id);
      if (reread === undefined || reread.state !== "active") {
        throw new PluginHostError(
          RPC_ERR.internal,
          `plugin ${id} failed to activate: ${reread?.reason ?? "unknown"}`,
        );
      }
    }
    // Whitelist commandId against the manifest's contributed commands.
    // Plugins could in principle handle commands not listed in
    // `contributes.commands`, but the manifest is the contract — making
    // the host the source of truth here keeps the model honest.
    const declared = entry.manifest.contributes.commands.find(
      (c) => c.id === commandId,
    );
    if (declared === undefined) {
      throw new PluginHostError(
        RPC_ERR.invalidParams,
        `plugin ${id} does not contribute command ${commandId}`,
      );
    }
    if (entry.process === undefined) {
      throw new PluginHostError(
        RPC_ERR.internal,
        `plugin ${id} is active but has no live process`,
      );
    }
    return await this.sendCommandInvoke(
      entry.process,
      entry.id,
      commandId,
      args,
    );
  }

  private sendCommandInvoke(
    plugin: PluginProcess,
    pluginId: string,
    commandId: string,
    args: unknown,
  ): Promise<unknown> {
    const outboundId = this.allocateOutboundId();
    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingInvokes.delete(outboundId);
        reject(
          new PluginHostError(
            RPC_ERR.internal,
            `plugin ${pluginId} did not respond to command.invoke within ${this.invokeTimeoutMs}ms`,
          ),
        );
      }, this.invokeTimeoutMs);
      this.pendingInvokes.set(outboundId, {
        resolve,
        reject,
        pluginId,
        timer,
      });
      plugin.send({
        jsonrpc: "2.0",
        id: outboundId,
        method: "command.invoke",
        params: { id: commandId, args },
      });
    });
  }

  private persist(): void {
    try {
      savePluginState(this.stateFile, this.disabled);
    } catch (err) {
      // The on-disk file is best-effort: if we can't write it we still
      // honor the in-memory state, but a future restart won't pick it up.
      this.logger(
        `[plugins] failed to write state file ${this.stateFile}: ${(err as Error).message}`,
      );
    }
  }

  private async handleUiRender(
    plugin: PluginProcess,
    params: unknown,
  ): Promise<void> {
    if (!params || typeof params !== "object" || Array.isArray(params)) {
      const err = new Error(
        "ui.render params must be an object",
      ) as Error & { code: number };
      err.code = RPC_ERR.invalidParams;
      throw err;
    }
    const p = params as Record<string, unknown>;
    const panelId = p.panelId;
    if (typeof panelId !== "string" || panelId.length === 0) {
      const err = new Error(
        "ui.render panelId must be a non-empty string",
      ) as Error & { code: number };
      err.code = RPC_ERR.invalidParams;
      throw err;
    }
    let tree;
    try {
      tree = validateUiTree(p.tree);
    } catch (err) {
      if (err instanceof UiValidationError) {
        const out = new Error(`ui.render: ${err.message}`) as Error & {
          code: number;
        };
        out.code = RPC_ERR.invalidParams;
        throw out;
      }
      throw err;
    }
    // Batch 3 file:// URL gate. See validateFileUrlsAgainstWorkspace.
    // Async because the gate `fs.realpath`s every file:// URL so a
    // symlink inside the workspace pointing outside it can't bypass
    // the prefix check — matches the `fs.*` RPCs' isolation discipline.
    // Rejecting the whole `ui.render` (not just the offending node) is
    // intentional: a partial render would leave the plugin's state
    // desynced from the panel's contents, and a single bad node is a
    // plugin-author bug they should see clearly.
    const gate = await validateFileUrlsAgainstWorkspace(
      tree,
      plugin.manifest.capabilities.fs,
      this.workspaceRootResolver(),
    );
    if (!gate.ok) {
      const code =
        gate.code === "capabilityNotDeclared"
          ? RPC_ERR.capabilityNotDeclared
          : RPC_ERR.invalidParams;
      const out = new Error(`ui.render: ${gate.message}`) as Error & {
        code: number;
      };
      out.code = code;
      throw out;
    }
    this.uiRegistry.render(plugin.manifest.id, panelId, tree);
  }

  // ----- Batch 4 imperative modal entry points -----
  //
  // Each `ui.show*` method validates the params, broadcasts a `ui.modal`
  // notification to subscribed clients via `UiPanelRegistry.broadcastModal`,
  // and returns `{ delivered: true }` to the calling plugin so the plugin's
  // await resolves once the push has been dispatched. The user's pick (or
  // dismiss) flows back via the regular `ui.event` channel — there is no
  // synchronous "wait for pick" round-trip on the host side.

  private parseShowParams(method: string, params: unknown): {
    panelId: string;
    rest: Record<string, unknown>;
  } {
    if (!params || typeof params !== "object" || Array.isArray(params)) {
      const err = new Error(`${method} params must be an object`) as Error & {
        code: number;
      };
      err.code = RPC_ERR.invalidParams;
      throw err;
    }
    const p = params as Record<string, unknown>;
    const panelId = p.panelId;
    if (typeof panelId !== "string" || panelId.length === 0) {
      const err = new Error(
        `${method} panelId must be a non-empty string`,
      ) as Error & { code: number };
      err.code = RPC_ERR.invalidParams;
      throw err;
    }
    return { panelId, rest: p };
  }

  private async handleShowAlert(
    plugin: PluginProcess,
    params: unknown,
  ): Promise<unknown> {
    const { panelId, rest } = this.parseShowParams("ui.showAlert", params);
    let alert: UiAlertDialog;
    try {
      alert = validateAlertDialog(rest.alert);
    } catch (err) {
      if (err instanceof UiValidationError) {
        const out = new Error(`ui.showAlert: ${err.message}`) as Error & {
          code: number;
        };
        out.code = RPC_ERR.invalidParams;
        throw out;
      }
      throw err;
    }
    this.uiRegistry.broadcastModal({
      kind: "alert",
      pluginId: plugin.manifest.id,
      panelId,
      alert,
    });
    return { delivered: true };
  }

  private async handleShowActionSheet(
    plugin: PluginProcess,
    params: unknown,
  ): Promise<unknown> {
    const { panelId, rest } = this.parseShowParams("ui.showActionSheet", params);
    let sheet: UiActionSheet;
    try {
      sheet = validateActionSheet(rest.sheet);
    } catch (err) {
      if (err instanceof UiValidationError) {
        const out = new Error(`ui.showActionSheet: ${err.message}`) as Error & {
          code: number;
        };
        out.code = RPC_ERR.invalidParams;
        throw out;
      }
      throw err;
    }
    this.uiRegistry.broadcastModal({
      kind: "actionSheet",
      pluginId: plugin.manifest.id,
      panelId,
      sheet,
    });
    return { delivered: true };
  }

  private async handleShowBottomSheet(
    plugin: PluginProcess,
    params: unknown,
  ): Promise<unknown> {
    const { panelId, rest } = this.parseShowParams("ui.showBottomSheet", params);
    let sheet: UiBottomSheet;
    try {
      sheet = validateBottomSheet(rest.sheet);
    } catch (err) {
      if (err instanceof UiValidationError) {
        const out = new Error(`ui.showBottomSheet: ${err.message}`) as Error & {
          code: number;
        };
        out.code = RPC_ERR.invalidParams;
        throw out;
      }
      throw err;
    }
    // Re-run the Batch-3 file:// gate on the bottom-sheet child tree.
    // The `ui.render` walker only sees panel trees — a BottomSheet's
    // child rides a separate code path, so without this call a plugin
    // could ship a `UiImage` with `file:///etc/passwd` inside a
    // BottomSheet and bypass the workspace boundary.
    const gate = await validateFileUrlsAgainstWorkspace(
      sheet.child,
      plugin.manifest.capabilities.fs,
      this.workspaceRootResolver(),
    );
    if (!gate.ok) {
      const code =
        gate.code === "capabilityNotDeclared"
          ? RPC_ERR.capabilityNotDeclared
          : RPC_ERR.invalidParams;
      const out = new Error(`ui.showBottomSheet: ${gate.message}`) as Error & {
        code: number;
      };
      out.code = code;
      throw out;
    }
    this.uiRegistry.broadcastModal({
      kind: "bottomSheet",
      pluginId: plugin.manifest.id,
      panelId,
      sheet,
    });
    return { delivered: true };
  }

  /// Forward an `ui.event` from the app into the owning plugin. Sent as a
  /// JSON-RPC *request* (with an id) per the issue spec; the host does
  /// not await the plugin's reply — UI events are fire-and-forget from
  /// the client's perspective, and the existing message router logs
  /// (then discards) any response the plugin chooses to send.
  ///
  /// Throws `RpcError`-shaped errors (`code` + `message`) so the
  /// dispatcher can turn them into JSON-RPC error frames. Currently:
  ///   * `invalidParams` — plugin id unknown or not active.
  ///   * `capabilityNotDeclared` — plugin manifest lacks `ui` capability.
  public dispatchUiEvent(params: {
    pluginId: string;
    panelId: string;
    nodeId: string;
    type: string;
    payload?: unknown;
  }): void {
    const entry = this.plugins.get(params.pluginId);
    if (entry === undefined) {
      throw new RpcError(
        RPC_ERR.invalidParams,
        `ui.event: no such plugin "${params.pluginId}"`,
      );
    }
    if (entry.state !== "active" || entry.process === undefined) {
      throw new RpcError(
        RPC_ERR.invalidParams,
        `ui.event: plugin "${params.pluginId}" is not active (${entry.state})`,
      );
    }
    // Mirror the capability gate the host applies to plugin-initiated
    // calls: a plugin that never declared `ui` cannot be the target of a
    // host→plugin `ui.event` either. Without this an app could push events
    // at a non-UI plugin and bypass the manifest's `capabilities` contract.
    if (entry.manifest.capabilities.ui !== true) {
      throw new RpcError(
        RPC_ERR.capabilityNotDeclared,
        `ui.event: plugin "${params.pluginId}" did not declare the "ui" capability`,
      );
    }
    const outboundParams: Record<string, unknown> = {
      pluginId: params.pluginId,
      panelId: params.panelId,
      nodeId: params.nodeId,
      type: params.type,
    };
    if (params.payload !== undefined) outboundParams.payload = params.payload;
    // Fire-and-forget: no id so the plugin does not reply. The SDK still
    // acknowledges (sends a response) because it mirrors the host method
    // table, but with no id the response is dropped by the plugin's own
    // respond() helper. On the host side we never await, so the channel
    // stays quiet.
    entry.process.send({
      jsonrpc: "2.0",
      method: "ui.event",
      params: outboundParams,
    });
  }

  /// Fan a `workspace.activated` notification out to every active plugin
  /// process. Called by the workspace registry whenever the
  /// currently-active workspace changes (open-and-activate, activate,
  /// close-that-flips-current, last-close-clears-current).
  ///
  /// Scope is intentionally unconditional: every active plugin receives
  /// the frame, regardless of manifest declarations. The callback is
  /// opt-in at the SDK level (plugins without `onWorkspaceActivated`
  /// ignore it harmlessly) and the cost of an extra notification frame
  /// is trivial compared to the wiring cost of a per-plugin
  /// subscription system. We do NOT gate on a capability key — there
  /// is no `workspace` capability in the manifest schema, and "the user
  /// switched windows" is not a privileged signal.
  ///
  /// Disabled / crashed / errored / registered (not-yet-active) plugins
  /// are skipped: they have no live process to receive the frame, and
  /// the SDK shape promises "no fire on startup" so an inactive plugin
  /// missing this transition is the correct behavior — it'll read the
  /// current value via `ctx.currentWorkspace()` whenever it activates
  /// next.
  public fanOutWorkspaceActivated(workspace: WorkspaceRef | null): void {
    for (const entry of this.plugins.values()) {
      if (entry.state !== "active" || entry.process === undefined) continue;
      entry.process.send({
        jsonrpc: "2.0",
        method: "workspace.activated",
        params: { workspace },
      });
    }
  }

  /// Test seam: handle a websocket dropping subscription from the UI
  /// fan-out. Production wires this through `ProcessState.removeSubscriber`
  /// so the connection-close path covers every panel.
  public uiUnsubscribe(ws: WebSocket): void {
    this.uiRegistry.unsubscribe(ws);
  }

  /// Test seam for assertions / future `plugin.disable` RPC. Returns the
  /// retired panels so tests can verify the snapshot stream without
  /// observing it through the subscriber fan-out.
  public retirePluginPanels(pluginId: string): UiPanelSnapshot[] {
    return this.uiRegistry.retirePlugin(pluginId);
  }
}

function resolveDefaultPluginsDir(): string {
  const override = process.env.OPENVSMOBILE_PLUGINS_DIR;
  if (override !== undefined && override.length > 0) return override;
  return join(homedir(), ...DEFAULT_PLUGINS_DIR_REL);
}

function resolveDefaultLogDir(): string {
  const override = process.env.OPENVSMOBILE_PLUGIN_LOG_DIR;
  if (override !== undefined && override.length > 0) return override;
  return join(homedir(), ...DEFAULT_LOG_DIR_REL);
}

function explainExit(info: {
  code: number | null;
  signal: NodeJS.Signals | null;
}): string {
  if (info.signal !== null) return `terminated by signal ${info.signal}`;
  if (info.code !== null) return `exited with code ${info.code}`;
  return "exited";
}
