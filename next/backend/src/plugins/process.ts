// Per-plugin process wrapper: spawn, wire stdio JSON-RPC, hand inbound
// requests to a host dispatcher, log stderr to a rotating file, observe
// exit.
//
// One PluginProcess per active plugin. Crashing is a state transition,
// not a recoverable event — the host marks the registry entry `crashed`
// and never auto-restarts (settled decision; see CLAUDE.md).

import { spawn, type ChildProcess } from "node:child_process";
import { accessSync, constants as fsConstants } from "node:fs";
import { execPath } from "node:process";
import { FrameCodec } from "./framing.js";
import type { PluginManifest } from "./manifest.js";
import { resolveEntryPath } from "./manifest.js";
import { StderrLog } from "./stderrLog.js";

export type PluginRequestHandler = (
  plugin: PluginProcess,
  message: JsonRpcInbound,
) => Promise<void> | void;

export interface JsonRpcInbound {
  jsonrpc: "2.0";
  id?: string | number;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

export interface PluginProcessOptions {
  manifest: PluginManifest;
  /// Plugin directory on disk. Used both as the spawn CWD (per issue spec)
  /// and as the base for resolving the entry path.
  dir: string;
  /// Rotating stderr log target. The host opens it before construction
  /// so spawn failures can still attribute their stderr.
  stderr: StderrLog;
  /// Called for every inbound JSON-RPC message (request, notification,
  /// or response). The host dispatches on it.
  onMessage: PluginRequestHandler;
  /// Called once with the exit code/signal when the child terminates.
  /// Fires at most once per PluginProcess.
  onExit: (info: { code: number | null; signal: NodeJS.Signals | null }) => void;
  /// Diagnostic logger for host-internal events (spawn, framing errors,
  /// channel decisions). Routed to console.error in production; tests
  /// pass a collector.
  logger?: (line: string) => void;
}

/// Refuse-to-load result returned by `start()` when the manifest points
/// at something we can't safely exec. The host marks the plugin
/// `errored` with this reason.
export class PluginSpawnError extends Error {}

export class PluginProcess {
  public readonly manifest: PluginManifest;
  private readonly dir: string;
  private readonly stderr: StderrLog;
  private readonly onMessage: PluginRequestHandler;
  private readonly onExit: PluginProcessOptions["onExit"];
  private readonly logger: (line: string) => void;
  private readonly codec: FrameCodec;
  private child: ChildProcess | null = null;
  private exited = false;

  constructor(opts: PluginProcessOptions) {
    this.manifest = opts.manifest;
    this.dir = opts.dir;
    this.stderr = opts.stderr;
    this.onMessage = opts.onMessage;
    this.onExit = opts.onExit;
    this.logger = opts.logger ?? ((line) => console.error(line));
    this.codec = new FrameCodec({
      onMessage: (raw) => this.handleMessage(raw),
      onFramingError: (msg) =>
        this.logger(`[plugin:${this.manifest.id}] ${msg}`),
    });
  }

  /// Spawn the child. Throws PluginSpawnError synchronously when the
  /// manifest points at something we refuse to exec (binary without +x,
  /// missing node entry, …). Asynchronous spawn failures (ENOENT after
  /// the spawn call returns) fire `onExit` instead.
  public async start(): Promise<void> {
    await this.stderr.open();
    const entryPath = resolveEntryPath(this.dir, this.manifest);
    let command: string;
    let args: string[];
    if (this.manifest.entry.kind === "node") {
      // `entry.path` is resolved relative to the plugin dir; the issue
      // says we MUST spawn with the same node binary the backend is
      // running on, so `execPath` is the right thing here.
      command = execPath;
      args = [entryPath];
    } else {
      // binary mode: refuse to spawn anything that isn't executable. A
      // non-executable file would error at spawn time with a confusing
      // ENOENT/EACCES; surface it up front instead.
      try {
        accessSync(entryPath, fsConstants.X_OK);
      } catch {
        throw new PluginSpawnError(
          `binary entry "${this.manifest.entry.path}" is not executable`,
        );
      }
      command = entryPath;
      args = [];
    }
    this.child = spawn(command, args, {
      cwd: this.dir,
      stdio: ["pipe", "pipe", "pipe"],
      // Inherit the host's env. v0 doesn't sandbox env vars — that's a
      // §3.5 capability concern we'll revisit. Plugins should not be
      // depending on host env in v0 anyway.
      env: process.env,
    });
    this.wireStreams();
  }

  /// Send a JSON-RPC message to the plugin. Drops silently if the child
  /// has exited — the host's exit handler will surface the loss.
  public send(message: object): void {
    if (this.child === null || this.exited) return;
    const stdin = this.child.stdin;
    if (stdin === null || stdin.destroyed) return;
    stdin.write(this.codec.encode(message));
  }

  /// Force-terminate the plugin. Used at host shutdown. We send SIGTERM
  /// (well-behaved plugins clean up); the caller is responsible for
  /// SIGKILLing on timeout if needed — for v0 we don't bother since
  /// shutdown is best-effort.
  public kill(): void {
    if (this.child === null || this.exited) return;
    try {
      this.child.kill("SIGTERM");
    } catch {
      // best-effort
    }
  }

  /// PID of the live child, or null if the process never spawned or has
  /// exited. Useful for diagnostics; the host doesn't use it for
  /// dispatch.
  public pid(): number | null {
    if (this.child === null) return null;
    return this.child.pid ?? null;
  }

  private wireStreams(): void {
    const child = this.child;
    if (child === null) return;
    const stdout = child.stdout;
    if (stdout !== null) {
      stdout.on("data", (chunk: Buffer) => this.codec.push(chunk));
    }
    const stderr = child.stderr;
    if (stderr !== null) {
      stderr.on("data", (chunk: Buffer) => this.stderr.write(chunk));
    }
    child.on("error", (err) => {
      this.logger(
        `[plugin:${this.manifest.id}] spawn error: ${err.message}`,
      );
      this.markExited(null, null);
    });
    child.on("exit", (code, signal) => {
      this.markExited(code, signal);
    });
  }

  private markExited(
    code: number | null,
    signal: NodeJS.Signals | null,
  ): void {
    if (this.exited) return;
    this.exited = true;
    this.stderr.close();
    this.onExit({ code, signal });
  }

  private handleMessage(raw: unknown): void {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      this.logger(
        `[plugin:${this.manifest.id}] discarding non-object frame`,
      );
      return;
    }
    const msg = raw as JsonRpcInbound;
    if (msg.jsonrpc !== "2.0") {
      this.logger(
        `[plugin:${this.manifest.id}] discarding frame with missing/invalid jsonrpc`,
      );
      return;
    }
    void this.onMessage(this, msg);
  }
}
