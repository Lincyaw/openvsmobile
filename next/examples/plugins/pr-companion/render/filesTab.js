// PR Companion — Files tab body (Phase 3).
//
// Two display modes, switched by `openFile`:
//
//   * `openFile === null`  → render the file list. Each row is a
//     ListTile with `onTapEvent = detail-file-tapped:<idx>`. We
//     intentionally do NOT use `swipeActions` here — the design doc
//     reserves the "Comment" swipe for Phase 4 (inline file comments).
//   * `openFile !== null`  → render a sub-view: a "← Back to files"
//     button followed by the file's diff as one CodeBlock per hunk.
//
// Hunk language inference is a tiny extension → highlight.js language
// map (per resolved design choice #3); see `./_pure.js`.
//
// Binary / very-large files: GitHub returns `patch: null`. We render a
// caption pointing the user at github.com instead of trying to be
// clever. The htmlUrl is not on PullFile (see github.js typedef); the
// user knows where their PR lives, so a generic caption is enough.

import { ui } from "@openvsmobile/sdk";

import { inferLanguage, splitHunks, fileIdSlug } from "./_pure.js";

// Re-export so callers (and tests) can import either from here or
// directly from _pure.js without caring where it lives.
export { inferLanguage, splitHunks };

/**
 * Build the file-list view (no file open).
 *
 * @param {Array<{ filename: string, additions: number, deletions: number }>} files
 */
function buildFileList(files) {
  if (files.length === 0) {
    return ui.section({
      id: "prcomp-detail-files-empty",
      children: [
        ui.text({
          id: "prcomp-detail-files-empty-text",
          text: "(no files in this PR)",
          style: "caption",
        }),
      ],
    });
  }
  return ui.list({
    id: "prcomp-detail-files-list",
    items: files.map((f, idx) =>
      ui.listTile({
        id: `prcomp-detail-file-${idx}-${fileIdSlug(f.filename)}`,
        title: f.filename,
        subtitle: `+${f.additions} -${f.deletions}`,
        leading: ui.icon({
          id: `prcomp-detail-file-${idx}-icon`,
          name: "file-text",
        }),
        onTapEvent: `detail-file-tapped:${idx}`,
      }),
    ),
  });
}

/**
 * Build the diff sub-view for an opened file.
 *
 * `file` may be `undefined` if the cached `openFile` name no longer
 * matches any file in `files` (rare — a refetch dropped/renamed the
 * file mid-session). We surface a caption + Back button rather than
 * leaving the panel blank.
 *
 * @param {{ filename: string, additions: number, deletions: number, patch: string | null } | undefined} file
 */
function buildFileDiffView(file) {
  /** @type {import("@openvsmobile/sdk").UiNode[]} */
  const children = [
    ui.row({
      id: "prcomp-detail-file-back-row",
      gap: "sm",
      children: [
        ui.button({
          id: "prcomp-detail-file-back-btn",
          label: "← Back to files",
          style: "secondary",
        }),
      ],
    }),
  ];
  if (file === undefined) {
    children.push(
      ui.text({
        id: "prcomp-detail-file-missing",
        text: "This file is no longer part of the PR.",
        style: "caption",
      }),
    );
    return ui.column({
      id: "prcomp-detail-file-diff",
      gap: "md",
      children,
    });
  }
  children.push(
    ui.text({
      id: "prcomp-detail-file-header",
      text: file.filename,
      style: "mono",
    }),
    ui.text({
      id: "prcomp-detail-file-stats",
      text: `+${file.additions} -${file.deletions}`,
      style: "caption",
    }),
  );
  if (file.patch === null) {
    // Binaries and very-large patches. GitHub elides `patch` for files
    // over its size threshold (typically 1MB or >3000 lines); the user
    // can fall back to github.com for the full diff.
    children.push(
      ui.text({
        id: "prcomp-detail-file-no-patch",
        text: "Patch too large to render; open on GitHub.",
        style: "caption",
      }),
    );
  } else {
    const lang = inferLanguage(file.filename);
    const hunks = splitHunks(file.patch);
    const slug = fileIdSlug(file.filename);
    hunks.forEach((hunk, idx) => {
      children.push(
        ui.codeBlock({
          id: `prcomp-detail-file-${slug}-hunk-${idx}`,
          code: hunk,
          // `language` is optional; omit when we can't infer to let the
          // renderer fall through to plain monospace rather than
          // guessing wrong.
          ...(lang !== null ? { language: lang } : {}),
        }),
      );
    });
    if (hunks.length === 0) {
      // Theoretically unreachable (splitHunks returns [] only on null/
      // empty input, both covered above) but cheap belt-and-braces.
      children.push(
        ui.text({
          id: "prcomp-detail-file-empty-patch",
          text: "(empty patch)",
          style: "caption",
        }),
      );
    }
  }
  return ui.column({
    id: "prcomp-detail-file-diff",
    gap: "md",
    children,
  });
}

/**
 * Build the Files tab body. Pure function — no side effects, no
 * fetching. Caller drives the `openFile` state.
 *
 * @param {{
 *   files: Array<{ filename: string, additions: number, deletions: number, patch: string | null }> | null,
 *   openFile: string | null,
 *   error?: { kind: string } | null,
 * }} params
 */
export function buildFilesTabBody({ files, openFile, error }) {
  if (files === null) {
    // Files fetch failed for this PR while pr / comments succeeded.
    // The other tabs still work; this one degrades gracefully into a
    // caption so the panel isn't half-empty.
    const msg =
      error !== null && error !== undefined
        ? `Failed to load files (${error.kind}).`
        : "Failed to load files.";
    return ui.section({
      id: "prcomp-detail-files-error",
      children: [
        ui.text({
          id: "prcomp-detail-files-error-text",
          text: msg,
          style: "caption",
        }),
      ],
    });
  }
  if (openFile === null) {
    return buildFileList(files);
  }
  const file = files.find((f) => f.filename === openFile);
  return buildFileDiffView(file);
}
