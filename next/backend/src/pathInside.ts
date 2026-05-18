// Single source of truth for "is `target` inside the directory `root`?"
//
// Used by:
//   * `ActiveWorkspace.assertContains` (workspace.ts) — `fs.*` RPC
//     isolation; called after `fs.realpath` so symlinks can't escape.
//   * `validateFileUrlsAgainstWorkspace` (plugins/ui.ts) — Batch-3
//     `file://` URL gate; also realpath-resolves before calling here.
//
// Both call sites use the same separator-guard convention so a partial
// prefix like `/srv/work` cannot falsely match `/srv/workroot`. Keeping
// the comparison in one helper prevents the two from drifting and the
// security boundary degrading silently.

import { sep } from "node:path";

/// `true` when `target` is the directory `root` itself OR strictly
/// inside it. Both arguments must already be normalized (and ideally
/// realpath-resolved) — this helper performs no lexical normalization
/// of its own; callers that pass un-resolved paths get whatever string
/// comparison their inputs deserve.
export function pathIsInside(target: string, root: string): boolean {
  if (target === root) return true;
  // Trailing-separator guard prevents `/srv/work` matching `/srv/workroot`.
  const rootWithSep = root.endsWith(sep) ? root : root + sep;
  return target.startsWith(rootWithSep);
}
