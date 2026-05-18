// PR Companion — pure helpers shared by render/*.js (Phase 3).
//
// Lives in its own file specifically so unit tests can import it
// without dragging in `@openvsmobile/sdk`. The example plugin
// directory has no `node_modules`; the SDK is provided by the host's
// sdk-loader at runtime. Tests run from `next/backend` and follow
// Node's normal resolution rules, which would fail on
// `import { ui } from "@openvsmobile/sdk"` from anywhere under
// `next/examples/plugins/pr-companion/`.
//
// Everything in this file MUST stay free of external imports (Node
// built-ins are fine if ever needed) so the import chain stays clean.

/**
 * Extension → highlight.js language identifier. Per resolved design
 * choice #3 in docs/design/plugins/pr-companion.md — kept small and
 * hardcoded; centralizing with the app-side
 * `highlight_theme.dart` map is v1 work.
 */
export const EXT_TO_LANG = {
  js: "javascript",
  ts: "typescript",
  tsx: "typescript",
  jsx: "javascript",
  dart: "dart",
  py: "python",
  go: "go",
  rs: "rust",
  java: "java",
  kt: "kotlin",
  swift: "swift",
  sh: "bash",
  bash: "bash",
  zsh: "bash",
  md: "markdown",
  json: "json",
  yaml: "yaml",
  yml: "yaml",
  html: "html",
  css: "css",
};

/**
 * Extract the extension (last `.`-delimited segment, lowercased) of a
 * basename and map it via EXT_TO_LANG. Returns `null` for files with
 * no extension (Dockerfile, Makefile), dotfiles (.gitignore — leading
 * `.` is not an extension), unknown extensions, or empty input.
 *
 * @param {string} filename
 * @returns {string | null}
 */
export function inferLanguage(filename) {
  if (typeof filename !== "string" || filename.length === 0) return null;
  // basename only — `pkg/sub/foo.ts` → `foo.ts`.
  const slash = filename.lastIndexOf("/");
  const base = slash === -1 ? filename : filename.slice(slash + 1);
  const dot = base.lastIndexOf(".");
  if (dot <= 0 || dot === base.length - 1) return null;
  const ext = base.slice(dot + 1).toLowerCase();
  return EXT_TO_LANG[ext] ?? null;
}

/**
 * Split a unified diff `patch` string into hunks. Each hunk starts
 * with `@@`; we keep the `@@` header line in the chunk so the user
 * can see the line numbers in context. Empty / non-string input
 * returns `[]`.
 *
 * Real GitHub patches always begin with `@@`; if a payload ever
 * doesn't (e.g. a one-line addition where GitHub elides the header),
 * we still yield the input as a single chunk so the user sees
 * something rather than nothing.
 *
 * @param {string | null} patch
 * @returns {string[]}
 */
export function splitHunks(patch) {
  if (typeof patch !== "string" || patch.length === 0) return [];
  const lines = patch.split("\n");
  /** @type {string[]} */
  const hunks = [];
  /** @type {string[]} */
  let current = [];
  for (const line of lines) {
    if (line.startsWith("@@")) {
      if (current.length > 0) hunks.push(current.join("\n"));
      current = [line];
    } else {
      current.push(line);
    }
  }
  if (current.length > 0) hunks.push(current.join("\n"));
  return hunks;
}

/**
 * Build a tag-safe id suffix from an arbitrary filename. UI node ids
 * have to be unique within a tree; deriving them from the filename is
 * stable across re-renders, so focus / scroll state survives. We
 * collapse any non-word character to `-` so the result is safe to use
 * as part of a `prcomp-detail-file-…` id.
 *
 * @param {string} filename
 */
export function fileIdSlug(filename) {
  return filename.replace(/[^a-zA-Z0-9]+/g, "-");
}

/**
 * Filter raw GitHub comment list down to top-level conversation (no
 * inline review comments, no thread replies).
 *
 *   * `path` is set on review-thread comments (inline file comments).
 *   * `inReplyToId` is set on replies within a review thread.
 *
 * The github.js `listPullComments` already hits
 * `/issues/{n}/comments` which only returns top-level conversation,
 * so both fields are typically null — but we filter defensively in
 * case a future caller swaps in `/pulls/{n}/comments` (review-tab
 * work) and so Phase 4's inline-comment work cannot accidentally leak
 * into this view.
 *
 * @template {{ path?: string | null, inReplyToId?: number | null }} T
 * @param {T[]} comments
 * @returns {T[]}
 */
export function filterTopLevelComments(comments) {
  return comments.filter(
    (c) =>
      (c.path === null || c.path === undefined) &&
      (c.inReplyToId === null || c.inReplyToId === undefined),
  );
}

/**
 * Conservative "X minutes ago" formatter. Avoids pulling Intl /
 * date-fns into the plugin runtime; the design doc treats relative
 * times as decorative captions and the spec didn't ask for perfect
 * locale handling.
 *
 * Edge cases:
 *   * Future-dated input (clock skew) → "just now". Negative relative
 *     times are misleading.
 *   * Unparseable input → returned verbatim. The caller usually has
 *     a fallback in mind ("show the raw timestamp").
 *
 * @param {string} iso
 * @param {number} [nowMs] — injectable for tests
 */
export function formatRelative(iso, nowMs = Date.now()) {
  if (typeof iso !== "string" || iso.length === 0) return "";
  const then = Date.parse(iso);
  if (!Number.isFinite(then)) return iso;
  const deltaMs = nowMs - then;
  if (deltaMs < 0) return "just now";
  const seconds = Math.floor(deltaMs / 1000);
  if (seconds < 60) return "just now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  const months = Math.floor(days / 30);
  if (months < 12) return `${months}mo ago`;
  const years = Math.floor(days / 365);
  return `${years}y ago`;
}
