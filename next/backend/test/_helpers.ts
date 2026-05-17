// Test helpers: create a real git repo in a tempdir, drive git commands, and
// build a minimal WebSocket stub that captures notifications.
//
// Per docs/conventions.md §6: no FS / PTY mocks; real things in temp dirs.
// `git` is invoked via the system binary — same as the production code path.

import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile, mkdir, realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function makeTempDir(prefix: string): Promise<string> {
  // realpath because macOS resolves /var → /private/var; the model stores the
  // realpath'd root and would otherwise mismatch path-prefix checks in tests.
  const d = await mkdtemp(join(tmpdir(), prefix));
  return await realpath(d);
}

export async function rmTempDir(path: string): Promise<void> {
  // Recursive + force so a half-written test doesn't leave anything behind.
  await rm(path, { recursive: true, force: true });
}

export async function makeRepo(path: string): Promise<void> {
  await git(path, ["init", "-q", "-b", "main"]);
  // Detach the repo from a global user.name/user.email — tests run unattended,
  // and `git commit` insists on both being set.
  await git(path, ["config", "user.email", "test@example.invalid"]);
  await git(path, ["config", "user.name", "Test"]);
  // Disable signing — release engineers sometimes have it on globally.
  await git(path, ["config", "commit.gpgsign", "false"]);
}

export async function git(cwd: string, args: string[]): Promise<string> {
  const { stdout } = await execFileAsync("git", args, {
    cwd,
    env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" },
  });
  return stdout;
}

export async function writeWorkspaceFile(
  root: string,
  relPath: string,
  content: string,
): Promise<void> {
  const abs = join(root, relPath);
  const parent = abs.substring(0, abs.lastIndexOf("/"));
  if (parent.length > 0 && parent !== root) {
    await mkdir(parent, { recursive: true });
  }
  await writeFile(abs, content);
}

/// Sleep for `ms`. Used sparingly — when we need to give chokidar's
/// debounce/native-event pump a moment. Tests prefer `model.drainOnce()`
/// where possible.
export function sleep(ms: number): Promise<void> {
  return new Promise((res) => setTimeout(res, ms));
}

/// Minimal WebSocket stand-in. The model only calls `send` + reads
/// `readyState`; everything else is irrelevant to tests.
export class FakeWebSocket {
  public readonly OPEN = 1;
  public readyState = 1;
  public sent: Array<{ method?: string; params?: unknown; id?: unknown; result?: unknown; error?: unknown }> = [];

  public send(raw: string): void {
    this.sent.push(JSON.parse(raw));
  }

  public notifications(method: string): Array<{ method?: string; params?: unknown }> {
    return this.sent.filter((m) => m.method === method);
  }

  public close(): void {
    this.readyState = 3;
  }
}
