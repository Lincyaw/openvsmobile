// Agent hook installer runner. This does not wrap Claude/Codex; it only
// re-runs the notification hook installer already bundled under bin/ so
// Settings can repair completion notifications after an agent config changes.

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const MAX_CAPTURE_BYTES = 64 * 1024;

export interface AgentHookStatus {
  agent: string;
  state: string;
  message: string;
  available: boolean;
  changed: boolean;
}

export interface AgentHookInstallResult {
  ok: boolean;
  exitCode: number | null;
  statuses: AgentHookStatus[];
  stdout: string;
  stderr: string;
}

export interface InstallAgentHooksOptions {
  backendRoot?: string;
  env?: NodeJS.ProcessEnv;
  runner?: typeof spawn;
}

interface RunAgentHooksOptions extends InstallAgentHooksOptions {
  check: boolean;
}

function backendRootFromModule(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  // Works both from src/ under tsx and from dist/ after tsc.
  return dirname(here);
}

function appendCapped(chunks: Buffer[], chunk: Buffer): void {
  const current = chunks.reduce((sum, c) => sum + c.length, 0);
  if (current >= MAX_CAPTURE_BYTES) return;
  const room = MAX_CAPTURE_BYTES - current;
  chunks.push(chunk.length <= room ? chunk : chunk.subarray(0, room));
}

function parseStatuses(stdout: string): AgentHookStatus[] {
  try {
    const parsed = JSON.parse(stdout);
    const raw = parsed?.results;
    if (typeof raw !== "object" || raw === null) return [];
    return Object.values(raw)
      .filter((v): v is Record<string, unknown> =>
        typeof v === "object" && v !== null,
      )
      .map((v) => ({
        agent: typeof v.agent === "string" ? v.agent : "agent",
        state: typeof v.state === "string" ? v.state : "unknown",
        message: typeof v.message === "string" ? v.message : "",
        available: v.available === true,
        changed: v.changed === true,
      }));
  } catch {
    return [];
  }
}

function runAgentHooks(
  opts: RunAgentHooksOptions,
): Promise<AgentHookInstallResult> {
  const backendRoot = opts.backendRoot ?? backendRootFromModule();
  const nodePath = join(backendRoot, "node", "bin", "node");
  const nodeBin = existsSync(nodePath) ? nodePath : process.execPath;
  const installer = join(backendRoot, "bin", "install-agent-hooks.mjs");
  if (!existsSync(installer)) {
    return Promise.resolve({
      ok: false,
      exitCode: null,
      statuses: [],
      stdout: "",
      stderr: `agent hook installer not found at ${installer}`,
    });
  }

  const spawnImpl = opts.runner ?? spawn;
  return new Promise((resolve) => {
    const stdoutChunks: Buffer[] = [];
    const stderrChunks: Buffer[] = [];
    const args = opts.check
      ? [installer, "--json", "--check"]
      : [installer, "--json"];
    const child = spawnImpl(nodeBin, args, {
      env: opts.env ?? process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    child.stdout?.on("data", (chunk: Buffer) => appendCapped(stdoutChunks, chunk));
    child.stderr?.on("data", (chunk: Buffer) => appendCapped(stderrChunks, chunk));
    child.on("error", (err) => {
      resolve({
        ok: false,
        exitCode: null,
        statuses: [],
        stdout: Buffer.concat(stdoutChunks).toString("utf8"),
        stderr:
          Buffer.concat(stderrChunks).toString("utf8") +
          `agent hook installer failed to start: ${err.message}`,
      });
    });
    child.on("close", (code) => {
      const stdout = Buffer.concat(stdoutChunks).toString("utf8");
      const stderr = Buffer.concat(stderrChunks).toString("utf8");
      resolve({
        ok: code === 0,
        exitCode: code,
        statuses: parseStatuses(stdout),
        stdout,
        stderr,
      });
    });
  });
}

export function installAgentHooks(
  opts: InstallAgentHooksOptions = {},
): Promise<AgentHookInstallResult> {
  return runAgentHooks({ ...opts, check: false });
}

export function getAgentHookStatus(
  opts: InstallAgentHooksOptions = {},
): Promise<AgentHookInstallResult> {
  return runAgentHooks({ ...opts, check: true });
}
