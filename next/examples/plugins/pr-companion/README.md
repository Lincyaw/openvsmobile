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

## Scope (Phases 1 + 2 + 3 — shipped)

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

**Not yet implemented** (Phases 4 / 5): review actions, top-level
comment sheet, inline-comment threads (Phase 4); Checks tab content,
background notification fan-out (Phase 5). See the design doc's
"Implementation phases" section for the staged plan.
