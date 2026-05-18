// PR Companion — Phase 5 Checks-tab unit tests.
//
// Picks up via the same `../examples/plugins/*/*.test.js` glob in
// next/backend/vitest.config.ts. Scope:
//   * `formatDuration` granularity edge cases (the new pure helper).
//   * `iconForStatus` / `captionForRun` exhaustive mapping table (these
//     are the entirety of the render decision-making — pinning the
//     table means visual regressions in the Checks tab become test
//     failures, not screenshot diffs).
//
// The tree-building parts of `renderChecksTab` import
// `@openvsmobile/sdk` and so cannot be exercised here without the
// plugin host; they're covered indirectly by the host's smoke tests
// in the next phase.

import { describe, it, expect } from "vitest";

// Import from _pure.js (not checksTab.js) — the latter resolves
// `@openvsmobile/sdk`, which has no node_modules entry in this example
// plugin and is provided by the host's sdk-loader at runtime only.
import { formatDuration, iconForStatus, captionForRun } from "./render/_pure.js";

describe("formatDuration", () => {
  it("renders sub-minute spans in seconds", () => {
    expect(formatDuration(0, 0)).toBe("0s");
    expect(formatDuration(0, 45_000)).toBe("45s");
    expect(formatDuration(0, 59_999)).toBe("59s");
  });

  it("renders sub-hour spans as Xm Ys, dropping zero seconds", () => {
    expect(formatDuration(0, 60_000)).toBe("1m");
    expect(formatDuration(0, 154_000)).toBe("2m 34s");
    expect(formatDuration(0, 300_000)).toBe("5m");
  });

  it("renders ≥1h spans as Xh Ym, dropping zero minutes", () => {
    expect(formatDuration(0, 3_600_000)).toBe("1h");
    expect(formatDuration(0, 4_320_000)).toBe("1h 12m");
    expect(formatDuration(0, 10_800_000)).toBe("3h");
  });

  it("returns '' for invalid input (clock skew, NaN)", () => {
    expect(formatDuration(1000, 500)).toBe("");
    expect(formatDuration(NaN, 1000)).toBe("");
    expect(formatDuration(1000, NaN)).toBe("");
    expect(formatDuration(Infinity, 0)).toBe("");
  });
});

describe("iconForStatus", () => {
  it("maps completed/success → check-circle success", () => {
    expect(iconForStatus({ status: "completed", conclusion: "success" })).toEqual({
      name: "check-circle",
      accent: "success",
    });
  });

  it("maps completed/failure-like → x-circle danger", () => {
    for (const conclusion of ["failure", "timed_out", "action_required"]) {
      expect(iconForStatus({ status: "completed", conclusion })).toEqual({
        name: "x-circle",
        accent: "danger",
      });
    }
  });

  it("maps completed/neutral-like → minus-circle muted", () => {
    for (const conclusion of ["neutral", "cancelled", "skipped"]) {
      expect(iconForStatus({ status: "completed", conclusion })).toEqual({
        name: "minus-circle",
        accent: "muted",
      });
    }
  });

  it("maps in-flight states → clock info", () => {
    for (const status of ["in_progress", "queued", "pending"]) {
      expect(iconForStatus({ status, conclusion: null })).toEqual({
        name: "clock",
        accent: "info",
      });
    }
  });

  it("falls back to alert-circle warning for unknown shapes", () => {
    expect(iconForStatus({ status: "completed", conclusion: null })).toEqual({
      name: "alert-circle",
      accent: "warning",
    });
    expect(iconForStatus({ status: "completed", conclusion: "stale" })).toEqual({
      name: "alert-circle",
      accent: "warning",
    });
    expect(iconForStatus({ status: "weird", conclusion: null })).toEqual({
      name: "alert-circle",
      accent: "warning",
    });
  });
});

describe("captionForRun", () => {
  it("renders 'duration · conclusion' for a finished run", () => {
    const caption = captionForRun({
      status: "completed",
      conclusion: "success",
      startedAt: "2026-01-01T00:00:00Z",
      completedAt: "2026-01-01T00:02:34Z",
    });
    expect(caption).toBe("2m 34s · success");
  });

  it("renders 'running Xs' when only startedAt is present", () => {
    // captionForRun takes an injectable `nowMs` so we don't have to
    // monkey-patch Date.now in tests.
    const startMs = Date.parse("2026-01-01T00:00:00Z");
    const nowMs = startMs + 90_000; // 1m 30s later
    const caption = captionForRun(
      {
        status: "in_progress",
        conclusion: null,
        startedAt: "2026-01-01T00:00:00Z",
        completedAt: null,
      },
      nowMs,
    );
    expect(caption).toBe("running 1m 30s");
  });

  it("omits duration when neither timestamp is present", () => {
    expect(
      captionForRun({
        status: "queued",
        conclusion: null,
        startedAt: null,
        completedAt: null,
      }),
    ).toBe("");
  });

  it("includes conclusion alone when no timestamps", () => {
    expect(
      captionForRun({
        status: "completed",
        conclusion: "failure",
        startedAt: null,
        completedAt: null,
      }),
    ).toBe("failure");
  });
});
