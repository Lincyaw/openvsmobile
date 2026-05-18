# PR Companion — Design

A flagship plugin for the mobile code workbench. Lets the user triage
review-requests, read PR diffs, and post review actions (approve / request
changes / comment) from the phone. Designed to be the canonical
demonstration of §4.3 widget vocabulary in a real use case.

Status: design draft, awaiting sign-off before dispatching workers.

## Why this plugin

The product brief is "phone-side code workbench" — read + observe +
companion, not desktop replacement. PR review fits that exactly:

- **Real mobile use case.** Triage review-requests during the commute,
  approve quick PRs at lunch, jump in to a teammate's review without
  opening a laptop. Complements desktop review; doesn't try to replace it.
- **Vocabulary exercise.** Hits ~all of §4.3 in one plugin: `tabBar`,
  `list`, `swipeAction`, `markdown`, `codeBlock`, `section`, `card`,
  `avatar`, `badge`, `actionSheet`, `bottomSheet`, `spinner`, `banner`,
  `progress`. Anything that turns out to be unusable here is feedback
  that vocabulary needs sharpening.
- **Honors non-goals.** Read + comment + approve + close. No inline file
  edits, no merge button — those stay in `gh pr checkout` / `gh pr merge`
  on a real terminal (first principle #6).

## Scope

**In v0**
- Inbox panel with three filtered lists: Review-requested / Mentioned /
  Assigned. Backed by GitHub Notifications API.
- PR detail panel: title + author + status; tabbed Conversation / Files /
  Checks; tap a file → diff (read-only); tap a comment → reply.
- Review actions: Approve, Request changes, Comment review.
- Top-level PR comments + reply to existing comments.
- Mark notification as read (swipe) / re-show (undo toast).
- Notification push when a new review request or @mention arrives.

**Explicitly NOT in v0**
- Inline file-level review comments. (Read-only diff is enough; tapping
  a line opens a reply to the *thread* on that line if one exists, but
  starting a new line-anchored thread is deferred.)
- Reactions (`👍`, `🚀`).
- Merge / close / reopen / re-request review. Destructive or workflow-
  altering → terminal-only.
- Draft PR management.
- Repo browse / search across PRs. (Inbox is the entry point.)
- File full-text view. Tapping "view raw" deep-links to github.com.
- Multiple accounts. `gh auth token` returns one identity; that's it.

## Workspace model

PRs are per-repo, so the plugin must respect the user's active workspace
context — otherwise opening "PRs" inside workspace `cool-app` and seeing
PRs for unrelated repos is just noise.

**Default behavior**: scope the inbox to the GitHub repo of the active
workspace. **Optional toggle**: "All repos" mode for cross-repo triage.
Toggle state persists per-workspace-id.

**Repo detection**: spawn `git -C <workspace.root> remote get-url origin`,
then parse against `github\.com[:/](.+?)/(.+?)(?:\.git)?$` (covers SSH
+ HTTPS forms). If the workspace has no git remote, or its remote isn't
GitHub (e.g. gitlab.com), we fall back to All-repos mode and surface a
`ui.banner style=info` like *"Workspace 'foo' isn't a GitHub repo —
showing all your PRs"*. No fatal error; the inbox keeps working.

**No active workspace** (user closed all): All-repos mode; no toggle
persisted.

**Workspace switch handling**: subscribe to the SDK's
`onWorkspaceActivated` callback (see Phase 0 below). On switch:
re-detect repo, re-render the inbox tab body, re-prime the polling
loop with the new scope. Don't dispose `prDetails` LRU cache — a PR
the user just had open might be in a different repo from the new
workspace, and they may pop back.

**Notification fan-out** (the 5-min background poll) stays globally
scoped regardless of toggle — review-requests for *any* repo the user
participates in still surface as system notifications. The scope toggle
only filters the in-app inbox view.

## SDK prerequisite (Phase 0)

PR Companion needs two things the SDK doesn't expose yet:

```ts
interface WorkspaceRef {
  id: string;     // UUID, stable across reconnect
  root: string;   // absolute path
  label: string;  // user-visible name
}

interface PluginContext {
  // Returns the currently-active workspace, or null if none. Plugins
  // call this on activation and after onWorkspaceActivated fires.
  currentWorkspace(): Promise<WorkspaceRef | null>;
}

interface PluginConfig {
  // Fired when the user activates a different workspace (including
  // closing all → null). Not fired on plugin startup; use
  // currentWorkspace() for that initial read.
  onWorkspaceActivated?(
    ctx: PluginContext,
    workspace: WorkspaceRef | null,
  ): void | Promise<void>;
}
```

Host side: the workspace selector already lives in
`next/backend/src/workspace.ts` and `workspace.activate` is a known RPC.
The plugin host (`next/backend/src/plugins/host.ts`) subscribes to the
workspace-changed signal and fans out a new `workspace.activated`
notification to plugin processes that have an `onWorkspaceActivated`
handler.

**This is shipped as its own PR, ahead of PR Companion Phase 1.** It's
platform investment that pays back across every repo-aware plugin
(CI watcher, issue tracker, server dashboard), not just this one.
Reviewing it standalone keeps the surface area small.

The remainder of this doc assumes those APIs exist.

## Capabilities (`plugin.json`)

```json
{
  "id": "pr-companion",
  "name": "PR Companion",
  "version": "0.1.0",
  "entry": { "kind": "node", "path": "index.js" },
  "activation": ["onStartup"],
  "capabilities": {
    "ui": true,
    "network": true,
    "fs": "readwrite"
  },
  "contributes": {
    "panels": [{ "id": "inbox", "title": "PRs" }]
  }
}
```

- `network: true` — calls GitHub REST + GraphQL. Honest declaration even
  though the host gate is on `network.*` RPC (which we don't use); we
  fetch directly via `fetch()`.
- `fs: readwrite` — persists dismissed-notification ids and last-seen
  Notifications API `Last-Modified` to `~/.openvsmobile/pr-companion/
  state.json`. Same convention as the notes example.
- `terminal: false` — we shell out to `gh auth token` once via
  `node:child_process` to fetch the token; that's not a `terminal.*`
  host RPC, it's a child process inside the plugin's own runtime.
- `secrets: false` — we never persist the token; we re-read it from
  `gh auth token` on each plugin start.

## Auth model

The user is assumed to have `gh` installed and authed on the host where
the backend runs (the same host that already has `claude`, `git`, etc.).
On activation:

1. `child_process.execFile("gh", ["auth", "token"])` → token string.
2. Token held in memory only, never written to disk.
3. If `gh` is missing or unauthed → render an error panel with a
   `UiCodeBlock` showing the exact `gh auth login` command to run, and a
   "Retry" button. No in-app login flow; auth lives in the terminal.

Re-reading the token on every activation means rotation just works.
Token-scope check is GitHub's job — if a call returns 401 we surface
the same error banner.

## Data model & caching

In-memory only, rebuilt on activation:

- `notifications: Map<id, NotificationRow>` — subset of GitHub
  notifications filtered to `pull_request` subject type.
- `prDetails: Map<"owner/repo#number", PrDetail>` — fetched lazily when
  the user opens the PR detail panel; LRU-capped at 20 entries so we
  don't grow unbounded.

Persisted to `~/.openvsmobile/pr-companion/state.json`:

- `dismissedIds: string[]` — notification ids the user swiped away;
  ignored on re-fetch until GitHub clears them (`Last-Modified` change).
- `lastSeenAt: string` (ISO) — for the badge "X new since you last
  opened the panel".
- `scopeByWorkspace: Record<workspaceId, "thisRepo" | "allRepos">` —
  per-workspace toggle state. Default is `"thisRepo"` when the
  workspace maps to a GitHub repo, otherwise `"allRepos"`.

## Refresh / polling strategy

GitHub isn't a push source, so the plugin polls. Per first principle #1
("backend is source of truth") we can't make the polling magically go
away, but we keep it as cheap and semantic as possible:

- Foreground inbox: poll `GET /notifications?participating=true` every
  60 s using the `If-Modified-Since` header from the last response.
  `304` is free; only `200` triggers a re-render.
- PR detail panel: re-fetch on open, then every 30 s while the user is
  reading it. Use ETag conditional GET.
- No global background poll — when the plugin's panels aren't active,
  we still poll every 5 min to drive notification fan-out (see below).
  This is the one place we accept a "wasted" tick; it's the price of
  catching review-requests when the app isn't open.

Rate-limit awareness: respect `X-RateLimit-Remaining`; back off to 5 min
when under 100 remaining; show a `UiBanner` with "rate-limited; retry at
HH:MM" when 0.

## Panel structure

### Inbox panel (`panels.inbox`)

```
ui.column gap=md
├── ui.row  (scope chip row)
│     ├── ui.badge variant=neutral text="owner/repo" | "All repos"
│     └── ui.button style=secondary label="Switch scope…"
│           onTapEvent=open-scope-sheet
│           (UiActionSheet with "Just this repo" / "All repos";
│            "Just this repo" hidden when current workspace ≠ GH repo)
├── ui.tabBar  activeId=…  onChangeEvent=tab-changed
│     [ "Review", "Mentioned", "Assigned" ]
├── ui.banner  (only if auth/rate-limit/offline/non-GH-workspace)
└── ui.list  variant=insetGrouped
      └── ui.swipeAction  trailing=[Mark read]  onTrailingEvent=dismiss
            └── ui.row gap=sm
                  ├── ui.avatar src=author.avatar_url size=sm
                  └── ui.column gap=xs flex
                        ├── ui.text style=body  "owner/repo #N — PR title"
                        ├── ui.row gap=xs
                        │     ├── ui.badge variant=status text=open|closed|merged
                        │     ├── ui.badge variant=count text="+12 −3"
                        │     └── ui.text style=caption "updated 2h ago"
                        └── ui.text style=caption  "review-requested by @bob"
```

Tap a row → push PR detail panel.

Empty list → `UiSection` with a friendly "No PRs need your attention"
caption + the last-refreshed timestamp.

### PR detail panel (`panels.pr-<owner>-<repo>-<n>`)

Detail panels are dynamically registered on first open and torn down
when the user pops back to Inbox, to keep the panel list short.

```
ui.column gap=md
├── ui.section variant=card  (header)
│     ├── ui.row gap=sm
│     │     ├── ui.avatar src=author.avatar_url
│     │     ├── ui.column gap=xs
│     │     │     ├── ui.text style=heading  "PR title"
│     │     │     └── ui.text style=caption  "owner/repo · #N · by @author"
│     │     └── ui.badge variant=status  open|draft|closed|merged
│     └── ui.row gap=sm  (review button row)
│           └── ui.button style=primary label="Review…"  onTapEvent=open-review-sheet
│
├── ui.tabBar activeId=…
│     [ "Conversation", "Files", "Checks" ]
│
└── ui.section  (active tab body — switched in plugin code)
```

**Conversation tab body:**

```
ui.list
├── ui.section variant=card  (PR body)
│     └── ui.markdown source=pr.body  baseUrl=github.com/owner/repo
└── for each timeline item:
    ui.section variant=card
      ├── ui.row gap=sm  (avatar + author + relative time)
      └── ui.markdown  (comment body)
                       (or `ui.text style=caption` for state-change events
                        like "merged", "requested-review-from @alice")
ui.bottomSheet trigger:  ui.button  "Comment"  onTapEvent=open-comment-sheet
```

**Files tab body:**

```
ui.list
└── ui.swipeAction trailing=[Comment]  (opens reply sheet for that file)
      ui.row
        ├── ui.icon src=feather:file-text
        ├── ui.text style=mono  "path/to/file.ts"
        └── ui.text style=caption color=success  "+42 −5"
```

Tap a file → push a sub-screen `ui.column` with `ui.codeBlock` per hunk,
language inferred from extension. Hunks are static; no inline comment
controls in v0.

**Checks tab body:**

```
ui.column
├── ui.progress variant=linear  value=passing/total  (only if running)
└── ui.list
    └── for each check_run:
        ui.row gap=sm
          ├── ui.icon  feather:check-circle | x-circle | clock | alert-circle
          ├── ui.text  "check name"
          └── ui.text style=caption  "duration · conclusion"
        (tap → ui.bottomSheet with ui.codeBlock of last 200 log lines
                 fetched on demand, with "View full on GitHub" link)
```

## Imperative modals

- **Review sheet** (triggered by Review button):
  `ui.showActionSheet` with three actions
  `[ "Approve", "Request changes", "Comment only" ]`. Picking an option
  opens a follow-up `ui.showBottomSheet` containing
  `ui.textField multiline rows=6 placeholder="Optional summary…"` +
  `ui.button "Submit"`. Submit → `POST /repos/.../pulls/N/reviews`.

- **Comment sheet** (triggered by "Comment" button on Conversation):
  `ui.showBottomSheet` with multi-line text field + Submit.

- **Dismiss confirmation**: none. Swipe is destructive but undoable via a
  3-second `notification.show` with an "Undo" action that re-inserts the
  id.

## Push notifications

Plugin uses `notification.show` (existing core surface) whenever the 5-min
background poll surfaces a notification id we haven't shown before:

```
{ title: "Review requested",
  body:  "owner/repo #N — PR title",
  tag:   `pr-companion:${notificationId}`,
  onTapPanelId: "inbox" }
```

Tag-based dedup; tapping deep-links to the inbox panel. (Deep-linking to
the specific PR detail panel would be nicer but requires a `panelId`
that doesn't exist until open — leave as v1 improvement.)

## Error states

| Condition | Render |
|---|---|
| `gh` not installed | `ui.banner` style=danger + `ui.codeBlock` "brew install gh / apt install gh" |
| `gh auth token` exits non-zero | `ui.banner` style=danger + `ui.codeBlock` "gh auth login" + Retry button |
| 401 from GitHub | Same as above — token revoked |
| Offline (`fetch` rejected) | `ui.banner` style=info "Offline. Showing cached data." + dim list |
| 403 rate-limited | `ui.banner` style=warning "Rate-limited until HH:MM" |
| 5xx | Inline `ui.text style=caption color=danger` on the affected row only; rest of the UI keeps working |

## File layout

```
next/examples/plugins/pr-companion/
├── plugin.json         # manifest above
├── README.md           # what it does, how to install, scope
├── index.js            # SDK entry, panel registration, event router
├── github.js           # fetch wrappers, ETag bookkeeping, types JSDoc
├── auth.js             # gh auth token resolver
├── render/
│   ├── inbox.js        # buildInboxPanel(state) → ui tree
│   ├── prDetail.js     # buildPrDetailPanel(state, pr) → ui tree
│   ├── filesTab.js
│   ├── conversationTab.js
│   └── checksTab.js
└── state.js            # load/save dismissed ids + lastSeenAt
```

One file per panel-builder keeps the trees readable; render functions
are pure (`(state) → uiTree`) so they're testable without a host.

## Implementation phases

Worker-friendly slices. Each ends in a runnable plugin a user could
install; each closes a clean review boundary.

**Phase 0 — SDK workspace API** (separate PR, lands first). See above.

**Phase 1 — Skeleton + Auth + Workspace detection.** plugin.json, SDK
entry, `gh auth token` resolver, error banner when missing. Wires
`onWorkspaceActivated` → re-detect repo. Inbox panel renders
"Hello, @user — workspace: owner/repo" or "(no GH repo)". No GitHub
calls yet beyond `/user`.

**Phase 2 — Inbox.** GitHub Notifications fetch with ETag, three-tab
filter (review-requested / mentioned / assigned), scope chip + switcher
sheet, swipe-to-dismiss with undo, persistence of dismissed ids and
per-workspace scope toggle.

**Phase 3 — PR detail (read).** Tap a row → PR detail panel with
Conversation + Files tabs, both read-only. Diff viewing via tap on file.

**Phase 4 — Review actions.** Review bottom sheet, Approve / Request
changes / Comment, top-level Comment, reply-to-thread.

**Phase 5 — Checks + background notifications.** Checks tab, 5-min
background poll with `notification.show` fan-out.

Each phase is a separate dev-worker dispatch; each gets a code-review
pass before the next starts.

## Resolved design choices

1. **Notifications API, not Search.** Notifications API is cheap
   (`If-Modified-Since` → `304 Not Modified`), naturally scopes to
   what the user actively participates in, and dovetails with the
   "mark as read" gesture. GraphQL Search (`is:pr review-requested:@me`)
   is broader but eats rate-limit fast and adds latency we don't want
   on a 60-second poll. Revisit only if the "Assigned" tab is
   demonstrably starved.
2. **Single fixed PR-detail panel + in-plugin navigation.** The plugin
   contributes one `panels.detail` entry, and which PR it shows is
   internal plugin state. Pro: panel ids are stable across reconnect;
   simpler `panels:` manifest; tighter UI list. Con: notification deep-
   links can only target the panel id, not a specific PR — we accept
   this and have the plugin pre-load the corresponding PR when the
   user follows a notification, by stashing "next PR to focus" in
   memory before pushing.
3. **Hunk language inference: reuse Files-tab map if exported, else a
   ~10-extension hardcoded fallback.** Files-tab map lives in
   `next/app/lib/ui/highlight_theme.dart` (filename → language) — that
   one is app-side. For plugin-side language hint, ship a small JS
   object covering js/ts/dart/py/go/rs/java/kt/swift/sh/md plus a
   `null` fallback. Centralizing the map across app + plugin is v1
   work, not blocking.
