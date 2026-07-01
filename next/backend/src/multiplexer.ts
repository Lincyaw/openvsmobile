// Terminal multiplexer probe + thin CLI wrappers.
//
// Backend can run terminals two ways:
//   (a) directly spawn the user's shell as a PTY child — terminal dies with
//       the backend (kernel SIGHUPs the slave when the master closes).
//   (b) spawn `zellij attach --create <name>`, with zellij holding the
//       actual shell. The backend's PTY child is the zellij CLIENT; the
//       zellij SERVER stays alive across backend restarts.
//
// (b) is preferred when available. Whether it's available is decided once
// at boot by probing `zellij --version` and cached as a `MultiplexerInfo`
// shared by every TerminalRegistry. If zellij is missing or its probe
// fails / times out, the backend transparently falls back to (a) — a
// missing multiplexer must never block startup.
//
// Everything here uses `execFile` (argv array, no shell) so session names
// and arguments can never be interpreted by a shell, and every call has a
// hard timeout so a stuck zellij CLI cannot wedge the backend.

import { execFile, type ExecFileException } from "node:child_process";
import { mkdirSync } from "node:fs";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/// Hard cap on every zellij CLI call. The probe runs once at startup; the
/// per-terminal `kill-session` runs at dispose. Two seconds is generous —
/// healthy invocations complete in tens of milliseconds — and an upper
/// bound on how long a stuck CLI can stall the surrounding flow.
export const ZELLIJ_CLI_TIMEOUT_MS = 2000;

/// Prefix applied to zellij session names spawned by the backend. Keeps
/// our sessions visually distinct from any the user spawned manually so
/// `zellij list-sessions` is still usable as an operator tool. Also acts
/// as a tiny namespace so a future cleanup script can identify our
/// sessions safely.
export const ZELLIJ_SESSION_PREFIX = "ovsm-";

/// Terminal id → zellij session name. Pure: no I/O. The leading prefix
/// guarantees the result starts with an ASCII letter (zellij rejects
/// some leading punctuation in session names).
export function zellijSessionName(terminalId: string): string {
  return `${ZELLIJ_SESSION_PREFIX}${terminalId}`;
}

/// Subset of session ids zellij accepts cleanly. Real terminal ids in
/// this codebase are UUIDs so this always passes; the check exists so a
/// future code path that builds a non-UUID id (e.g. user-supplied) can't
/// smuggle shell-meaningful characters into a session name. On failure
/// the caller falls back to direct-shell mode for that one terminal —
/// never throws, never blocks creation.
const VALID_ID = /^[a-zA-Z0-9_-]+$/;
export function isSessionIdSafe(id: string): boolean {
  return VALID_ID.test(id);
}

/// Outcome of the boot-time probe. Stored process-wide; consulted by
/// TerminalRegistry to decide whether to wrap shells in zellij.
export interface MultiplexerInfo {
  readonly kind: "zellij" | "none";
  /// Raw `zellij --version` stdout when kind === "zellij"; undefined
  /// otherwise. Surfaced only in the boot log for diagnostics.
  readonly version?: string;
}

/// Indirection point for tests. Production wires `realExecRunner`, which
/// shells out via `child_process.execFile`. Tests pass a fake runner so
/// the suite never depends on zellij being installed on CI.
export interface ExecRunner {
  run(
    command: string,
    args: readonly string[],
    options: { timeoutMs: number },
  ): Promise<{ stdout: string; stderr: string }>;
}

export function zellijEnvironment(
  env: NodeJS.ProcessEnv = process.env,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(env)) {
    if (value !== undefined) out[key] = value;
  }
  const socketDir = env.ZELLIJ_SOCKET_DIR;
  if (socketDir !== undefined && socketDir.length > 0) {
    try {
      mkdirSync(socketDir, { recursive: true, mode: 0o700 });
    } catch (err) {
      console.error(
        `[openvsmobile-next] WARN: failed to create ZELLIJ_SOCKET_DIR ${socketDir}:`,
        err,
      );
    }
    out.ZELLIJ_SOCKET_DIR = socketDir;
  } else {
    // Default to zellij's own namespace so sessions created in a normal
    // desktop/SSH terminal are discoverable and adoptable from the app.
    delete out.ZELLIJ_SOCKET_DIR;
  }
  return out;
}

export const realExecRunner: ExecRunner = {
  async run(command, args, options) {
    const { stdout, stderr } = await execFileAsync(command, [...args], {
      timeout: options.timeoutMs,
      env: zellijEnvironment(),
      // 64 KB output cap. Far more than `zellij --version` or
      // `kill-session` ever produces; anything larger means something
      // is wrong upstream and we'd rather fail fast.
      maxBuffer: 64 * 1024,
    });
    return { stdout: stdout.toString(), stderr: stderr.toString() };
  },
};

/// Probe for an available multiplexer. Today only zellij; the result
/// type is shaped so adding tmux later is a switch case, not a rewrite.
/// Never throws — every failure (ENOENT, non-zero exit, timeout) maps to
/// `{ kind: "none" }` so callers can branch on shape, not on exceptions.
export async function probeMultiplexer(
  runner: ExecRunner = realExecRunner,
): Promise<MultiplexerInfo> {
  try {
    const { stdout } = await runner.run("zellij", ["--version"], {
      timeoutMs: ZELLIJ_CLI_TIMEOUT_MS,
    });
    const version = stdout.trim();
    return { kind: "zellij", version };
  } catch (err) {
    // ENOENT (not installed), non-zero exit, or timeout — all collapse
    // to "no multiplexer", with one stderr line so a misconfigured host
    // is debuggable without scraping syslog.
    const reason = describeExecError(err);
    console.error(
      `[openvsmobile-next] zellij unavailable (${reason}); ` +
        `terminal sessions will NOT persist across backend restarts`,
    );
    return { kind: "none" };
  }
}

/// Best-effort `zellij kill-session`. Logs failure and returns; never
/// throws. The caller (terminal.dispose) cannot meaningfully recover
/// from a kill-session failure — the PTY is already closed and the user
/// has moved on.
export async function killZellijSession(
  sessionName: string,
  runner: ExecRunner = realExecRunner,
): Promise<void> {
  try {
    await runner.run("zellij", ["kill-session", sessionName], {
      timeoutMs: ZELLIJ_CLI_TIMEOUT_MS,
    });
  } catch (err) {
    // Common harmless case: the session is already gone (zellij itself
    // crashed, user ran `zellij delete-session`, etc.). We log once at
    // info-ish level via stderr and move on — failing the surrounding
    // RPC for a stale kill is worse than the leak it would prevent.
    const reason = describeExecError(err);
    console.error(
      `[openvsmobile-next] zellij kill-session ${sessionName} failed: ${reason}`,
    );
  }
}

/// One row of `zellij list-sessions` output. `status === "exited"` mirrors
/// zellij's own "(EXITED - reason)" annotation; everything else is treated
/// as active. We don't surface timestamps for v0 — zellij's output uses
/// human strings ("Created 5m ago") that we'd just parse and lose precision
/// on. See task brief §"Out of scope".
export interface ExternalSession {
  readonly name: string;
  readonly status: "active" | "exited";
}

const ANSI_ESCAPE = /\x1B\[[0-9;?]*[ -/]*[@-~]/g;

/// Strip ANSI escape sequences and return the visible payload. Zellij's
/// CLI colorizes output even when stdout isn't a TTY; without this the
/// session name we extract is wrapped in color codes that don't match
/// when we look the session up later.
function stripAnsi(s: string): string {
  return s.replace(ANSI_ESCAPE, "");
}

/// Parse one `zellij list-sessions` line. Modern zellij emits
/// `<name> [Created Xm ago]` for active sessions and
/// `<name> [Created Xm ago] (EXITED - reason)` for exited ones; older
/// versions may omit the bracketed timestamp. We anchor only on the
/// leading session name (first whitespace-delimited token after ANSI
/// strip) and on the `(EXITED` substring to flag the status — the open
/// paren is what disambiguates the status annotation from a session
/// literally named `EXITED` (which the name regex allows).
export function parseZellijListSessions(stdout: string): ExternalSession[] {
  const out: ExternalSession[] = [];
  for (const rawLine of stdout.split(/\r?\n/)) {
    const line = stripAnsi(rawLine).trim();
    if (line.length === 0) continue;
    // Zellij prints a friendly "No active zellij sessions found." when
    // there are none — don't try to parse that as a name.
    if (/^no .*sessions/i.test(line)) continue;
    const firstToken = line.split(/\s/, 1)[0];
    if (firstToken.length === 0) continue;
    // Be defensive: a token must look like a plausible session name.
    if (!/^[A-Za-z0-9._-]+$/.test(firstToken)) continue;
    // Match on the bare `(EXITED` prefix (with the open paren) so a
    // session literally named `EXITED` on an otherwise-active line is
    // not misclassified. Zellij's actual annotation is always wrapped:
    // `(EXITED - <reason>)`.
    const status: "active" | "exited" =
      line.includes("(EXITED") ? "exited" : "active";
    out.push({ name: firstToken, status });
  }
  return out;
}

/// Run `zellij list-sessions` and return the parsed result. Treats a
/// non-zero exit as "no sessions" rather than throwing — zellij returns
/// exit 1 when there are no sessions, which is not an error.
export async function listZellijSessions(
  runner: ExecRunner = realExecRunner,
): Promise<ExternalSession[]> {
  try {
    const { stdout } = await runner.run(
      "zellij",
      ["list-sessions", "--no-formatting"],
      {
        timeoutMs: ZELLIJ_CLI_TIMEOUT_MS,
      },
    );
    return parseZellijListSessions(stdout);
  } catch (err) {
    // "no sessions" surfaces as exit 1 with the friendly string on
    // stdout. Recent zellij also routes the message through stderr; we
    // try to recover the payload either way so the caller sees an
    // empty array instead of an exception.
    const e = err as { stdout?: string; stderr?: string };
    if (typeof e.stdout === "string" && e.stdout.length > 0) {
      return parseZellijListSessions(e.stdout);
    }
    if (typeof e.stderr === "string" && e.stderr.length > 0) {
      return parseZellijListSessions(e.stderr);
    }
    return [];
  }
}

function describeExecError(err: unknown): string {
  if (err === null || typeof err !== "object") return String(err);
  const e = err as ExecFileException & { signal?: string };
  if (e.code === "ENOENT") return "binary not found";
  if (e.signal === "SIGTERM") return "timed out";
  if (typeof e.code === "number") return `exit ${e.code}`;
  if (typeof e.message === "string") return e.message;
  return "unknown error";
}
