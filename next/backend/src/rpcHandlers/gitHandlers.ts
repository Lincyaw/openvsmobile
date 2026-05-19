// `git.*` JSON-RPC handlers extracted out of rpc.ts so the dispatch file
// stays under a navigable size. Pure move — no logic changes from the prior
// inline implementation. Registered via `register(methods)` from rpc.ts;
// the methods table itself stays private to rpc.ts.

import { stat as fsStat } from "node:fs/promises";
import { join as pathJoin } from "node:path";
import {
  hashWorkingFile,
  indexBlobSha,
  isGitRepo,
  pathInIndex,
  pathInTree,
  readHeadInfo,
  readLogPage,
  readStatus,
  resolveRef,
  runDiffArgs,
} from "../git.js";
import { parseUnifiedDiff, type DiffHunk } from "../diffParser.js";
import {
  asBag,
  optionalString,
  requireString,
  RPC_ERR,
  RpcError,
  type MethodRegistry,
} from "../rpc.js";

// ---- Constants ----

/// Cap unified-diff text at 500 KiB. Beyond that we surface `tooLarge: true`
/// rather than ship the patch over a phone link. The cap matches design-doc
/// section 2.2 (binary / >500KB / deleted files render an explanatory
/// placeholder, not the diff); it is intentionally lower than git's own
/// maxBuffer (8 MiB) so the wire payload stays bounded even when git is
/// happy to keep going.
const DIFF_TEXT_LIMIT_BYTES = 500 * 1024;

/// Sentinel returned in `baseSha` / `headSha` when the slot has no real blob
/// to point at: deleted working-tree file, or `INDEX` for a path not in the
/// index. 40 chars so the wire field is always a fixed-width SHA-like
/// string.
const ZERO_SHA = "0000000000000000000000000000000000000000";

/// `git.log` page size bounds. The upper cap keeps a single response within
/// a reasonable wire payload (a 200-entry page with bodies is well under
/// 1 MiB in practice); the floor exists because `0` or negative is treated
/// as "I don't care, give me the default" rather than as an error.
const GIT_LOG_MAX_LIMIT = 200;
const GIT_LOG_DEFAULT_LIMIT = 50;

// ---- Wire shapes ----

/// Wire-shape hunk. Narrows DiffParser's DiffLine.kind to the three values
/// the protocol commits to. Internal `noNewline` markers are dropped at the
/// RPC boundary.
interface WireHunk {
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  header: string;
  lines: { kind: "context" | "add" | "del"; text: string }[];
}

interface GitDiffResult {
  hunks: WireHunk[];
  baseSha: string;
  headSha: string;
  isBinary: boolean;
  tooLarge?: true;
}

interface DecodedLogCursor {
  pinnedSha: string;
  offset: number;
}

// ---- Registration ----

export function register(methods: MethodRegistry): void {
  // Pull RPC for the working-tree status. Pairs with the workspace.subscribe
  // push surface (which carries deltas); callers use this when they need a
  // full snapshot on demand outside the subscribe path.
  methods.set("git.status", async (ctx, params) => {
    const p = asBag(params);
    const ws = ctx.state.workspaces.requireById(p.workspaceId);
    if (!(await isGitRepo(ws.root))) {
      return {
        isGitRepo: false,
        branch: null,
        ahead: 0,
        behind: 0,
        entries: [],
      };
    }
    const [head, entries] = await Promise.all([
      readHeadInfo(ws.root),
      readStatus(ws.root),
    ]);
    return {
      isGitRepo: true,
      branch: head?.branch ?? null,
      ahead: head?.ahead ?? 0,
      behind: head?.behind ?? 0,
      entries: entries.map((e) => ({ path: e.path, status: e.status })),
    };
  });

  methods.set("git.diff", async (ctx, params) => {
    const p = asBag(params);
    const ws = ctx.state.workspaces.requireById(p.workspaceId);
    const path = requireString(p, "path");
    const base = optionalString(p, "base") ?? "HEAD";
    // `head` is allowed to be explicitly null (working tree) or a string
    // (ref / "INDEX"). Missing param is treated as null per the protocol
    // default.
    const headParam = p.head;
    if (
      headParam !== undefined &&
      headParam !== null &&
      typeof headParam !== "string"
    ) {
      throw new RpcError(
        RPC_ERR.invalidParams,
        "head must be a string or null when provided",
      );
    }
    const head: string | null =
      headParam === undefined || headParam === null
        ? null
        : (headParam as string);

    // Existence pre-check. A path that has never lived anywhere (working
    // tree, index, or either ref's tree) is a caller bug — surface
    // invalidParams rather than silently returning an empty diff.
    await assertPathExists(ws.root, path, base, head);

    const baseSha = await resolveBaseSha(ws.root, base, path);
    const headSha = await resolveHeadSha(ws.root, head, path);
    // Content-addressed cache key (first principle #3). Two callers asking
    // for the same (workspace, path, baseSha, headSha) get the same patch
    // byte-for-byte, so a second resolve short-circuits the git spawn.
    const cacheKey = `${ws.id} ${path} ${baseSha} ${headSha}`;
    const cached = ctx.state.diffCache.get(cacheKey) as
      | GitDiffResult
      | undefined;
    if (cached !== undefined) return cached;

    const selectorArgs = buildDiffSelectorArgs(base, head);
    const { stdout, tooLarge: bufferOverflow } = await runDiffArgs(
      ws.root,
      selectorArgs,
      path,
    );

    // Binary detection. Git auto-detects and emits a literal
    //   `Binary files a/x and b/x differ`
    // line inside the patch when the blob has NUL bytes. The marker can
    // show up at the start of stdout (no `diff --git` preamble in some
    // shapes) or after it; scanning the body covers every permutation.
    const isBinary = /(^|\n)Binary files .* and .* differ\n?/.test(stdout);

    const overSize = stdout.length > DIFF_TEXT_LIMIT_BYTES;
    const tooLarge = bufferOverflow || overSize;

    let hunks: WireHunk[] = [];
    if (!isBinary && !tooLarge) {
      hunks = toWireHunks(parseUnifiedDiff(stdout));
    }

    const result: GitDiffResult = {
      hunks,
      baseSha,
      headSha,
      isBinary,
    };
    if (tooLarge) {
      result.tooLarge = true;
    }
    ctx.state.diffCache.set(cacheKey, result);
    return result;
  });

  methods.set("git.log", async (ctx, params) => {
    const p = asBag(params);
    const ws = ctx.state.workspaces.requireById(p.workspaceId);
    const path = optionalString(p, "path");
    const cursor = optionalString(p, "cursor");
    const decoded = decodeLogCursor(cursor);
    // Clamp limit per the brief: [1, 200], default to 50 on
    // 0/negative/missing.
    const rawLimit = p.limit;
    let limit: number;
    if (rawLimit === undefined || rawLimit === null) {
      limit = GIT_LOG_DEFAULT_LIMIT;
    } else if (typeof rawLimit !== "number" || !Number.isFinite(rawLimit)) {
      throw new RpcError(RPC_ERR.invalidParams, "limit must be a number");
    } else {
      const n = Math.trunc(rawLimit);
      limit = n <= 0 ? GIT_LOG_DEFAULT_LIMIT : Math.min(n, GIT_LOG_MAX_LIMIT);
    }
    const opts: {
      path?: string;
      limit: number;
      skip?: number;
      pinnedSha?: string;
    } = { limit };
    if (path !== undefined) opts.path = path;
    if (decoded !== null) {
      opts.skip = decoded.offset;
      opts.pinnedSha = decoded.pinnedSha;
    }
    const entries = await readLogPage(ws.root, opts);
    // No entries + no cursor → either a non-git workspace, an empty repo,
    // or a path that has never been touched. Per the brief, that surfaces
    // as `{ entries: [] }` (no error, no cursor).
    if (entries.length === 0) {
      return { entries };
    }
    // Pin to the head of *this* walk. On the first page the head is just
    // entries[0]. On subsequent pages it's whatever the cursor carried —
    // never re-resolve HEAD inside a walk, that's how you get duplicates
    // when new commits land mid-pagination.
    const pinnedSha = decoded !== null ? decoded.pinnedSha : entries[0].sha;
    const previousOffset = decoded !== null ? decoded.offset : 0;
    const nextOffset = previousOffset + entries.length;
    // Fewer rows than asked-for means git has nothing else to give us, so
    // we drop the cursor to signal end-of-stream. A full page might or
    // might not have more; emit a cursor and let the next call return an
    // empty page if it turns out to be the boundary.
    if (entries.length < limit) {
      return { entries };
    }
    return { entries, nextCursor: encodeLogCursor(pinnedSha, nextOffset) };
  });
}

// ---- Helpers ----

/// `git.log` cursors are opaque on the wire. Today they're a base64-encoded
/// JSON blob `{ h: <sha>, o: <skipCount> }`; the encoding is *not* part of
/// the protocol contract — a future change can swap the strategy without
/// breaking clients as long as the same opaque-token round-trip semantics
/// hold.
function encodeLogCursor(pinnedSha: string, offset: number): string {
  const payload = JSON.stringify({ h: pinnedSha, o: offset });
  return Buffer.from(payload, "utf8").toString("base64");
}

function decodeLogCursor(cursor: string | undefined): DecodedLogCursor | null {
  if (cursor === undefined || cursor.length === 0) return null;
  let raw: string;
  try {
    raw = Buffer.from(cursor, "base64").toString("utf8");
  } catch {
    throw new RpcError(RPC_ERR.invalidParams, "cursor is not valid base64");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new RpcError(RPC_ERR.invalidParams, "cursor is malformed");
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new RpcError(RPC_ERR.invalidParams, "cursor is malformed");
  }
  const obj = parsed as { h?: unknown; o?: unknown };
  if (
    typeof obj.h !== "string" ||
    obj.h.length === 0 ||
    typeof obj.o !== "number" ||
    !Number.isInteger(obj.o) ||
    obj.o < 0
  ) {
    throw new RpcError(RPC_ERR.invalidParams, "cursor is malformed");
  }
  return { pinnedSha: obj.h, offset: obj.o };
}

/// Translate (base, head) into the args that go AFTER `git diff` and BEFORE
/// the pathspec. Throws invalidParams for nonsensical combinations.
function buildDiffSelectorArgs(base: string, head: string | null): string[] {
  if (head === null) {
    if (base === "INDEX") {
      // Bare `git diff -- <path>` = index to working tree.
      return [];
    }
    return [base];
  }
  if (head === "INDEX") {
    if (base === "INDEX") {
      throw new RpcError(
        RPC_ERR.invalidParams,
        "base and head cannot both be INDEX",
      );
    }
    return ["--cached", base];
  }
  if (base === "INDEX") {
    throw new RpcError(
      RPC_ERR.invalidParams,
      "INDEX as base only supported with head=null or head=INDEX",
    );
  }
  return [base, head];
}

async function resolveBaseSha(
  cwd: string,
  base: string,
  path: string,
): Promise<string> {
  if (base === "INDEX") {
    return (await indexBlobSha(cwd, path)) ?? ZERO_SHA;
  }
  const sha = await resolveRef(cwd, base);
  if (sha === null) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `cannot resolve base ref: ${base}`,
    );
  }
  return sha;
}

async function resolveHeadSha(
  cwd: string,
  head: string | null,
  path: string,
): Promise<string> {
  if (head === null) {
    return (await hashWorkingFile(cwd, path)) ?? ZERO_SHA;
  }
  if (head === "INDEX") {
    return (await indexBlobSha(cwd, path)) ?? ZERO_SHA;
  }
  const sha = await resolveRef(cwd, head);
  if (sha === null) {
    throw new RpcError(
      RPC_ERR.invalidParams,
      `cannot resolve head ref: ${head}`,
    );
  }
  return sha;
}

async function assertPathExists(
  cwd: string,
  path: string,
  base: string,
  head: string | null,
): Promise<void> {
  // Working tree first: a present file is the cheapest "yes".
  try {
    await fsStat(pathJoin(cwd, path));
    return;
  } catch {
    // not on disk; keep looking
  }
  // Index covers staged additions even before the first commit.
  if (await pathInIndex(cwd, path)) return;
  // Commit trees on either side of the requested diff.
  const refs = new Set<string>();
  if (base !== "INDEX") refs.add(base);
  if (head !== null && head !== "INDEX") refs.add(head);
  for (const ref of refs) {
    const resolved = await resolveRef(cwd, ref);
    if (resolved === null) continue;
    if (await pathInTree(cwd, resolved, path)) return;
  }
  throw new RpcError(RPC_ERR.invalidParams, `no such path: ${path}`);
}

function toWireHunks(hunks: DiffHunk[]): WireHunk[] {
  return hunks.map((h) => ({
    oldStart: h.oldStart,
    oldLines: h.oldLines,
    newStart: h.newStart,
    newLines: h.newLines,
    header: h.header,
    lines: h.lines
      .filter((l) => l.kind !== "noNewline")
      .map((l) => ({
        kind: l.kind as "context" | "add" | "del",
        text: l.text,
      })),
  }));
}
