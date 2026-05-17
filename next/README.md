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
| `terminal.create`     | `{ workspaceId, cols, rows, cwd? }` → `{ sessionId, workspaceId }` |
| `terminal.write`      | `{ sessionId, dataBase64 }` → `{}` |
| `terminal.resize`     | `{ sessionId, cols, rows }` → `{}` |
| `terminal.dispose`    | `{ sessionId }` → `{}` |
| `terminal.list`       | `{ workspaceId? }` → `{ sessions }` |
| `terminal.history`    | `{ sessionId, maxBytes? }` → `{ sessionId, scrollbackBase64, scrollbackOffsetEnd, bytesDropped, lengthBytes }`. Returns the most-recent up-to-`maxBytes` bytes from the per-session scrollback (default cap 1 MiB, override via `OPENVSMOBILE_SCROLLBACK_BYTES`). `scrollbackOffsetEnd` is the running `seqEnd` at the moment the snapshot was assembled; the returned bytes cover `[scrollbackOffsetEnd - lengthBytes, scrollbackOffsetEnd)`. `bytesDropped` is non-zero once the buffer has wrapped. |
| `notification.subscribe`     | `{}` → `{ ok: true }`. Per-connection toggle; fan-out skips unsubscribed connections. |
| `notification.unsubscribe`   | `{}` → `{ ok: true }`. |
| `notification.list`          | `{ since?, limit, source?, includeRead? }` → `{ items, cursor? }`. `cursor` (oldest returned timestamp) only present when the page filled. |
| `notification.markRead`      | `{ ids }` → `{ ok: true }`. Writes the connection's `deviceId` (from handshake) into each row's `read_by` array; broadcasts `notification.readChanged` to subscribed peers. |
| `notification.delete`        | `{ ids }` → `{ ok: true }`. Broadcasts `notification.deleted`. |
| `notification.markImportant` | `{ id, important }` → `{ ok: true }`. Pinning clears the TTL; unpinning a previously-pinned row re-arms a default TTL. Unknown id → `-32010 notificationNotFound`. |

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

JSON-RPC error code `-32001` ("capability denied") is reserved for the
future plugin host and unused in this iteration.

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

- Plugin host / UI tree protocol (§3 and §4.3 of the design doc).
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
