// PR Companion — Checks tab body (Phase 5).
//
// Pure render module mirroring filesTab.js's shape. The Checks tab
// reads CheckRun rows fetched from
// `GET /repos/{owner}/{repo}/commits/{ref}/check-runs` (see
// github.js#listCheckRuns; the per-ref endpoint is why prDetail's
// fetchAndRender threads pr.headSha through as a second-stage fetch).
//
// Visual contract (design doc → "Checks tab body"):
//
//   ui.column
//   ├── ui.progress variant=linear value=<passing/total>
//   │     (only when at least one run is still in progress / queued)
//   └── ui.list
//       └── for each check_run: ui.row[icon · name · "duration · conclusion"]
//
// Status → icon mapping is centralized in `iconForStatus` so the test
// can exercise every branch from a tiny table. Tap on a row emits a
// `${CHECK_LOG_EVENT_PREFIX}<idx>` event that index.js's Phase-6
// dispatch picks up — see render/logSheet.js for the resulting bottom-
// sheet body. The legacy Phase-5 `detail-check-tapped:<idx>` event is
// still emitted by prDetail.js's handler-swallow path (it logs at
// debug + returns true), so the new event uses a distinct prefix to
// route around it cleanly without modifying prDetail.js.
//
// Empty / error states mirror filesTab's pattern: caption inside a
// `ui.section` so the panel never collapses to nothing.

import { ui } from "@openvsmobile/sdk";

import { iconForStatus, captionForRun } from "./_pure.js";

// Re-export so the test file (and any future caller) can import either
// from here or directly from _pure.js without caring where it lives.
export { iconForStatus, captionForRun };

/**
 * Event-id prefix fired when the user taps a check row. Index.js's
 * dispatch parses the suffix as the row index and looks up the
 * corresponding CheckRun in the prDetail cache. Exported so the
 * dispatch and this renderer share one source of truth.
 *
 * Distinct from Phase-5's `detail-check-tapped:` prefix on purpose:
 * prDetail.js's existing handler swallows that one with a debug log,
 * and we'd rather not modify prDetail.js to re-route. The two
 * prefixes coexist; only the new one is wired up today.
 */
export const CHECK_LOG_EVENT_PREFIX = "detail-check-log:";

/**
 * Whether a run is still in-flight. Used to gate the linear progress
 * bar at the top of the tab — no progress widget when everything is
 * already terminal (passing or failing).
 *
 * @param {{ status: string }} run
 */
function isRunning(run) {
  return run.status === "in_progress" || run.status === "queued" || run.status === "pending";
}

/**
 * Whether a run is a clean pass. Drives the progress-bar numerator.
 *
 * @param {{ status: string, conclusion: string | null }} run
 */
function isPassing(run) {
  return run.status === "completed" && run.conclusion === "success";
}

/**
 * Build one row for a check run. The row is tappable; the event id
 * carries the index so prDetail.js's event router can resolve back to
 * the run without us threading the full CheckRun object through the
 * tree.
 *
 * @param {{ id: number, name: string, status: string, conclusion: string | null, startedAt: string | null, completedAt: string | null }} run
 * @param {number} idx
 */
function buildRow(run, idx) {
  const { name, accent } = iconForStatus(run);
  const rowId = `prcomp-detail-check-${idx}`;
  const caption = captionForRun(run);
  return ui.listTile({
    id: rowId,
    title: run.name,
    leading: ui.icon({ id: `${rowId}-leading`, name, accent }),
    subtitle: caption.length > 0 ? caption : undefined,
    onTapEvent: `${CHECK_LOG_EVENT_PREFIX}${idx}`,
  });
}

/**
 * Build the Checks tab body. Pure function — no side effects, no
 * fetching. Caller drives `checkRuns` and `error`.
 *
 * @param {{
 *   pr: unknown,
 *   checkRuns: Array<{ id: number, name: string, status: string, conclusion: string | null, startedAt: string | null, completedAt: string | null }> | null,
 *   error?: { kind: string } | null,
 * }} params
 */
export function renderChecksTab({ pr: _pr, checkRuns, error }) {
  if (error !== null && error !== undefined) {
    // Mirror filesTab's caption pattern. The other tabs still work;
    // this one degrades to a caption rather than poisoning the panel.
    const msg = `Failed to load checks (${error.kind}).`;
    return ui.section({
      id: "prcomp-detail-checks-error",
      children: [
        ui.text({
          id: "prcomp-detail-checks-error-text",
          text: msg,
          style: "caption",
        }),
      ],
    });
  }
  if (checkRuns === null) {
    // Pre-first-fetch. Surface a quiet caption rather than a spinner —
    // the parent panel already shows a top-level loading state on the
    // very first paint; for refreshes we just want the tab to look
    // empty rather than yanking out the old data.
    return ui.section({
      id: "prcomp-detail-checks-loading",
      children: [
        ui.text({
          id: "prcomp-detail-checks-loading-text",
          text: "Loading checks…",
          style: "caption",
        }),
      ],
    });
  }
  if (checkRuns.length === 0) {
    return ui.section({
      id: "prcomp-detail-checks-empty",
      children: [
        ui.text({
          id: "prcomp-detail-checks-empty-text",
          text: "No checks configured for this PR.",
          style: "caption",
        }),
      ],
    });
  }

  /** @type {import("@openvsmobile/sdk").UiNode[]} */
  const children = [];

  const running = checkRuns.some(isRunning);
  if (running) {
    const total = checkRuns.length;
    const passing = checkRuns.filter(isPassing).length;
    // value is a unit interval [0,1] per UiProgress contract; total > 0
    // here because the empty list path returned above.
    children.push(
      ui.progress({
        id: "prcomp-detail-checks-progress",
        variant: "linear",
        value: passing / total,
        label: `${passing}/${total} passing`,
      }),
    );
  }

  children.push(
    ui.list({
      id: "prcomp-detail-checks-list",
      items: checkRuns.map((run, idx) => buildRow(run, idx)),
    }),
  );

  return ui.column({
    id: "prcomp-detail-checks",
    gap: "md",
    children,
  });
}
