// Workspace-scoped file-name search.
//
// Pure pull RPC: a fresh `readdir` walk per call (acceptable for v0; lazy
// indexing is a post-v0 concern — see issue #56 "Out of scope").
//
// Three pieces:
//   1. The walker. Recursive readdir with `withFileTypes: true`. Symlinks
//      are skipped entirely (never followed, never returned) so a symlinked
//      directory cannot smuggle external paths into the result set — same
//      scope posture as `fs.readFile`.
//   2. The ignore filter. By default we honor the workspace's top-level
//      `.gitignore` AND a hard-coded noise list (`node_modules`, `.git`,
//      `dist`, `build`, `.dart_tool`, `target`, `vendor`). `includeIgnored:
//      true` skips both filters entirely — there's no half-way state.
//   3. The fuzzy scorer. Subsequence match against the path, with bonuses
//      for basename hits, consecutive characters, and segment boundaries.
//      Returns null when any query char doesn't appear in order.
//
// The function returns up to `limit` matches sorted by score (high first)
// plus a `truncated` flag indicating whether the walker found more than
// `limit` scoring matches before stopping.

import { promises as fs, type Dirent } from "node:fs";
import { join, relative, sep } from "node:path";
import ignoreFactory, { type Ignore } from "ignore";

export interface FindFilesMatch {
  /// Workspace-relative path, POSIX separators.
  path: string;
  /// Higher = better match. Opaque integer; only ordering is contractual.
  score: number;
}

export interface FindFilesResult {
  matches: FindFilesMatch[];
  truncated: boolean;
}

export interface FindFilesOptions {
  query: string;
  limit: number;
  includeIgnored: boolean;
}

/// Noise directories that we always skip when `includeIgnored:false`, even
/// if they aren't listed in `.gitignore`. Most repos hit at least one of
/// these and the cost of walking them is a measurable fraction of the RPC
/// budget. Names are matched against the immediate directory name only —
/// `node_modules` deep inside a project still gets pruned, but a file
/// literally named `node_modules.txt` is fine.
const DEFAULT_NOISE_DIRS = new Set<string>([
  "node_modules",
  ".git",
  "dist",
  "build",
  ".dart_tool",
  "target",
  "vendor",
]);

/// Cap on candidate paths considered. The performance budget in #56 is
/// ~300 ms on a 10k-file tree; this ceiling prevents a pathological repo
/// (100k+ files, all unscoring) from blowing the budget. When hit, we
/// flip `truncated` and stop walking — better a partial result than a
/// timed-out RPC.
const MAX_CANDIDATES = 50_000;

export async function findFiles(
  workspaceRoot: string,
  opts: FindFilesOptions,
): Promise<FindFilesResult> {
  const query = opts.query.trim();
  if (query.length === 0) {
    return { matches: [], truncated: false };
  }
  const ignoreMatcher = opts.includeIgnored
    ? null
    : await loadIgnoreMatcher(workspaceRoot);

  // Top-K is small (≤ 200), but scanning all candidates would still be O(N
  // log N) if we kept everything. Track a running array sorted by score —
  // insert each scoring match, drop the lowest when we exceed `limit`.
  // Using a simple sorted array since `limit` is bounded at 200; the cost
  // of one insertion is dwarfed by the readdir IO it accompanies.
  const top: FindFilesMatch[] = [];
  let truncated = false;
  let candidates = 0;

  const queryLower = query.toLowerCase();

  async function walk(absDir: string): Promise<void> {
    let entries: Dirent[];
    try {
      entries = await fs.readdir(absDir, { withFileTypes: true });
    } catch {
      // Permission denied / vanished directory — skip silently.
      return;
    }
    for (const ent of entries) {
      if (candidates >= MAX_CANDIDATES) {
        truncated = true;
        return;
      }
      const name = ent.name;
      const abs = join(absDir, name);
      const rel = relative(workspaceRoot, abs).split(sep).join("/");
      // Skip symlinks entirely. This is the same posture as fs.readFile:
      // we refuse to follow links so scope cannot be escaped. Returning
      // them as files would imply a downstream readFile that the scope
      // check would then refuse — incoherent UX.
      if (ent.isSymbolicLink()) {
        continue;
      }
      if (ent.isDirectory()) {
        if (!opts.includeIgnored) {
          if (DEFAULT_NOISE_DIRS.has(name)) continue;
          // `ignore` requires a trailing slash for directory matching to
          // honor patterns like `build/`.
          if (ignoreMatcher !== null && ignoreMatcher.ignores(`${rel}/`)) {
            continue;
          }
        }
        await walk(abs);
        continue;
      }
      if (!ent.isFile()) continue;
      if (!opts.includeIgnored && ignoreMatcher !== null) {
        if (ignoreMatcher.ignores(rel)) continue;
      }
      candidates++;
      const score = scoreMatch(queryLower, rel);
      if (score === null) continue;
      insertTop(top, { path: rel, score }, opts.limit);
    }
  }

  await walk(workspaceRoot);
  // `top` is maintained sorted asc by score (lowest first); flip for output.
  top.sort((a, b) => b.score - a.score || a.path.localeCompare(b.path));
  return { matches: top, truncated };
}

/// Score `path` against `queryLower`. Returns null when `query` is not a
/// (case-insensitive) subsequence of `path`. Higher scores are better.
///
/// Heuristics:
///   * +consecutive: matching two query chars adjacently is better than
///     scattered hits.
///   * +basename: matches in the trailing path segment (after the last `/`)
///     score higher than matches in deep directory prefixes.
///   * +segment-boundary: a match right after `/`, `.`, `_`, `-`, or ` `
///     scores higher (mirrors how users think — they type the start of a
///     word, not its middle).
///   * Length penalty: ties are broken in favor of shorter paths so a
///     query like "main" prefers `main.ts` over `src/lib/some/main.ts`.
export function scoreMatch(queryLower: string, path: string): number | null {
  const pathLower = path.toLowerCase();
  const basenameStart = pathLower.lastIndexOf("/") + 1;

  let score = 0;
  let lastMatchPos = -2;
  let p = 0;
  for (let q = 0; q < queryLower.length; q++) {
    const ch = queryLower[q] as string;
    const idx = pathLower.indexOf(ch, p);
    if (idx === -1) return null;
    let charScore = 1;
    if (idx === lastMatchPos + 1) {
      charScore += 4;
    }
    if (idx >= basenameStart) {
      charScore += 3;
    }
    if (idx === 0) {
      charScore += 2;
    } else {
      const prev = pathLower[idx - 1];
      if (prev === "/" || prev === "." || prev === "_" || prev === "-" || prev === " ") {
        charScore += 2;
      }
    }
    score += charScore;
    lastMatchPos = idx;
    p = idx + 1;
  }
  // Multiply so length penalty stays a tiebreaker, never overtakes a real
  // hit. Path length is bounded by filesystem realities (< 4096 chars), so
  // this keeps the headline weight on consecutive / basename / boundary.
  return score * 1000 - pathLower.length;
}

/// Sorted-ascending insert into `top`; truncate at `limit`.
function insertTop(
  top: FindFilesMatch[],
  entry: FindFilesMatch,
  limit: number,
): void {
  if (top.length < limit) {
    top.push(entry);
    // Bubble small entry toward the start so `top[0]` is always the
    // lowest score — the candidate to evict next. (Linear, but `limit`
    // is bounded at 200 so this is cheap.)
    let i = top.length - 1;
    while (i > 0 && top[i - 1]!.score > top[i]!.score) {
      const a = top[i - 1]!;
      const b = top[i]!;
      top[i - 1] = b;
      top[i] = a;
      i--;
    }
    return;
  }
  if (entry.score <= top[0]!.score) return;
  top[0] = entry;
  // Bubble new entry up to its sorted position.
  let i = 0;
  while (i < top.length - 1 && top[i]!.score > top[i + 1]!.score) {
    const a = top[i]!;
    const b = top[i + 1]!;
    top[i] = b;
    top[i + 1] = a;
    i++;
  }
}

async function loadIgnoreMatcher(workspaceRoot: string): Promise<Ignore> {
  const matcher = ignoreFactory();
  try {
    const content = await fs.readFile(
      join(workspaceRoot, ".gitignore"),
      "utf8",
    );
    matcher.add(content);
  } catch {
    // Missing .gitignore is fine — the noise-dir list still applies.
  }
  return matcher;
}
