// Thin async wrapper around the `git` CLI, invoked via execFile (no shell).
// We deliberately do NOT use nodegit / isomorphic-git: spawning the real git
// gives us identical behavior to "what the user sees in their terminal",
// including submodules, LFS, hooks, custom configs, and worktree quirks. No
// library will ever match that fidelity, and we are happy to pay a process
// spawn cost on watcher-driven drains.

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const GIT_BIN = "git";
const GIT_TIMEOUT_MS = 10_000;
// Cap stdout per invocation. `git diff` can run away on huge files; we want
// a hard ceiling rather than letting Node buffer arbitrarily.
const GIT_MAX_BUFFER = 8 * 1024 * 1024; // 8 MiB

export interface GitHeadInfo {
  branch: string;       // detached HEAD surfaces as "HEAD"
  headSha: string;
  ahead: number;        // 0 when no upstream
  behind: number;       // 0 when no upstream
}

export interface GitStatusEntry {
  path: string;
  // Single-letter status. We collapse staged + worktree into one user-facing
  // letter, with priority M > A > D > U > ? (matches what the UI cares about
  // for decoration).
  status: "M" | "A" | "D" | "?" | "U";
  // Rename source path, if status came from a rename. The new path lives in
  // `path` (matches `git status --porcelain=v2 -z` semantics).
  renamedFrom?: string;
}

export interface GitLogEntry {
  sha: string;
  author: string;
  date: string;     // ISO-8601 with tz offset
  subject: string;
}

/// Resolve current branch + HEAD sha + upstream tracking divergence in a
/// single tight burst of git invocations. Designed to be cheap enough that
/// the drain loop can call it once per debounce window.
export async function readHeadInfo(cwd: string): Promise<GitHeadInfo | null> {
  const branch = await runGitOptional(["rev-parse", "--abbrev-ref", "HEAD"], cwd);
  if (branch === null) return null;
  const headSha = await runGitOptional(["rev-parse", "HEAD"], cwd);
  if (headSha === null) {
    // Repo exists but has no commits yet. Surface as branch + empty sha.
    return { branch: branch.trim(), headSha: "", ahead: 0, behind: 0 };
  }
  // rev-list with @{upstream} fails (exit 128) when no upstream is configured.
  // We treat that as "not tracking" — ahead/behind = 0 — not as an error.
  const tracking = await runGitOptional(
    ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"],
    cwd,
  );
  let behind = 0;
  let ahead = 0;
  if (tracking !== null) {
    const m = /^(\d+)\s+(\d+)/.exec(tracking.trim());
    if (m) {
      behind = Number(m[1]);
      ahead = Number(m[2]);
    }
  }
  return { branch: branch.trim(), headSha: headSha.trim(), ahead, behind };
}

/// Run `git status --porcelain=v2 -z --find-renames` and parse it into a flat
/// entry list. `-z` separates entries by NUL so paths containing spaces /
/// newlines round-trip cleanly. We do not surface staged-vs-worktree
/// distinctions in v0 — the UI's decoration vocabulary is M/A/D/U/?.
export async function readStatus(cwd: string): Promise<GitStatusEntry[]> {
  const out = await runGitOptional(
    ["status", "--porcelain=v2", "-z", "--find-renames", "--untracked-files=all"],
    cwd,
  );
  if (out === null) return [];
  return parsePorcelainV2(out);
}

/// Run a single `git diff` invocation with caller-supplied "selector" args
/// (the bits that come AFTER `diff` and BEFORE the pathspec — e.g. `HEAD`,
/// `--cached`, or `<base> <head>`). Returns the raw stdout plus a `tooLarge`
/// flag for the buffer-overflow case.
///
/// We deliberately do NOT detect binary-vs-text here: git auto-detects and
/// emits a `Binary files a/x and b/x differ` marker inline. The caller
/// inspects that marker, so we get binary + text + content in one spawn
/// rather than the old two-spawn (numstat + diff) pattern.
export async function runDiffArgs(
  cwd: string,
  selectorArgs: string[],
  path: string,
): Promise<{ stdout: string; tooLarge: boolean }> {
  const args = [
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--unified=3",
    ...selectorArgs,
    "--",
    path,
  ];
  try {
    const { stdout } = await execFileAsync(GIT_BIN, args, {
      cwd,
      timeout: GIT_TIMEOUT_MS,
      maxBuffer: GIT_MAX_BUFFER,
      windowsHide: true,
    });
    return { stdout, tooLarge: false };
  } catch (err) {
    // ERR_CHILD_PROCESS_STDIO_MAXBUFFER → caller should report "too-large".
    const code = (err as NodeJS.ErrnoException).code;
    if (code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER") {
      return { stdout: "", tooLarge: true };
    }
    throw err;
  }
}

/// Resolve a ref (branch, tag, commit-ish) to its full 40-char SHA. Returns
/// null when the ref is unknown — callers turn that into invalidParams.
export async function resolveRef(cwd: string, ref: string): Promise<string | null> {
  const out = await runGitOptional(
    ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`],
    cwd,
  );
  if (out === null) return null;
  const trimmed = out.trim();
  return trimmed.length > 0 ? trimmed : null;
}

/// SHA of the working-tree file's current contents. Returns null when the
/// file does not exist on disk (e.g. deleted vs HEAD). Used as `headSha` for
/// the "vs working tree" diff so the client's cache key invalidates the
/// moment the file changes.
export async function hashWorkingFile(
  cwd: string,
  path: string,
): Promise<string | null> {
  const out = await runGitOptional(["hash-object", "--", path], cwd);
  if (out === null) return null;
  const trimmed = out.trim();
  return trimmed.length > 0 ? trimmed : null;
}

/// SHA of the file's staged blob in the index. Returns null when the path is
/// not in the index (untracked, or matches an entry only in a commit tree).
export async function indexBlobSha(
  cwd: string,
  path: string,
): Promise<string | null> {
  const out = await runGitOptional(
    ["ls-files", "--stage", "--", path],
    cwd,
  );
  if (out === null) return null;
  // `<mode> <sha> <stage>\t<path>` — extract the second field.
  const match = /^\S+\s+(\S+)\s+\S+\t/.exec(out);
  return match ? match[1] : null;
}

/// True when the file path is reachable in `commitRef`'s tree. Used to decide
/// whether a deleted-from-working-tree path can still be diffed against an
/// ancestor commit.
export async function pathInTree(
  cwd: string,
  commitRef: string,
  path: string,
): Promise<boolean> {
  const out = await runGitOptional(
    ["ls-tree", "--name-only", commitRef, "--", path],
    cwd,
  );
  return out !== null && out.trim().length > 0;
}

/// True when the file path is in the index.
export async function pathInIndex(cwd: string, path: string): Promise<boolean> {
  const out = await runGitOptional(["ls-files", "--", path], cwd);
  return out !== null && out.trim().length > 0;
}

/// `git log` for a workspace or path. Output formatted as `<sha>\x01<author>\x01<date>\x01<subject>`
/// per line so we don't have to escape paths.
export async function readLog(
  cwd: string,
  options: { path?: string; limit: number; beforeSha?: string },
): Promise<GitLogEntry[]> {
  const args = [
    "log",
    `--max-count=${options.limit}`,
    "--pretty=format:%H%x01%an%x01%aI%x01%s",
  ];
  if (options.beforeSha !== undefined && options.beforeSha.length > 0) {
    args.push(`${options.beforeSha}~1`);
  }
  if (options.path !== undefined && options.path.length > 0) {
    args.push("--", options.path);
  }
  const out = await runGitOptional(args, cwd);
  if (out === null) return [];
  const entries: GitLogEntry[] = [];
  for (const line of out.split("\n")) {
    if (line.length === 0) continue;
    const parts = line.split("\x01");
    if (parts.length < 4) continue;
    entries.push({
      sha: parts[0],
      author: parts[1],
      date: parts[2],
      subject: parts.slice(3).join("\x01"),
    });
  }
  return entries;
}

/// `git rev-list oldSha..newSha` — commits introduced on the current branch by
/// the most recent move. Oldest first. Empty array on no-op.
export async function revList(
  cwd: string,
  oldSha: string,
  newSha: string,
): Promise<string[]> {
  if (oldSha.length === 0 || newSha.length === 0 || oldSha === newSha) {
    return [];
  }
  const out = await runGitOptional(
    ["rev-list", "--reverse", `${oldSha}..${newSha}`],
    cwd,
  );
  if (out === null) return [];
  return out.split("\n").filter((s) => s.length > 0);
}

/// Read a commit's subject line. Used to populate workspace.commit.added.
export async function readCommitSubject(
  cwd: string,
  sha: string,
): Promise<string> {
  const out = await runGitOptional(
    ["log", "-1", "--pretty=format:%s", sha],
    cwd,
  );
  return out === null ? "" : out.trimEnd();
}

/// Quick check: is this directory a git repo at all? Used at workspace-open
/// time to decide whether to start the git metadata watcher.
export async function isGitRepo(cwd: string): Promise<boolean> {
  const out = await runGitOptional(
    ["rev-parse", "--is-inside-work-tree"],
    cwd,
  );
  return out !== null && out.trim() === "true";
}

// ---- private ----

/// Run a git command. Returns stdout on success, null on any failure
/// (non-zero exit, ENOENT, timeout). We do not surface git's stderr to the
/// caller — drain loops should keep marching on "git failed once" because the
/// next watcher tick will retry.
async function runGitOptional(
  args: string[],
  cwd: string,
): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync(GIT_BIN, args, {
      cwd,
      timeout: GIT_TIMEOUT_MS,
      maxBuffer: GIT_MAX_BUFFER,
      windowsHide: true,
      // GIT_OPTIONAL_LOCKS=0 stops `git status` from waiting on .git/index.lock
      // when another git process is mid-operation. We are observing, not
      // mutating — never block our drain on someone else's lock.
      env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" },
    });
    return stdout;
  } catch {
    return null;
  }
}

/// Parse `git status --porcelain=v2 -z` output into our entry shape. The
/// porcelain v2 format is well documented: each entry begins with a single
/// character indicating its record type (`1` = changed, `2` = renamed/copied,
/// `?` = untracked, `u` = unmerged), followed by tab-separated fields, with
/// entries separated by NUL. Renames have a second NUL between new and old
/// paths.
function parsePorcelainV2(raw: string): GitStatusEntry[] {
  const entries: GitStatusEntry[] = [];
  // Split on NUL; for rename entries, the second NUL separates the old path,
  // so we have to special-case the join.
  const tokens = raw.split("\0");
  let i = 0;
  while (i < tokens.length) {
    const tok = tokens[i];
    if (tok.length === 0) {
      i++;
      continue;
    }
    const kind = tok.charAt(0);
    if (kind === "1") {
      // "1 XY <sub> <mH> <mI> <mW> <hH> <hI> <path>"
      const path = extractPathFromV2Changed(tok);
      const xy = tok.slice(2, 4);
      const status = collapseXY(xy);
      if (path !== null && status !== null) {
        entries.push({ path, status });
      }
      i++;
    } else if (kind === "2") {
      // "2 XY <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>" then NUL
      // <origPath>. The original-path token lives in the NEXT element.
      const path = extractPathFromV2Changed(tok);
      const xy = tok.slice(2, 4);
      const origPath = tokens[i + 1] ?? "";
      if (path !== null) {
        entries.push({
          path,
          status: collapseXY(xy) ?? "M",
          renamedFrom: origPath.length > 0 ? origPath : undefined,
        });
      }
      i += 2;
    } else if (kind === "?") {
      // "? <path>"
      const path = tok.slice(2);
      entries.push({ path, status: "?" });
      i++;
    } else if (kind === "u") {
      // "u XY <sub> ..." — unmerged. Path is the last field after several
      // mode/sha tokens; rather than count them, take everything after the
      // last space.
      const lastSpace = tok.lastIndexOf(" ");
      const path = lastSpace >= 0 ? tok.slice(lastSpace + 1) : "";
      if (path.length > 0) entries.push({ path, status: "U" });
      i++;
    } else if (kind === "#") {
      // Header line ("# branch.oid ...") — we read HEAD info separately. Skip.
      i++;
    } else {
      // Unknown record kind; skip rather than crash.
      i++;
    }
  }
  return entries;
}

/// In porcelain v2 records 1 and 2, the path is the final whitespace-
/// separated field. Quoting is off (we used `-z`) so we can split safely.
function extractPathFromV2Changed(record: string): string | null {
  // Fields are space-separated up to and INCLUDING the path, but the path may
  // legitimately contain spaces. We know there are 8 leading fields before
  // the path for kind "1" (status, sub, mH, mI, mW, hH, hI = 7 + initial "1"
  // = 8 tokens), and 9 for kind "2" (extra: <X><score>). Counting tokens is
  // brittle; instead, locate the path by skipping the known prefix.
  // Kind 1: "1 XY <sub> <mH> <mI> <mW> <hH> <hI> <path>"
  // Kind 2: "2 XY <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>"
  const fieldsBeforePath = record.charAt(0) === "2" ? 9 : 8;
  let pos = 0;
  for (let f = 0; f < fieldsBeforePath; f++) {
    const next = record.indexOf(" ", pos);
    if (next < 0) return null;
    pos = next + 1;
  }
  return record.slice(pos);
}

/// Collapse the staged/worktree XY pair into a single decoration letter.
/// Priority: deletion wins over modify (the file is gone), add over modify
/// (the file is new), unmerged wins over everything else. R/C entries
/// collapse to "M" — the rename source path lives in `renamedFrom`, not in
/// the status letter; we never decorate the new path with an "R" because the
/// UI vocabulary is M/A/D/?/U.
function collapseXY(xy: string): "M" | "A" | "D" | "U" | null {
  const x = xy.charAt(0);
  const y = xy.charAt(1);
  if (x === "U" || y === "U" || (x === "D" && y === "D") || (x === "A" && y === "A")) {
    return "U";
  }
  if (x === "D" || y === "D") return "D";
  if (x === "A" || y === "A") return "A";
  if (x === "M" || y === "M" || x === "R" || y === "R" || x === "C" || y === "C") {
    return "M";
  }
  if (x === "." && y === ".") return null;
  return "M";
}
