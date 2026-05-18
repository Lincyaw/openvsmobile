// PR Companion — Phase 6 per-check log bottom-sheet builder.
//
// Pure: takes the result of `github.js#getCheckRunLog` (plus the row
// metadata index.js already has) and returns the UiBottomSheet payload.
// The orchestration (fetching, opening the sheet, dispatching the tap)
// lives in index.js — same split as the Phase-4 review sheets.
//
// Why a separate module:
//   * Keeps index.js's `handleChecksLogEvent` short — no inline tree
//     construction.
//   * The builder is the most testable surface in this slice: every
//     branch of github.js's `getCheckRunLog` envelope maps to a distinct
//     banner, and the truncation cutoff is trivial to assert.
//   * Importing `@openvsmobile/sdk`'s `ui` builder is fine here; we don't
//     touch fs / fetch / SDK side-effects.
//
// Visual contract (design doc → "Checks tab body"):
//
//   ui.bottomSheet title="<check name>"
//     child: ui.column
//       ├── ui.text style=caption "<status + duration>"   (always)
//       ├── ui.text style=caption "(showing last 200 lines)"  (only if truncated)
//       ├── ui.codeBlock language=bash code=<last 200 lines>  (ok path)
//       └── ui.banner                                          (error paths)
//
// `notFound` (404) gets its own banner because GitHub returns 404 both
// for never-existed jobs AND for jobs whose logs have aged past the
// workflow's retention setting — see github.js#getCheckRunLog header.

import { ui } from "@openvsmobile/sdk";

import { captionForRun } from "./_pure.js";

/**
 * Soft cap on log lines surfaced in the bottom sheet. Matches the
 * design-doc spec ("ui.codeBlock of last 200 log lines fetched on
 * demand"). Exported for tests; not configurable at runtime — the limit
 * is a UX choice, not a tunable.
 */
export const LOG_TAIL_LINES = 200;

/**
 * Bottom-sheet id. Stable across renders so a re-open of the same row
 * reconciles cleanly instead of stacking sheets in the host's modal
 * queue.
 */
export const LOG_SHEET_ID = "prcomp-detail-check-log-sheet";

/**
 * Slice `log` down to its last `LOG_TAIL_LINES` lines. Returns both the
 * trimmed body and a boolean so the caller can render the "(showing
 * last 200 lines)" caption only when actually truncated. Linebreak
 * handling: split on `\n` (GitHub Actions log streams are LF-terminated
 * even on Windows runners), join with `\n`. We do not normalize CRLF —
 * the codeBlock renderer treats `\r` as a regular character, which is
 * fine for a raw-text log.
 *
 * @param {string} log
 * @returns {{ body: string, truncated: boolean }}
 */
export function tailLines(log) {
  if (typeof log !== "string" || log.length === 0) {
    return { body: "", truncated: false };
  }
  const lines = log.split("\n");
  if (lines.length <= LOG_TAIL_LINES) {
    return { body: log, truncated: false };
  }
  return {
    body: lines.slice(lines.length - LOG_TAIL_LINES).join("\n"),
    truncated: true,
  };
}

/**
 * Build the bottom-sheet UiNode for a check-row tap. `result` is the
 * envelope returned by `github.js#getCheckRunLog`; `run` is the row
 * itself (used for the title + status caption).
 *
 * @param {{
 *   run: { name: string, status: string, conclusion: string | null, startedAt: string | null, completedAt: string | null },
 *   result: { status: string, body?: string, code?: number, resetAt?: Date, error?: Error },
 * }} params
 * @returns {import("@openvsmobile/sdk").UiBottomSheet}
 */
export function buildLogSheet({ run, result }) {
  /** @type {import("@openvsmobile/sdk").UiNode[]} */
  const children = [];

  // Status caption mirrors the check-row caption so the sheet header
  // restates what the user just tapped without forcing them to re-read
  // the row. captionForRun degrades to "" for never-started runs; we
  // surface a fallback so the column never opens with an empty caption.
  const caption = captionForRun(run);
  children.push(
    ui.text({
      id: "prcomp-detail-check-log-caption",
      text: caption.length > 0 ? caption : run.status,
      style: "caption",
    }),
  );

  if (result.status === "ok") {
    const { body, truncated } = tailLines(
      typeof result.body === "string" ? result.body : "",
    );
    if (truncated) {
      children.push(
        ui.text({
          id: "prcomp-detail-check-log-truncated",
          text: `(showing last ${LOG_TAIL_LINES} lines)`,
          style: "caption",
        }),
      );
    }
    children.push(
      ui.codeBlock({
        id: "prcomp-detail-check-log-code",
        // Empty body is legal — codeBlock renders an empty frame rather
        // than vanishing. Some jobs upload a job entry but produce no
        // log output (skipped step, very-early failure). The status
        // caption above is the user's signal.
        code: body,
        // `bash` matches the design-doc spec; logs are line-based shell
        // output and bash gets us reasonable defaults from
        // flutter_highlight's grammar without pretending to know more
        // structure than we do.
        language: "bash",
      }),
    );
  } else if (result.status === "notFound") {
    children.push(
      ui.banner({
        id: "prcomp-detail-check-log-banner-notfound",
        title: "Log unavailable",
        body: "Pruned by GitHub Actions retention, or the job hasn't started yet.",
        accent: "info",
      }),
    );
  } else if (result.status === "unauthed") {
    children.push(
      ui.banner({
        id: "prcomp-detail-check-log-banner-unauthed",
        title: "GitHub token revoked",
        body: "Re-authenticate via gh auth login on the host.",
        accent: "danger",
      }),
    );
  } else if (result.status === "rateLimited") {
    const reset =
      result.resetAt instanceof Date
        ? // HH:MM in the host's local time. Matches the inbox banner's
          // existing reset-time presentation; we do not include the date
          // because the limit resets at most an hour later.
          result.resetAt.toLocaleTimeString([], {
            hour: "2-digit",
            minute: "2-digit",
          })
        : "soon";
    children.push(
      ui.banner({
        id: "prcomp-detail-check-log-banner-ratelimited",
        title: `Rate-limited until ${reset}`,
        accent: "warning",
      }),
    );
  } else if (result.status === "offline") {
    children.push(
      ui.banner({
        id: "prcomp-detail-check-log-banner-offline",
        title: "Offline",
        body: "Reconnect to load the log.",
        accent: "info",
      }),
    );
  } else if (result.status === "serverError") {
    const code = typeof result.code === "number" ? result.code : 0;
    children.push(
      ui.banner({
        id: "prcomp-detail-check-log-banner-server",
        title: `GitHub returned HTTP ${code}`,
        accent: "danger",
      }),
    );
  } else {
    // Defensive catch-all — github.js could grow a new status union
    // member faster than this file does. Surfacing as a generic danger
    // banner rather than rendering an empty sheet keeps the user
    // informed without us pretending to know what went wrong.
    children.push(
      ui.banner({
        id: "prcomp-detail-check-log-banner-unknown",
        title: "Couldn't load log",
        accent: "danger",
      }),
    );
  }

  return ui.bottomSheet({
    id: LOG_SHEET_ID,
    title: run.name,
    child: ui.column({
      id: "prcomp-detail-check-log-col",
      gap: "md",
      children,
    }),
  });
}
