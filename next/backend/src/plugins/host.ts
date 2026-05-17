// Plugin host: discovery, registry, capability-gated dispatch.
//
// One PluginHost per backend process. Scans `OPENVSMOBILE_PLUGINS_DIR`
// (default ~/.local/share/openvsmobile-next/plugins/), parses manifests,
// spawns `onStartup`-activated plugins, and dispatches host-bound JSON-RPC
// calls from each plugin. Everything plugin-related stays in this folder;
// the rest of the backend reaches in via PluginHost only.
//
// The only host method exposed in C1 is `host.log({ level, msg })`. Any
// other namespace from a plugin gets capability-gated and (since no
// other host RPCs are wired yet) ultimately resolves to either
// `-32011 capabilityNotDeclared` (manifest didn't ask for the capability)
// or `-32601 methodNotFound` (manifest declared it but the host has not
// implemented the method yet — landing in C2/C3/C4/C5). The capability
// check runs first, per the conventions doc.

import { existsSync } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { RPC_ERR } from "../rpc.js";
import {
  loadManifest,
  type ManifestCapabilities,
  type PluginManifest,
} from "./manifest.js";
import {
  PluginProcess,
  PluginSpawnError,
  type JsonRpcInbound,
} from "./process.js";
import { StderrLog } from "./stderrLog.js";

export type PluginState =
  | "registered"
  | "active"
  | "crashed"
  | "errored"
  | "disabled";

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

export interface PluginHostOptions {
  /// Override discovery root. Tests point this at a tempdir; production
  /// reads it from `OPENVSMOBILE_PLUGINS_DIR` and falls back to the
  /// XDG-style default.
  pluginsDir?: string;
  /// Directory for plugin stderr logs. Default
  /// `~/.local/state/openvsmobile-next/plugins/`.
  logDir?: string;
  /// Diagnostic logger. Defaults to console.error.
  logger?: (line: string) => void;
  /// Sink for `host.log` calls. The default fan-out routes them through
  /// `logger`. Tests pass a collector to assert delivery.
  onHostLog?: (entry: HostLogEntry) => void;
}

const DEFAULT_PLUGINS_DIR_REL = [".local", "share", "openvsmobile-next", "plugins"];
const DEFAULT_LOG_DIR_REL = [".local", "state", "openvsmobile-next", "plugins"];

/// Capability key required by a method namespace. Methods under `host.*`
/// require no capability (the host log is intentionally always
/// available). Anything else maps to a key in the manifest's
/// `capabilities` block; an unrecognized namespace also maps to "no
/// capability satisfies this", which the gate translates to
/// `-32011 capabilityNotDeclared`.
function requiredCapability(method: string): keyof ManifestCapabilities | null {
  // host.* — uncategorized, always allowed.
  if (method.startsWith("host.")) return null;
  // The plugin-side API surface from §3.6. The map below is the
  // authoritative source of "which capability key gates which method
  // namespace"; widen here when a new host RPC lands.
  if (method.startsWith("fs.") || method.startsWith("workspace.")) return "fs";
  if (method.startsWith("terminal.")) return "terminal";
  if (method.startsWith("git.")) return "fs";
  if (method.startsWith("network.")) return "network";
  if (method.startsWith("secrets.")) return "secrets";
  if (method.startsWith("ui.") || method.startsWith("notify.")) return "ui";
  // Unknown namespace → no capability key satisfies it. Treat the same
  // as "not declared" so misuse from a plugin author surfaces clearly.
  return "fs";
}

function pluginHasCapability(
  caps: ManifestCapabilities,
  key: keyof ManifestCapabilities,
): boolean {
  if (key === "fs") return caps.fs === "read" || caps.fs === "readwrite";
  return caps[key] === true;
}

export class PluginHost {
  private readonly pluginsDir: string;
  private readonly logDir: string;
  private readonly logger: (line: string) => void;
  private readonly onHostLog: (entry: HostLogEntry) => void;
  private readonly plugins = new Map<string, PluginRegistryEntry>();
  /// Counter for outgoing requests we initiate toward plugins (e.g.
  /// `initialize` in the C2 timeframe). Lives here so a single
  /// monotonic source covers every plugin.
  private nextOutboundId = 1;

  constructor(opts: PluginHostOptions = {}) {
    this.pluginsDir = opts.pluginsDir ?? resolveDefaultPluginsDir();
    this.logDir = opts.logDir ?? resolveDefaultLogDir();
    this.logger = opts.logger ?? ((line) => console.error(line));
    this.onHostLog =
      opts.onHostLog ??
      ((entry) =>
        this.logger(
          `[plugin:${entry.pluginId}] ${entry.level}: ${entry.msg}`,
        ));
  }

  /// Public read-only view of the registry. Tests + future `plugin.list`
  /// reach for this.
  public list(): PluginRegistryEntry[] {
    return [...this.plugins.values()];
  }

  public get(id: string): PluginRegistryEntry | undefined {
    return this.plugins.get(id);
  }

  /// Plugins directory the host is configured to scan. Lets tests
  /// confirm env-var override took effect.
  public dir(): string {
    return this.pluginsDir;
  }

  /// Discover everything on disk and start `onStartup` plugins. Safe to
  /// call once at backend boot. If the plugins directory is missing
  /// entirely we treat that as "no plugins installed" — not an error.
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

  /// Tear every plugin process down. Best-effort; we send SIGTERM and
  /// move on. Called from the backend's shutdown handler.
  public shutdown(): void {
    for (const entry of this.plugins.values()) {
      if (entry.process !== undefined) entry.process.kill();
    }
  }

  /// Walk the plugins directory. Each direct child that contains a
  /// `plugin.json` becomes a `registered` entry. Mismatched id, parse
  /// errors, and missing manifest files are surfaced through the entry
  /// state — invalid plugins land as `errored` so the host can still
  /// report them to the future Plugins tab without erroring the whole
  /// backend.
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
      this.plugins.set(dirId, {
        id: dirId,
        dir,
        manifest,
        state: "registered",
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

  /// Spawn a plugin's process and wire its message handler. Idempotent:
  /// a re-activate on an already-active plugin is a no-op. After this
  /// returns, the plugin's state is one of `active`, `crashed`, or
  /// `errored`.
  public async activate(entry: PluginRegistryEntry): Promise<void> {
    if (entry.state === "active") return;
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
        entry.state = "errored";
        entry.reason = err.message;
        this.logger(`[plugin:${entry.id}] refused to spawn: ${err.message}`);
        return;
      }
      throw err;
    }
    entry.process = proc;
    entry.state = "active";
    this.logger(`[plugin:${entry.id}] spawned pid=${proc.pid() ?? "?"}`);
  }

  /// Used for the activating-state intermediate; today we flip directly
  /// from `registered` to `active`. Kept as a placeholder so existing
  /// callers don't break when the C2 `initialize` handshake lands.
  private handlePluginExit(
    entry: PluginRegistryEntry,
    info: { code: number | null; signal: NodeJS.Signals | null },
  ): void {
    // No automatic restart (settled decision; CLAUDE.md). We move the
    // entry to `crashed` if it had been running, or leave `errored`
    // alone (a stillborn child can fire `exit` after we already
    // transitioned to errored via the spawn-error path).
    if (entry.state === "active") {
      entry.state = "crashed";
      entry.reason = explainExit(info);
      entry.exit = info;
      this.logger(
        `[plugin:${entry.id}] crashed: ${entry.reason} (no automatic restart)`,
      );
    } else {
      entry.exit = info;
    }
    entry.process = undefined;
  }

  private handlePluginMessage(
    plugin: PluginProcess,
    msg: JsonRpcInbound,
  ): void {
    // Requests carry an id; notifications don't. Plugins may also send
    // *responses* to host-initiated requests (we'll have those once
    // `initialize` lands in C2); v0 has none so we just log them.
    if (msg.method === undefined) {
      // Response to a (currently nonexistent) host-initiated request.
      // Logging until the C2 timeframe wires the response router.
      this.logger(
        `[plugin:${plugin.manifest.id}] discarding response (no outstanding host requests)`,
      );
      return;
    }
    void this.dispatchPluginRequest(plugin, msg);
  }

  private async dispatchPluginRequest(
    plugin: PluginProcess,
    msg: JsonRpcInbound,
  ): Promise<void> {
    const method = msg.method;
    if (typeof method !== "string") return; // already filtered, kept for narrowing
    // Capability gate first. The conventions doc is explicit: capability
    // gating is centralized, not scattered through handlers.
    const required = requiredCapability(method);
    if (
      required !== null &&
      !pluginHasCapability(plugin.manifest.capabilities, required)
    ) {
      this.respond(plugin, msg.id, {
        code: RPC_ERR.capabilityNotDeclared,
        message: `capabilityNotDeclared: ${method} requires capability "${required}"`,
      });
      return;
    }
    try {
      const result = await this.callHostMethod(plugin, method, msg.params);
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

  /// The actual host-method table. v0 has exactly one entry: `host.log`.
  /// Adding methods here without also widening `requiredCapability`
  /// would let plugins bypass the gate, so the two must move together.
  private async callHostMethod(
    plugin: PluginProcess,
    method: string,
    params: unknown,
  ): Promise<unknown> {
    if (method === "host.log") {
      this.handleHostLog(plugin.manifest.id, params);
      return {};
    }
    // Pre-C2: capability passed, but the method itself doesn't exist
    // yet. Surface as methodNotFound so a plugin author has a clear
    // signal that they declared a capability but the host hasn't wired
    // the corresponding API in this build.
    const err = new Error(`unknown host method: ${method}`) as Error & {
      code: number;
    };
    err.code = RPC_ERR.methodNotFound;
    throw err;
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

  /// Reserve an outbound id for a future host→plugin request. Not used
  /// in v0; lives here so the C2 initialize handshake doesn't have to
  /// invent its own counter.
  public allocateOutboundId(): number {
    return this.nextOutboundId++;
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
