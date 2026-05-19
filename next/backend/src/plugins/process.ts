// Per-plugin process wrapper: spawn, wire stdio JSON-RPC, hand inbound
// requests to a host dispatcher, log stderr to a rotating file, observe
// exit.
//
// One PluginProcess per active plugin. Crashing is a state transition,
// not a recoverable event — the host marks the registry entry `crashed`
// and never auto-restarts (settled decision; see CLAUDE.md).

import { spawn, type ChildProcess } from "node:child_process";
import { accessSync, constants as fsConstants, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { execPath } from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
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
  /// Resolves the first time `onExit` fires. Lets `terminate()` callers
  /// block on the actual exit instead of racing the kernel.
  private exitWaiters: Array<() => void> = [];
  /// Stdin backpressure state. `stdinPaused` flips true the first time
  /// `write()` returns false; the next `drain` flips it back. Queued
  /// frames accumulate in `stdinQueue` (and their byte total in
  /// `stdinQueueBytes` so we don't traverse on every push).
  private stdinPaused = false;
  private stdinQueue: Buffer[] = [];
  private stdinQueueBytes = 0;

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
      // Inject the SDK resolver as an `--import` side-effect module so
      // the plugin's `import "@openvsmobile/sdk"` resolves regardless
      // of where the plugin directory lives on disk. ESM does not
      // consult NODE_PATH (Node spec — bare specifiers walk only
      // `node_modules`), and we deliberately don't write a
      // `node_modules` symlink into user-controlled plugin
      // directories, so a resolver hook is the v0 mechanism for the
      // "host-injected resolver path" from design §3.4.
      args = [];
      const loaderUrl = resolveSdkLoaderUrl();
      if (loaderUrl !== null) {
        args.push("--import", loaderUrl);
      }
      args.push(entryPath);
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
      // Explicit env whitelist (see `buildPluginEnv`). Plugins inherit
      // ONLY what they need to behave like a normal process (locale,
      // home, shell) plus the `OPENVSMOBILE_PLUGIN_*` channel the SDK
      // loader reads. Everything else — and in particular any
      // host-side TOKEN/SECRET/API_KEY/PASSWORD — is stripped so a
      // plugin that calls `child_process` or reads env at startup
      // can't trivially exfiltrate host credentials.
      env: buildPluginEnv(),
    });
    this.wireStreams();
  }

  /// Send a JSON-RPC message to the plugin. Drops silently if the child
  /// has exited — the host's exit handler will surface the loss.
  ///
  /// Tracks per-plugin stdin backpressure: when the kernel pipe fills
  /// up (`stdin.write()` returns false) we stop scheduling further
  /// writes until the `drain` event fires, then flush whatever queued
  /// up. If the queued bytes ever exceed `STDIN_HIGH_WATER_MARK_BYTES`
  /// (16 MiB) we treat the plugin as wedged and terminate it — a
  /// runaway plugin that never reads its stdin must not be allowed to
  /// grow the host's RSS without bound.
  public send(message: object): void {
    if (this.child === null || this.exited) return;
    const stdin = this.child.stdin;
    if (stdin === null || stdin.destroyed) return;
    const frame = this.codec.encode(message);
    // Fast path: pipe has room AND no queued frames waiting on drain.
    if (!this.stdinPaused && this.stdinQueue.length === 0) {
      const ok = stdin.write(frame);
      if (!ok) this.stdinPaused = true;
      return;
    }
    // Slow path: queue and account.
    this.stdinQueue.push(frame);
    this.stdinQueueBytes += frame.length;
    if (this.stdinQueueBytes > STDIN_HIGH_WATER_MARK_BYTES) {
      this.logger(
        `[plugin:${this.manifest.id}] stdin backpressure overflow (${this.stdinQueueBytes} bytes queued); terminating`,
      );
      // Drop the queue first so a kill cycle doesn't keep paying RSS
      // for buffers we will never flush.
      this.stdinQueue = [];
      this.stdinQueueBytes = 0;
      try {
        this.child?.kill("SIGKILL");
      } catch {
        // best-effort — kernel may have already torn the child down.
      }
    }
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

  /// Wait until the child actually exits. Resolves immediately if the
  /// process already exited (or was never running). Used by the disable
  /// path so we can SIGTERM, await this, and SIGKILL on timeout.
  public waitForExit(): Promise<void> {
    if (this.exited || this.child === null) return Promise.resolve();
    return new Promise((resolve) => {
      this.exitWaiters.push(resolve);
    });
  }

  /// SIGTERM the plugin; if it hasn't exited within `graceMs`, SIGKILL.
  /// Resolves once the child has actually exited. `graceMs` is tunable so
  /// tests don't have to wait the 10-second production default.
  public async terminate(graceMs: number): Promise<void> {
    if (this.child === null || this.exited) return;
    try {
      this.child.kill("SIGTERM");
    } catch {
      // best-effort — the kernel may have already torn the child down.
    }
    const exited = this.waitForExit();
    let timer: NodeJS.Timeout | null = null;
    const grace = new Promise<"timeout">((resolve) => {
      timer = setTimeout(() => resolve("timeout"), graceMs);
    });
    const winner = await Promise.race([
      exited.then(() => "exited" as const),
      grace,
    ]);
    if (timer !== null) clearTimeout(timer);
    if (winner === "timeout" && !this.exited && this.child !== null) {
      this.logger(
        `[plugin:${this.manifest.id}] SIGTERM did not exit within ${graceMs}ms; escalating to SIGKILL`,
      );
      try {
        this.child.kill("SIGKILL");
      } catch {
        // best-effort
      }
      await this.waitForExit();
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
    const stdin = child.stdin;
    if (stdin !== null) {
      stdin.on("drain", () => this.flushStdinQueue());
      // Silently swallow EPIPE — the plugin exited and the kernel
      // dropped the pipe. The `exit` event below will fire and let
      // the host transition state cleanly.
      stdin.on("error", () => {});
    }
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

  /// Drain handler. Called when the kernel pipe has room again. Flushes
  /// queued frames until either the queue is empty or `write()` returns
  /// false again (in which case we leave the remainder queued for the
  /// next drain).
  private flushStdinQueue(): void {
    this.stdinPaused = false;
    if (this.child === null || this.exited) {
      this.stdinQueue = [];
      this.stdinQueueBytes = 0;
      return;
    }
    const stdin = this.child.stdin;
    if (stdin === null || stdin.destroyed) {
      this.stdinQueue = [];
      this.stdinQueueBytes = 0;
      return;
    }
    while (this.stdinQueue.length > 0) {
      const frame = this.stdinQueue.shift() as Buffer;
      this.stdinQueueBytes -= frame.length;
      const ok = stdin.write(frame);
      if (!ok) {
        this.stdinPaused = true;
        return;
      }
    }
  }

  private markExited(
    code: number | null,
    signal: NodeJS.Signals | null,
  ): void {
    if (this.exited) return;
    this.exited = true;
    this.stderr.close();
    this.onExit({ code, signal });
    const waiters = this.exitWaiters;
    this.exitWaiters = [];
    for (const w of waiters) w();
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

/// Stdin backpressure budget. A plugin that wedges and never reads its
/// stdin would otherwise let the host's queued-frame buffer grow until
/// the host OOMs. 16 MiB matches the inbound frame cap in `framing.ts`
/// — symmetric default for both directions.
const STDIN_HIGH_WATER_MARK_BYTES = 16 * 1024 * 1024;

/// Build the env a plugin child inherits. We deliberately do NOT pass
/// `process.env` through — a single-user system still benefits from
/// keeping host credentials out of every plugin's reach. The shape is:
///
///   * Pass through a small set of "behave like a normal process"
///     variables: PATH, HOME, LANG, LC_ALL, TZ, TMPDIR, USER, SHELL.
///   * Pass through `OPENVSMOBILE_PLUGIN_*` (the channel the SDK
///     loader uses for per-plugin state, e.g.
///     OPENVSMOBILE_PLUGIN_STATE_FILE).
///   * Strip everything else, with a final regex sweep that removes
///     anything matching /TOKEN|SECRET|API_KEY|PASSWORD/i in case the
///     whitelist later picks up a key whose value the host considers
///     sensitive.
function buildPluginEnv(): NodeJS.ProcessEnv {
  const passthrough = [
    "PATH",
    "HOME",
    "LANG",
    "LC_ALL",
    "TZ",
    "TMPDIR",
    "USER",
    "SHELL",
  ];
  const sensitive = /TOKEN|SECRET|API_KEY|PASSWORD/i;
  const out: NodeJS.ProcessEnv = {};
  for (const key of passthrough) {
    const v = process.env[key];
    if (v !== undefined && !sensitive.test(key)) out[key] = v;
  }
  for (const key of Object.keys(process.env)) {
    if (!key.startsWith("OPENVSMOBILE_PLUGIN_")) continue;
    if (sensitive.test(key)) continue;
    const v = process.env[key];
    if (v !== undefined) out[key] = v;
  }
  return out;
}

/// Cached `file://` URL of the SDK loader hook. `null` means the SDK
/// isn't installed and we should let the spawn proceed without the
/// `--import` flag — the plugin will fail loud with `MODULE_NOT_FOUND`
/// on its own `import "@openvsmobile/sdk"`, which is the right
/// diagnostic for "you didn't run `pnpm install`". Searching the
/// filesystem on every spawn would be wasted work; the layout is fixed
/// for the lifetime of the process.
let cachedSdkLoaderUrl: string | null | undefined;

/// Locate `@openvsmobile/sdk/runtime/sdk-loader.mjs` by walking up from
/// this file looking for a `node_modules/@openvsmobile/sdk/` directory.
/// The dev path is `<backend>/src/plugins/process.ts` →
/// `<backend>/node_modules`; after `tsc` it's
/// `<backend>/dist/plugins/process.js` → `<backend>/node_modules`; in a
/// packaged tarball the same walk works because the SDK lives under
/// `<root>/node_modules` either way.
function resolveSdkLoaderUrl(): string | null {
  if (cachedSdkLoaderUrl !== undefined) return cachedSdkLoaderUrl;
  const selfDir = dirname(fileURLToPath(import.meta.url));
  let d = selfDir;
  while (true) {
    const candidate = join(
      d,
      "node_modules",
      "@openvsmobile",
      "sdk",
      "runtime",
      "sdk-loader.mjs",
    );
    if (existsSync(candidate)) {
      cachedSdkLoaderUrl = pathToFileURL(candidate).href;
      return cachedSdkLoaderUrl;
    }
    const parent = dirname(d);
    if (parent === d) {
      cachedSdkLoaderUrl = null;
      return null;
    }
    d = parent;
  }
}
