# openvsmobile-next

The new (P1) implementation of the mobile code platform described in
[`docs/design/mobile-code-platform.md`](../docs/design/mobile-code-platform.md).
This subdirectory is intentionally side-by-side with the legacy
`server/` (Go) and `app/` (Flutter) trees; demolition of the legacy
artifacts is P6 and not part of this iteration.

## Layout

```
next/
├── backend/   # Node 20+ / TypeScript backend (auth + workspace + fs + terminal)
└── app/       # Flutter Android client (Files + Terminal tabs)
```

## Running the backend

Requirements: Node ≥ 20, pnpm (or npm), a C/C++ toolchain (for the
`node-pty` native build).

```bash
cd next/backend
pnpm install        # builds node-pty
pnpm run typecheck  # tsc --noEmit
pnpm run dev        # default port 7860, ws path /rpc
```

On first start the backend generates a bearer token, writes it to
`~/.config/openvsmobile-next/config.json` (mode 0600), and logs it to
stderr. Copy that token into the Flutter app's Settings screen. To
override, set `OPENVSMOBILE_TOKEN` before launching — when the token
comes from the environment it is NOT printed to the log.

To override the port: `PORT=8123 pnpm run dev`.

The backend persists recents (per-user, not per-connection) to
`~/.config/openvsmobile-next/state.json`. Missing/corrupt files are
silently reinitialized.

### Health and protocol

- `GET /healthz` — plain `ok` for liveness probes.
- `GET ws://host:port/rpc` — the single WebSocket carrying JSON-RPC 2.0
  in both directions, exactly as described in §4.1 of the design doc.
  Handshake (`auth.handshake`) must be the first message; the
  connection is closed with code 1008 on a bad token.
- `POST /notify` — Bearer-token-authed sender API for the notification
  system (§4.5). Same token as the WebSocket; mounted on the same HTTP
  server. Body is a `Notification` minus server-assigned fields. See
  the `mobile-notify` CLI in `bin/` for an out-of-the-box sender.

### Smoke-testing without the Flutter app

`scripts/smoke.mjs` opens a workspace under `mktemp -d`, lists it,
reads a text + binary file, opens a second workspace, activates the
first, spawns a PTY, sends `echo hello-smoke && exit`, waits for the
`terminal.exit` notification, and closes both workspaces. Exits
non-zero on any failure.

```bash
# Backend already running (with OPENVSMOBILE_TOKEN=secret on port 7861)
TOKEN=secret PORT=7861 node scripts/smoke.mjs
```

If you don't set `TOKEN`, the script reads it from
`~/.config/openvsmobile-next/config.json`.

## Running the Flutter client

Requirements: Flutter ≥ 3.41 stable, an Android SDK + emulator (or a
real device with USB debugging) when you want to run on hardware.

```bash
cd next/app
flutter pub get
flutter analyze            # zero warnings expected
flutter test               # one smoke test
flutter build apk --debug  # produces build/app/outputs/flutter-apk/app-debug.apk
flutter run                # device or emulator
```

When the app starts for the first time it shows a Settings screen with
three fields: **Host**, **Port**, **Bearer token**. Fill in the
network reachable address of the machine running the backend (e.g.
`192.168.1.10`, or `10.0.2.2` if you're on the Android emulator
talking to a backend on the host), the port, and the token printed by
the backend.

You can reopen Settings later via the gear icon in the app bar.

### App layout (this iteration)

- **App bar.** Left side: a "(choose workspace)" / workspace-label
  button that opens the workspace switcher. Right side: a gear icon
  for Settings.
- **Workspace switcher** (modal bottom sheet) has three sections:
  1. **Open workspaces** — your active sessions. Tap to switch focus,
     long-press to close (confirm dialog).
  2. **Recent** — recently opened roots that aren't currently active.
     Tap to open as a new workspace.
  3. **Browse new…** — drills through directories step-by-step.
     Workspaces are opened via this picker; **there is no raw path
     text input anywhere in the UI**.
- **Bottom navigation.** Two tabs in this iteration: **Files** and
  **Terminal**. Plugins and Settings tabs are deferred (Settings
  reachable via the app-bar gear icon).
- **Files.** Lazy-expand tree of the current workspace. Tap a text
  file to open a read-only viewer; binary files show a placeholder.
- **Terminal.** Header chip strip = PTY sessions in the current
  workspace (with a "+ New" chip). Tap to focus, long-press to kill
  (confirm). The first time you enter a workspace's Terminal tab a
  PTY is auto-created so the view isn't empty.

When focus moves to another workspace, background workspaces' PTYs
keep running and their output keeps accumulating into per-session
byte buffers (capped at 256 KB per session in the client to bound
memory). On re-focus the buffered output is replayed into the xterm
view.

## Protocol summary (implemented in this iteration)

Frontend → Backend:

| Method                | Notes |
|-----------------------|-------|
| `auth.handshake`      | `{ token, protocolVersion, client }` → `{ ok, serverVersion, protocolVersion, defaultCwd }`. Closes the socket on bad token. |
| `system.ping`         | `{}` → `{ now }`. Heartbeat used by the client to detect silent NAT drops. |
| `workspace.list`      | `{} → { active: Workspace[], recents: string[] }` |
| `workspace.open`      | `{ root, activate?: boolean = true }` → `{ workspace }`. Adds root to recents. With `activate:true` (default) sets the new workspace as current; with `activate:false` the existing focus is preserved and the new workspace is staged in the background. |
| `workspace.activate`  | `{ id }` → `{ workspace }`. Focus only — no filesystem touch. |
| `workspace.close`     | `{ id }` → `{}`. Kills all PTYs in the workspace, updates current. |
| `workspace.current`   | `{} → { workspace \| null }` |
| `fs.listDir`          | `{ workspaceId, path }` → `{ entries }`, or `{ path, picker: true }` for the workspace-less picker. Dirs first, then files, alphabetical. The workspace-scoped form realpath-resolves the target before any read, so symlinks cannot escape the workspace boundary. |
| `fs.readFile`         | `{ workspaceId, path }` → `{ contentBase64, encoding: "utf8"\|"binary" }`. 2 MiB cap; refused outside workspace. Scope is asserted before any IO, and out-of-scope vs. not-found errors are intentionally indistinguishable on the wire. |
| `workspace.findFiles` | `{ workspaceId, query, limit?: number = 50, includeIgnored?: boolean = false }` → `{ matches: { path, score }[], truncated }`. Fuzzy basename-weighted scoring; `limit` capped at 200. `.gitignore` + the hard-coded noise list (`node_modules`, `.git`, `dist`, `build`, `.dart_tool`, `target`, `vendor`) are skipped unless `includeIgnored:true`. Symlinks are never followed — out-of-workspace targets cannot leak via search. |
| `git.status`          | `{ workspaceId }` → `{ isGitRepo, branch \| null, ahead, behind, entries: { path, status: "M"\|"A"\|"D"\|"?"\|"U" }[] }`. Pull RPC for the current working-tree state. Returns `{ isGitRepo: false, branch: null, ahead: 0, behind: 0, entries: [] }` for non-repo workspaces; never throws. |
| `git.diff`            | `{ workspaceId, path, base?: string, head?: string\|null }` → `{ hunks, baseSha, headSha, isBinary, tooLarge? }`. Defaults are `base: "HEAD"` and `head: null` (= working tree), so the bare call diffs unstaged + staged changes against HEAD. Either side may also be a commit SHA, a branch name, or the literal `"INDEX"` (the staged blob). `Hunk = { oldStart, oldLines, newStart, newLines, header, lines: DiffLine[] }`; `DiffLine = { kind: "context"\|"add"\|"del", text }`. `baseSha` / `headSha` are resolved 40-char SHAs (commit SHA for refs, blob SHA for working tree and INDEX, all-zero sentinel when the slot has no blob — e.g. a deleted working-tree file); the client uses `(baseSha, headSha, path)` as a content-addressed cache key per first principle #3. Binary files surface as `isBinary: true` with `hunks: []`. Patches over 500 KiB surface as `tooLarge: true` with `hunks: []` (matches design-doc §2.2: "binary / >500KB / deleted files render an explanatory placeholder, not the diff"). A path that lives nowhere — not in the working tree, not in the index, and not in either side's commit tree — returns RpcError `-32602 invalid params`. |
| `git.log`             | `{ workspaceId, path?, limit, cursor? }` → `{ entries: LogEntry[], nextCursor? }`. `LogEntry = { sha, parents: string[], authorName, authorEmail, authorDate, committerDate, subject, body? }`, newest-first. `limit` clamped to `[1, 200]`; `0` or negative falls back to `50`. `cursor` is opaque (encoding is **not** part of the contract); pass the previous response's `nextCursor` verbatim to fetch the next page. A walk pins to the HEAD sha resolved on the first page, so commits landing during pagination don't shift entries between pages. `path` restricts to commits touching that path. Non-git workspace → `{ entries: [] }` with no error. **No core UI consumer in v0** — the RPC is intentionally provided so a future history-viewer plugin has something to bind to; the missing UI is not an incomplete feature. |
| `terminal.create`     | `{ workspaceId, cols, rows, cwd? }` → `{ sessionId, workspaceId }` |
| `terminal.write`      | `{ sessionId, dataBase64 }` → `{}` |
| `terminal.resize`     | `{ sessionId, cols, rows }` → `{}` |
| `terminal.dispose`    | `{ sessionId }` → `{}` |
| `terminal.list`       | `{ workspaceId? }` → `{ sessions }` |
| `terminal.history`    | `{ sessionId, maxBytes? }` → `{ sessionId, scrollbackBase64, scrollbackOffsetEnd, bytesDropped, lengthBytes }`. Returns the most-recent up-to-`maxBytes` bytes from the per-session scrollback (default cap 1 MiB, override via `OPENVSMOBILE_SCROLLBACK_BYTES`). `scrollbackOffsetEnd` is the running `seqEnd` at the moment the snapshot was assembled; the returned bytes cover `[scrollbackOffsetEnd - lengthBytes, scrollbackOffsetEnd)`. `bytesDropped` is non-zero once the buffer has wrapped. |
| `notification.subscribe`     | `{}` → `{ ok: true }`. Per-connection toggle; fan-out skips unsubscribed connections. |
| `notification.unsubscribe`   | `{}` → `{ ok: true }`. |
| `notification.list`          | `{ since?, limit, source?, includeRead? }` → `{ items, cursor? }`. `cursor` (oldest returned timestamp) only present when the page filled. `includeRead` defaults to `true`; when `false` and the caller's `deviceId` is known, rows that include the caller's id in `read_by` are filtered out server-side. Calling `list` also triggers an opportunistic GC sweep at most once per hour. |
| `notification.markRead`      | `{ ids }` → `{ ok: true }`. Writes the connection's `deviceId` (from handshake) into each row's `read_by` array; broadcasts `notification.readChanged` to subscribed peers. Same id from the same device twice is a no-op (the array stays length-1). |
| `notification.delete`        | `{ ids }` → `{ ok: true }`. Broadcasts `notification.deleted`. Unknown ids are silently swallowed. |
| `notification.markImportant` | `{ id, important }` → `{ ok: true }`. Promote clears `ttl_until`. Demote always re-anchors at `now + 7d` (the original window is not preserved — promote wipes it). Unknown ids are silently swallowed. |
| `plugin.subscribe`           | `{}` → `{ ok: true }`. Per-connection toggle for the `plugin.stateChanged` push surface; off until called so older clients don't receive the frames. |
| `plugin.unsubscribe`         | `{}` → `{ ok: true }`. |
| `plugin.list`                | `{}` → `{ plugins: PluginInfo[] }` where `PluginInfo = { id, name, version, state: "running" \| "stopped" \| "crashed" \| "disabled", capabilities, contributes, crashReason? }`. Backend is the source of truth — clients render from this, never from a cached copy. |
| `plugin.enable`              | `{ id }` → `{ ok: true }`. Removes the plugin from the persisted disabled set; if the in-memory state was `disabled`, transitions to `stopped` and immediately activates when the manifest declares `onStartup`. Fires `plugin.stateChanged`. |
| `plugin.disable`             | `{ id }` → `{ ok: true }`. Persists the disabled flag, then terminates the child process (SIGTERM, 10 s grace, SIGKILL). Fires `plugin.stateChanged` to `state: "disabled"`. |
| `plugin.invokeCommand`       | `{ id, commandId, args? }` → `{ result?: any }`. Routed through the plugin's JSON-RPC channel as a host→plugin `command.invoke` request; the plugin's response (or error) is returned. Triggers `onCommand:<commandId>` activation if the plugin is in `stopped` state and lists that activation event. Disabled / crashed plugins reject with `-32602`. |
| `ui.subscribe`               | `{}` → `{ ok: true }`. Per-connection toggle for the UI-descriptor fan-out (design §4.3 / issue #59). The response is followed (on the next microtask) by one `ui.tree` push per currently-active panel so a fresh subscriber lands in sync. |
| `ui.unsubscribe`             | `{}` → `{}`. Drops this connection from the `ui.tree` fan-out. Connection-close auto-unsubscribes too. |
| `ui.event`                   | `{ pluginId, panelId, nodeId, type, payload? }` → `{}`. Forwards a leaf-widget interaction (button tap / text-field change / …) from the app into the owning plugin as a host→plugin `ui.event` JSON-RPC request. Returns `-32602` when the plugin id is unknown or the plugin is not active; returns `-32011 capabilityNotDeclared` when the target plugin's manifest never declared the `ui` capability. The plugin's reply is not surfaced back to the app in v0 — events are fire-and-forget from the client's perspective; plugins react by mutating their tree + re-rendering. |

Backend → Frontend (notifications):

| Method              | Params |
|---------------------|--------|
| `terminal.data`     | `{ sessionId, workspaceId, dataBase64, seqEnd }`. `seqEnd` is a per-session monotonic byte offset at the *end* of this chunk; clients use it to drop duplicates after a `terminal.history` replay. |
| `terminal.exit`     | `{ sessionId, workspaceId, exitCode }` |
| `workspace.closed`  | `{ id }` — broadcast to every subscriber when a workspace is closed (user-initiated or on backend shutdown). |
| `notification.show`        | `{ notification }` — full Notification, sent on every new POST /notify (including supersedes-driven inserts). |
| `notification.superseded`  | `{ oldId, newId }` — fires before the matching `notification.show` when the new row has a `supersedes` field. |
| `notification.readChanged` | `{ ids, readByDevice, ts }` — multi-device read-state sync. |
| `notification.deleted`     | `{ ids }` — fires on `notification.delete` and on GC sweeps. |
| `plugin.stateChanged`      | `{ id, state, crashReason? }` — fires on every plugin state transition. Filtered to peers that called `plugin.subscribe`. `state` uses the wire vocab from `plugin.list` (`running` \| `stopped` \| `crashed` \| `disabled`); `crashReason` is set when the state is `crashed`. |
| `ui.tree`                  | `{ pluginId, panelId, tree, version }` — plugin-owned UI descriptor (design §4.3). `version` is monotonic per (pluginId, panelId); clients drop pushes whose `version <= lastSeenVersion[panelKey]`. `tree` is one of the typed `UiNode` shapes — `Column / Row / Section / Card / List / Text / Spacer / TextField / Button` — and goes `null` on the final retirement push the host emits when the owning plugin's process exits or is disabled. Every node carries a mandatory unique `id`; the renderer uses it to construct `ValueKey`s so focus / scroll / animation state survive full re-renders. |

Notification storage notes:

- v0 has no hard upper bound on rows; misbehaving senders with
  `important: true` indefinitely accumulate. Watch
  `~/.local/state/openvsmobile-next/notifications.db` size. A row-count
  cap is a v1 task.

JSON-RPC error code `-32001` ("capability denied") is reserved for the
future plugin host and unused in this iteration. `-32011`
(`capabilityNotDeclared`) is in use today — plugins that call a host RPC
their manifest didn't request hit this code at the host's capability
gate.

### Why there is no `plugin.install` / `plugin.uninstall` RPC

The `plugin.*` namespace deliberately excludes install and uninstall.
Plugin install is filesystem-only — users drop a `<plugin-id>/`
directory under `~/.local/share/openvsmobile-next/plugins/` and the host
picks it up on next start. There is no marketplace, no URL fetcher, and
no RPC method that pulls untrusted code from the network. This matches
the settled architectural decision in
[`CLAUDE.md`](../CLAUDE.md) ("Plugin install is filesystem-only.
Single-user system; the user trusts their own plugins by virtue of
having put them there"). Adding network-pulling install would require a
separate design discussion about trust, signing, and uninstall is not in
scope until install is.

### UI descriptor protocol (`ui.*`)

Plugins describe their UI as a typed `UiNode` tree (design §4.3). The
backend exposes three surfaces:

| Direction          | Method      | Purpose |
|--------------------|-------------|---------|
| plugin → host      | `ui.render` | Replace one panel's tree atomically. `{ panelId, tree }`. Mandatory unique node ids; the host rejects duplicates with `-32602 invalidParams`. |
| host → app         | `ui.tree`   | Push: latest tree for one panel, with monotonic `version`. |
| app → host → plugin | `ui.event` | Forwards a user interaction (button tap / text-field change) into the plugin's `ui.event` handler. |

The widget vocabulary is `Column / Row / Section / Card / List / Text /
Spacer / TextField / Button`. **There is no escape hatch** — a feature
that doesn't fit grows the vocabulary, not the runtime. The
[Flutter renderer](app/lib/ui/ui_renderer.dart) keys every widget by
`ValueKey('ui:<id>')`; with that key stable, focus / scroll / animation
state survive a full re-render even when leaf values mutate. The
[panel cache](app/lib/ui/ui_panels_model.dart) tracks `lastVersion` per
(pluginId, panelId) and drops any push whose `version <= lastVersion`,
so reordered or duplicate pushes never roll the UI back.

A panel's lifetime ends when its plugin's process exits or is disabled
— the host emits one final `ui.tree { tree: null, version: ++ }` per
panel so the app drops the cached UI. There is no auto-restart
(settled decision; CLAUDE.md).

The Plugins tab itself (the surface that actually hosts these panels)
is deferred to C4 — this iteration ships the protocol + the renderer +
the version-drop logic, exercised by tests rather than by a visible
screen.

### Protocol notes

- **`defaultCwd`** — returned in the `auth.handshake` response. The
  client uses this as the starting directory for the workspace picker
  so it doesn't try to navigate to the phone's `$HOME` (which has no
  meaning on the backend). Older backends without this field cause the
  client to fall back to `/`.
- **`workspace.open` activation semantics** — by default opening a
  workspace also focuses it. Pass `activate: false` to add it without
  changing the user's current focus. Useful when the client wants to
  pre-stage a recently-opened workspace before the user explicitly
  switches to it.
- **`system.ping`** — application-layer heartbeat. The Flutter client
  sends one every 25 s while connected; a missing pong within 10 s
  triggers a force-close and the always-on reconnect path. Servers may
  treat `now` as opaque (it's a timestamp for debugging, not used for
  drift correction).
- **Session persistence (process-level state).** Backend state is
  process-global. Workspaces and PTYs survive client disconnects;
  closing the WebSocket detaches the subscriber but disposes nothing.
  On reconnect the client calls `workspace.list` → `terminal.list` →
  `terminal.history` for each session before writing live data, so the
  terminal view picks up exactly where the user left off. Scrollback is
  bounded at 1 MiB per session by default (override with
  `OPENVSMOBILE_SCROLLBACK_BYTES`). See
  [`docs/design/mobile-code-platform.md`](../docs/design/mobile-code-platform.md)
  §5.1. Cross-process-restart persistence is explicitly **not** a goal
  — users who need that run `tmux` inside the terminal.

## What's deferred (out of scope for this PR)

- Plugin host §3 lifecycle UI (Plugins tab, install/uninstall flow).
  The host itself + the `ui.*` descriptor protocol from §4.3 are
  implemented — see the "UI descriptor protocol" section above.
- Git status decorations + diff view.
- Code syntax highlighting.
- QR-code pairing.
- Notifications panel.
- Multi-workspace simultaneously **on the client** is in scope; multi-
  user / multi-tenant on the backend is not.
- Token rotation.
- iOS build (only Android is targeted here; iOS may follow trivially).
- Anything inside the legacy `server/`, `openvscode-server/`, `app/`
  directories.

## Manual acceptance walkthrough

The acceptance steps from the brief have been exercised:

1. Backend started with `pnpm run dev`; token printed to stderr.
2. Flutter app launched; Settings prompt → host/port/token entered →
   Save.
3. App shows the connecting → connected progression; app bar shows
   "(choose workspace)" once connected.
4. Tap app bar → Browse new… → drill into a directory → "Select this
   directory" → app bar updates to that directory's basename.
5. Files tab shows the lazy-expand tree; tap a text file → read-only
   viewer opens with the content.
6. Terminal tab connects (auto-creates one PTY for the workspace);
   typing `echo hello` + Enter shows `hello`.
7. Kill backend (Ctrl-C) → app shows the disconnected banner; does
   not crash.
8. Restart backend, restart app → recent workspace appears in the
   switcher under "Recent" and can be re-opened.
9. Open two workspaces, switch focus between them via the switcher;
   confirm the PTY in workspace A keeps running while focused on
   workspace B (echo a counter loop and watch the buffer scroll back
   when you return).

## Open questions

- **Per-session buffer cap.** 256 KB is a guess. Once a real chatty
  background PTY (e.g. `tail -f`) exists we'll know whether that's
  too generous or too stingy.
- **`fs.listDir` symlinks.** Currently treated as `file` so they
  surface in the picker but don't drill in. If we want first-class
  symlink-to-directory behavior we'd need to follow + cycle-detect.
- **Reconnection model.** The client maintains a persistent socket
  with a "WeChat-style" always-on behaviour:
  - Auto-reconnect with exponential backoff `[1, 2, 4, 8, 16, 30, …]` s
    capped at 30 s; reset on a successful handshake.
  - Authentication failures (`-32002`) move to the terminal `failed`
    state — the user must update settings to recover.
  - The OS connectivity state is observed via `connectivity_plus`:
    losing all links parks the client in `waitingForNetwork`;
    regaining a link triggers an immediate reconnect.
  - On `AppLifecycleState.resumed` we short-circuit the backoff.
  - Application-layer heartbeat (`system.ping` every 25 s, 10 s
    timeout) catches silent NAT/carrier drops.
  - Requests issued during a transient state are queued for up to
    15 s; terminal writes are dropped instead of queued because a
    stale sessionId after reconnect wouldn't make sense.
