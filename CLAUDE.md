# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## What this project is

A **mobile-native code workbench** with a plugin platform. The phone-side surface is intentionally minimal — "read code + run a terminal + show plugin panels." Everything richer (AI assistants, language services, code review flows, notification fanout) ships as a plugin, not built into the core.

The canonical design lives at [`docs/design/mobile-code-platform.md`](docs/design/mobile-code-platform.md). When this file and the design doc disagree, **the design doc wins.**

**Hard non-goals:**
- A mobile rendering of desktop VSCode.
- Running VSCode extension `.js` code or stubbing `vscode.*`. (We borrow VSCode's *data formats* — themes, grammars — not its runtime.)
- An on-device heavy editor. Editing is a non-goal for v0.
- A backend wrapper for the Claude CLI. Users run `claude` from the terminal; rich AI integration is a plugin.
- A WebView-based plugin UI host. Plugins describe UI as a typed widget tree; Flutter renders natively.

## Architecture

```
next/
├── backend/   Node 25+ / TypeScript. One persistent WebSocket at /rpc
│              carrying JSON-RPC 2.0 (Flutter ↔ backend) + a forthcoming
│              stdio JSON-RPC channel per spawned plugin process.
└── app/       Flutter Android client. Always-on WebSocket with reconnect;
              declarative widget renderer for plugin UI (§4.3 of design).

server/, openvscode-server/, app/   ← LEGACY (Go + OpenVSCode-fork era).
                                      Kept side-by-side until P6 cutover.
                                      Do NOT edit. Do NOT reintroduce
                                      code from them into next/.
```

### Bottom navigation: 4 tabs (settled)

**Files / Terminal / Plugins / Settings.**

- **Files** — directory tree + read-only viewer + git decorations (color + M/A/U/? badges) + tap-changed-file → diff. **No separate Git tab**; git is a view layer over Files.
- **Terminal** — local PTY in the Node backend. Multiple PTYs per workspace via header chips. Soft-keyboard companion bar (Esc/Tab/Ctrl-sticky/arrows/Home/End/PgUp/PgDn/Del).
- **Plugins** — entry point for every plugin panel. Lists active plugin panels; drills into the declarative UI tree.
- **Settings** — server URL/token, pairing, plugin management, About.

Current `next/app/` is mid-migration: ships **Files / Terminal / More** today; More holds Settings + SSH bootstrap + About as a transitional layout. Moving to the proper 4-tab arrangement (split More → Settings tab + add Plugins tab) is pending work, not a redesign.

### Core (v0) capabilities — everything else is a plugin

1. **Workspaces** as window-like session contexts (UUID-keyed, multiple active simultaneously, recents persisted, switcher in app-bar from any tab, no raw-path text input).
2. **File browser + git decorations + diff viewer.**
3. **Code viewer** with syntax highlighting and structured selection (selection → context object a plugin can consume).
4. **Terminal** with local PTY, ANSI rendering, soft-keyboard companion.
5. **Auth + pairing.** Bearer token now; QR-code first-run flow deferred.
6. **Plugin loader + IPC.** Process-per-plugin via stdio JSON-RPC; capability gates declared in `plugin.json`; UI contributions are *data*, not code.
7. **Notification surface** for plugins to post toasts/badges without owning chrome.

If a capability is not on this list, it is **a plugin or it is deferred** — including LSP, AI assistants, code review, debugger, search-across-files, PR browsing.

### Backend ↔ frontend protocol (next/backend ↔ next/app)

Single persistent WebSocket carrying JSON-RPC 2.0; first message is `auth.handshake`. Method namespaces in v0:

- `auth.*` — handshake, rotateToken
- `workspace.*` — list, open, activate, close, current, findFiles
- `fs.*` — listDir, readFile (workspace-scoped; symlinks cannot escape root)
- `terminal.*` — create, write, resize, dispose, list, history
- `git.*` — status, diff, log (read-only in v0)  *(not yet implemented)*
- `plugin.*` — list, enable, disable, install, uninstall, invokeCommand  *(not yet implemented)*
- `ui.*` — event (user interacted with plugin UI; routed to owning plugin)  *(not yet implemented)*

Notifications (push-only, no polling for streams): `terminal.data`, `terminal.exit`, `workspace.fileChanged`, `workspace.closed`, `git.changed`, `ui.tree`, `notification.show`, `plugin.stateChanged`.

Full reference in `next/README.md` (currently-shipped surface) and `docs/design/mobile-code-platform.md` §4 (target surface).

### Plugin model (when it lands)

Closer to **LSP** than to **vscode.\***: anything that speaks JSON-RPC over stdio can be a plugin.

- Each plugin ships `plugin.json` declaring `entry`, `activation` events, `capabilities` (fs/terminal/network/secrets/ui), and `contributes` (commands/panels/statusItems).
- Capabilities are declared, not inferred — backend gates every call.
- Activation is event-based (`onStartup`, `onCommand:*`, `onFileType:*`); plugins do not all start at boot.
- **UI is described as data**: a typed widget tree (`UiColumn` / `UiRow` / `UiSection` / `UiCard` / `UiList` / `UiTextField` / `UiButton` / …). Flutter renders. Updates are full re-renders in v0 (reconciled by node id, so focus/scroll/animation survive); incremental `ui.update` patches reserved for v1.

**Plugin host is the largest pending v0 piece.** Until it lands, "AI integration" means: type `claude` in the terminal.

### Distribution

Backend ships as a self-contained linux tarball (portable Node + production node_modules + compiled JS + `launch.sh`) plus an `install.sh` that drops a `systemd --user` unit and emits one line of JSON (`{port, token, version, linger}`) on success.

Released via `.github/workflows/release-backend.yml` on `backend-v*` tags; native runners for x64 and arm64 (no qemu — node-pty's node-gyp rebuild doesn't cross cleanly). Flutter client embeds `kBackendVersion` constant pointing at the matching release; SSH-bootstrap flow in `next/app/lib/screens/ssh_bootstrap_screen.dart` streams `install.sh` over SSH stdin and parses the JSON line to populate settings.

## Settled architectural decisions (do not propose reverting)

- **No standalone Git tab.** Git is a view layer over Files.
- **No backend Claude CLI wrapper.** Users launch `claude` from the terminal; rich AI lives in a plugin.
- **Terminal stays local PTY in the Node backend.** Kernel handles nested PTYs (tmux/zellij/`claude` inside terminal) identically.
- **No WebView plugin host.** Plugins describe UI as a typed widget tree; Flutter renders natively. Missing widget → grow the vocabulary, do not fall back to HTML.
- **No VSCode extension runtime.** No `vscode.*` shim. Themes/grammars/snippets borrowed as data formats only.
- **Settings is a top-level tab, not a More-tab sub-entry.** The current "More tab" is a transient layout artifact during migration.
- **Workspaces are UUID-keyed**, not path-keyed. Same path closed and re-opened gets a fresh id.
- **No raw filesystem path text input anywhere in the UI.** Workspace switcher uses recents list + step-by-step picker.
- **`server/`, `openvscode-server/`, `app/` are legacy** and kept side-by-side with `next/` until P6 cutover. Do not edit. Do not reintroduce code that was deleted from them.

<!-- auto-harness:begin -->
## Project conventions

- Backend: Node ≥ 25 (bundled in release tarball), TypeScript strict, ESM. Package manager: pnpm.
- App: latest stable Flutter SDK, Android API target latest.
- Package management: `pnpm install --frozen-lockfile` (backend), `flutter pub get` (app).
- Formatting: `dart format` (app), Prettier-defaults are fine in backend.
- Validation gate (before committing): `cd next/app && flutter analyze && cd ../backend && pnpm typecheck` must pass.
- Language: discussion in Chinese, code/comments/docs in English.
- All new code lives under `next/`. Treat `server/`, `openvscode-server/`, `app/` as read-only history.

## Active skills

- dev-loop — implement → test → vibe-verify → AI-review → measure → keep/discard
- north-star — quantifiable optimization targets with observation mechanisms
- long-horizon — autonomous decision-making with escalation ladder (L1-L5)

## North-star targets

1. **Build health** — both halves of `next/` build successfully.
   Measure: `cd next/backend && pnpm typecheck && cd ../app && flutter build apk --debug`
   (Release tarball build is CI's job — `pkg/build-tarball.sh` is not a local gate.)

2. **Test health** — 100% pass rate on what exists.
   Measure: `cd next/app && flutter test`
   (Backend has no test harness yet — a known gap to fix when the v0 surface stabilizes.)

3. **Code health** — zero warnings from static analysis.
   Measure: `cd next/app && flutter analyze && cd ../backend && pnpm typecheck`

4. **Design alignment** — every `next/` feature maps to a §2 line item in `docs/design/mobile-code-platform.md`, is a plugin, or is explicitly deferred. No fourth bucket.

Secondary tiebreaker: simpler code that maps cleanly to a design-doc section > clever abstractions that don't.
<!-- auto-harness:end -->
