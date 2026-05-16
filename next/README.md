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
| `auth.handshake`      | `{ token, protocolVersion, client }` → `{ ok, serverVersion, protocolVersion }`. Closes the socket on bad token. |
| `workspace.list`      | `{} → { active: Workspace[], recents: string[] }` |
| `workspace.open`      | `{ root }` → `{ workspace }`. Adds root to recents, sets current. |
| `workspace.activate`  | `{ id }` → `{ workspace }`. Focus only — no filesystem touch. |
| `workspace.close`     | `{ id }` → `{}`. Kills all PTYs in the workspace, updates current. |
| `workspace.current`   | `{} → { workspace \| null }` |
| `fs.listDir`          | `{ workspaceId, path }` → `{ entries }`, or `{ path, picker: true }` for the workspace-less picker. Dirs first, then files, alphabetical. |
| `fs.readFile`         | `{ workspaceId, path }` → `{ contentBase64, encoding: "utf8"\|"binary" }`. 2 MiB cap; refused outside workspace. |
| `terminal.create`     | `{ workspaceId, cols, rows, cwd? }` → `{ sessionId, workspaceId }` |
| `terminal.write`      | `{ sessionId, dataBase64 }` → `{}` |
| `terminal.resize`     | `{ sessionId, cols, rows }` → `{}` |
| `terminal.dispose`    | `{ sessionId }` → `{}` |
| `terminal.list`       | `{ workspaceId? }` → `{ sessions }` |

Backend → Frontend (notifications):

| Method              | Params |
|---------------------|--------|
| `terminal.data`     | `{ sessionId, workspaceId, dataBase64 }` (workspaceId may be null when the workspace was already closed) |
| `terminal.exit`     | `{ sessionId, workspaceId, exitCode }` |
| `workspace.closed`  | `{ id }` — echoed for user-initiated close, used for server-initiated closes on shutdown. |

JSON-RPC error code `-32001` ("capability denied") is reserved for the
future plugin host and unused in this iteration.

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
- **Reconnection.** The client connects once on settings save. It does
  not auto-reconnect on transient socket drops; the user retriggers
  by saving the same settings again. Fine for v0; a simple retry
  loop is worth adding when the first non-developer uses this.
