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

## Scope (Phases 1 + 2 — shipped)

Phase 1 ships the plugin shell:

- Two panels are registered (`inbox`, `detail`) with placeholder
  content.
- `gh auth token` is resolved on every activation; the inbox banner
  reflects auth state (`missing` / `unauthed` / `tokenInvalid` /
  `offline` / `ok`).
- The active workspace is detected (`git remote get-url origin` → SSH
  or HTTPS GitHub remote parser) and the inbox greeting reflects
  `owner/repo`, `not a GitHub repo`, or `no workspace active`.
- A single `GET /user` call surfaces the authenticated login.

Phase 2 ships the Inbox:

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
- Tapping a row stages a PR ref for the Detail panel; the detail
  surface itself is Phase 3.

**Not yet implemented** (Phases 3–5): PR detail rendering, review
actions, checks tab, background notification fan-out. See the design
doc's "Implementation phases" section for the staged plan.
