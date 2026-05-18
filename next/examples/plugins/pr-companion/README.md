# PR Companion

A mobile companion for triaging GitHub pull-request review-requests,
reading PR diffs, and posting review actions from the phone. Complements
desktop review; intentionally does not try to replace it.

Full design: [`docs/design/plugins/pr-companion.md`](../../../../docs/design/plugins/pr-companion.md).

## Install

```sh
cp -r next/examples/plugins/pr-companion ~/.local/share/openvsmobile-next/plugins/
```

Plugins are discovered by directory drop per CLAUDE.md ("Plugin install
is filesystem-only").

## Requirements

- The [`gh`](https://cli.github.com/) CLI must be installed on the host
  running the openvsmobile backend.
- You must already be signed in: `gh auth login`.

The plugin shells out to `gh auth token` on every activation; the token
is held in memory only and is re-resolved on each plugin start (which is
the rotation story — run `gh auth refresh` and the next activation
picks up the new token).

## Capabilities declared

- `ui: true` — renders the inbox + PR detail panels.
- `network: true` — calls `api.github.com` directly via `fetch()` (not
  via a host `network.*` RPC; the manifest declares the intent honestly).
- `fs: readwrite` — Phase 2+ will persist dismissed-notification ids and
  per-workspace scope toggle state under `~/.openvsmobile/pr-companion/`.

Capabilities `terminal` and `secrets` are explicitly absent: we never
shell out to a `terminal.*` RPC (the `gh auth token` invocation is a
plain `node:child_process` call inside our own process), and we never
persist the token.

## Scope (Phases 1 + 2 + 3 + 4 + 5 + 6 — shipped)

Phase 1 — plugin shell:

- Two panels are registered (`inbox`, `detail`).
- `gh auth token` is resolved on every activation; the inbox banner
  reflects auth state (`missing` / `unauthed` / `tokenInvalid` /
  `offline` / `ok`).
- The active workspace is detected (`git remote get-url origin` → SSH
  or HTTPS GitHub remote parser) and the inbox greeting reflects
  `owner/repo`, `not a GitHub repo`, or `no workspace active`.
- A single `GET /user` call surfaces the authenticated login.

Phase 2 — Inbox:

- `GET /notifications?participating=true` polled every 60 s with
  `If-None-Match` / `If-Modified-Since` so 304s stay free.
- Three-tab filter (Review-requested / Mentioned / Assigned) over the
  notification list, plus a scope chip ("this repo" vs "all repos")
  with a switcher action sheet. The "this repo" option is hidden when
  the active workspace has no parseable GitHub remote; in that case
  the banner explains the All-repos fallback.
- Swipe-to-dismiss persists dismissed notification ids to
  `~/.openvsmobile/pr-companion/state.json`; the per-workspace scope
  toggle is persisted alongside, keyed by the workspace UUID.
- Tapping a row stages the PR ref and re-renders the Detail panel.

Phase 3 — read-only PR detail panel:

- Three-tab structure (Conversation / Files / Checks). Conversation
  renders the PR body + top-level comments as Markdown cards; Files
  renders one row per changed file with `+adds -dels` and a tap-to-open
  diff sub-view (one `ui.codeBlock` per hunk, language inferred from a
  small extension map per resolved design choice #3); Checks is a
  placeholder for Phase 5.
- In-memory LRU cache (20 entries) keyed by `owner/repo#number`. Stale-
  while-revalidate: cached data renders instantly, a background refetch
  re-renders on success.
- 30s ETag polling while a PR is open; the timer is stopped when the PR
  is closed or the plugin shuts down. Polling uses github.js's existing
  10s per-request timeout — no separate abort plumbing here.
- Partial-failure rendering: if any of `getPull` / `listPullFiles` /
  `listPullComments` fails, the other tabs still render; the failing
  tab degrades to a caption. A full-stack failure surfaces as a single
  banner (`unauthed` / `offline` / `rateLimited` / `serverError`).

Phase 4 — review actions:

- "Review…" button on the PR detail header opens an action sheet with
  Approve / Request changes / Comment only. Picking an option opens a
  bottom sheet with a textfield (body) + Submit button; submitting
  POSTs `/repos/{o}/{r}/pulls/{n}/reviews` via the matching
  `event: APPROVE | REQUEST_CHANGES | COMMENT`.
- "Comment" button at the bottom of the Conversation tab opens the
  same bottom-sheet shape and POSTs `/issues/{n}/comments` (the
  top-level PR-comment endpoint).
- Tapping (or swiping → "Reply") an existing comment in the
  Conversation tab opens the same sheet pre-filled with a GitHub-
  flavored quote block (`> @author wrote:\n> <first line>\n\n`) and
  POSTs `/pulls/{n}/comments/{commentId}/replies` on submit.
- On a successful POST the detail panel re-fetches so the new
  review / comment shows up in Conversation. On failure a danger
  banner appears above the header naming the failing action and the
  github.js error kind.
- Pending state: a module-level `reviewSubmitPending` flag swallows
  double-tap on Submit during a slow POST. The bottom sheet stays
  open after success (the SDK does not yet expose plugin-driven
  dismissal — tracked as `TODO(v1)` in `@openvsmobile/sdk`); the user
  taps outside to close, and the next tap on Review / Comment opens a
  fresh sheet with a cleared body.

Phase 5 (partial) — Checks tab:

- The Checks tab renders one row per `check_run` for the PR's
  `head_sha`, with an icon + accent driven by `status` / `conclusion`
  (success → check-circle, failure / timed-out / action-required →
  x-circle, neutral / cancelled / skipped → minus-circle, in-progress /
  queued / pending → clock, anything else → alert-circle). When at
  least one run is still in flight, a linear `ui.progress` widget at
  the top of the tab shows the passing-out-of-total ratio.
- Caption per row is `"<duration> · <conclusion>"` (e.g. `"2m 34s ·
  success"`); in-flight runs show `"running 1m 12s"` against
  wall-clock. Duration formatting lives in `_pure.js#formatDuration`.
- The check-runs fetch is the fourth leg of the detail panel's
  `fetchAndRender`, gated on the PR's `head_sha`: cached PRs fire it in
  parallel with the other three, fresh PRs fall back to a sequential
  second stage (one extra round-trip on first paint). It piggybacks
  the existing 30-second ETag polling — no new timer.
- Tapping a check row opens a bottom sheet with the last 200 lines of
  the workflow-job log (see Phase 6 below for the consumer side).

Phase 6 — notification fan-out + per-check log sheet:

- **Background notification fan-out.** On every successful 60s inbox
  poll, genuinely-new `review_requested` / `mention` / `team_mention` /
  `assign` items fire a system toast via `ctx.showNotification`
  (Phase-6A SDK extension). Toasts carry `groupKey: "pr-companion"` so
  the OS collapses bursts, and `ttl: 3600` so stale ones expire from
  the host's notification store. Cold-start no-spam: on the very first
  poll after activation (i.e. `shownNotifIds` empty on disk) the
  plugin pre-populates the persisted shown-set with the entire
  current inbox without firing — subsequent polls then only fan out
  ids that are genuinely new since startup.
- **Persistence of shown ids.** `state.json` gains a `shownNotifIds`
  array soft-capped at 500 entries (FIFO eviction). The eviction
  edge-case — an evicted id reappearing in the inbox could re-fire —
  is acceptable given the 1-hour toast TTL.
- **Per-check log bottom sheet.** Tapping a check row in the Checks
  tab fetches the last 200 lines of the job log via
  `github.js#getCheckRunLog` (Phase-6B) and opens a bottom sheet with
  a `ui.codeBlock` (language=bash). Error envelopes map to inline
  banners: `notFound` → "log unavailable (pruned by retention)",
  `unauthed` → "token revoked, run gh auth login", `rateLimited` →
  "rate-limited until HH:MM", `offline` → "offline", `serverError` →
  "GitHub returned HTTP <code>". Fetch-first / sheet-after pattern
  (same as Phase 4): no spinner-then-content swap, at the cost of
  ≤10s between tap and sheet (github.js's request timeout bound).

**Deferred** (not in Phase 6):

- **Deep-linking from a toast back into the plugin's inbox panel** is
  not yet wired. Requires extending `NotificationAction` in the SDK
  with an `open-plugin-panel` variant; today the union is just
  `{open-url, copy, open-workspace}`. The Phase-6 toast carries no
  `action` field — it is informational only.
- **Inline-file commenting on the Files tab** and **reactions** remain
  out of scope for v0.

See the design doc's "Implementation phases" section for the staged
plan.
