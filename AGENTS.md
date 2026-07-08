# AGENTS.md

This file provides guidance to Codex when working with this repository.

## What this project is

A **mobile-native code workbench** with a plugin platform. The phone-side surface is intentionally minimal — "read code + run a terminal + show plugin panels." Everything richer (AI assistants, language services, code review flows, notification fanout) ships as a plugin, not built into the core.

The canonical design lives at [`docs/design/mobile-code-platform.md`](docs/design/mobile-code-platform.md). When this file and the design doc disagree, **the design doc wins.**

Project-specific conventions for both code and review are at [`docs/conventions.md`](docs/conventions.md). Both human and agent reviewers apply that rulebook to anything under `next/`.

**Hard non-goals:**
- A mobile rendering of desktop VSCode.
- Running VSCode extension `.js` code or stubbing `vscode.*`. (We borrow VSCode's *data formats* — themes, grammars — not its runtime.)
- An on-device heavy editor. Editing is a non-goal for v0.
- A backend wrapper for the Codex CLI. Users run `Codex` from the terminal; rich AI integration is a plugin.
- A WebView-based plugin UI host. Plugins describe UI as a typed widget tree; Flutter renders natively.

## First principles

Read these before designing anything new. Every concrete rule under "Settled architectural decisions" is downstream of one of these. They are the *why*; the settled list is the *what*.

**Design for the long term, not the v0 surface.** v0 may implement only a slice, but the wire protocol shape must be the one we'd pick if we were building this at full scale. Getting the protocol wrong now means breaking every client later. Implementation can be lazy; the contract cannot be.

1. **Backend is the source of truth; client subscribes and renders.** No client-side polling for freshness. No "pull to refresh". If the user can perceive the UI is stale, the model is wrong — fix the push path, not the UI.

2. **Pushes are semantic, not "something changed."** A push tells the client *exactly* what changed (which paths, which branch, which version) so the client never needs a follow-up query to act on it. Vague broadcasts ("git.changed") are an anti-pattern — they force every client to re-pull and defeat the point of a push.

3. **Pull RPCs are content-addressed and cacheable.** Request-response methods (`git.diff`, `git.log`, `fs.readFile`) are keyed by content hash / commit sha / mtime+size so the client can cache aggressively and the backend can short-circuit recomputation.

4. **State carries a monotonic version; reconnect is a first-class path.** Every server-pushed event carries a `version`. On reconnect, the client asks `subscribe(sinceVersion: N)`; the backend either replays from a small journal or sends a fresh snapshot and resets the baseline. Disconnect never clears the UI — last-known state stays visible behind an "offline" indicator until resync.

5. **Per-resource subscription is in the protocol from day one.** Subscriptions carry a scope (paths, ids, …); pushes are filtered to subscribed scope. v0 may always subscribe-all, but the protocol must scale to 50k-file monorepos without a breaking redesign. Lazy / on-demand expansion is a server-side optimization layered over the same wire format, not a protocol change.

6. **Write operations stay in the terminal; the app observes.** Git writes, deploys, package installs, file edits — none of these get app-side buttons in the core. The user types the command; the backend watches the filesystem and pushes the resulting state delta. Any "should we add a button for X?" temptation reframes to "should X be a plugin?" — if yes, the plugin host gates it via capabilities; if no, terminal-only.

7. **Multiple views are projections of one model, not separate pages.** Files / Changes / Search are filter predicates over the same tree, not independent screens. One workspace = one tree; tabs and toggles change *what's emphasized*, never *what exists*.

8. **Plugins extend the vocabulary, never the runtime.** When a feature doesn't fit, grow the typed widget tree, the RPC namespace, or the capability set — never reach for an escape hatch (WebView, `vscode.*` shim, in-tree if-statement for one plugin's needs). The core stays thin precisely so the surface stays auditable.

## Architecture

```
next/
├── backend/   Node 25+ / TypeScript. One persistent WebSocket at /rpc
│              carrying JSON-RPC 2.0 (Flutter ↔ backend) + a forthcoming
│              stdio JSON-RPC channel per spawned plugin process.
└── app/       Flutter Android client. Always-on WebSocket with reconnect;
              declarative widget renderer for plugin UI (§4.3 of design).
```

### Bottom navigation: 5 tabs (settled)

**Files / Terminal / Voice / Plugins / Settings.**

- **Files** — directory tree + read-only viewer + git decorations (color + M/A/U/? badges) + tap-changed-file → diff. **No separate Git tab**; git is a view layer over Files.
- **Terminal** — local PTY in the Node backend. Multiple PTYs per workspace via header chips. Soft-keyboard companion bar (Esc/Tab/Ctrl-sticky/arrows/Home/End/PgUp/PgDn/Del).
- **Voice** — host-rendered eyes-free control surface over plugin-exposed shortcuts. It scans typed `ui.tree` nodes marked `voiceShortcut: true` and routes gestures back through `ui.event`; it is not a built-in AI chat client.
- **Plugins** — entry point for every plugin panel. Lists active plugin panels; drills into the declarative UI tree.
- **Settings** — server URL/token, pairing, plugin management, About.

The 5-tab arrangement is live in `home_shell.dart`. Earlier drafts of this doc described a transitional "Files / Terminal / More" layout; that migration is complete — Settings is its own tab, Voice is the eyes-free projection, and Plugins is in place. SSH bootstrap and About are reachable from inside Settings.

### Core (v0) capabilities — everything else is a plugin

1. **Workspaces** as window-like session contexts (UUID-keyed, multiple active simultaneously, recents persisted, switcher in app-bar from any tab, no raw-path text input).
2. **File browser + git decorations + diff viewer.**
3. **Code viewer** with syntax highlighting and structured selection (selection → context object a plugin can consume).
4. **Terminal** with local PTY, ANSI rendering, soft-keyboard companion.
5. **Auth + pairing.** Bearer token now; QR-code first-run flow deferred.
6. **Plugin loader + IPC.** Process-per-plugin via stdio JSON-RPC; capability gates declared in `plugin.json`; UI contributions are *data*, not code.
7. **Voice / eyes-free control surface** as a host projection over plugin-exposed `voiceShortcut` actions and `ui.event` routing.
8. **Notification surface** for plugins to post toasts/badges without owning chrome.

If a capability is not on this list, it is **a plugin or it is deferred** — including LSP, AI assistants, code review, debugger, search-across-files, PR browsing.

### Backend ↔ frontend protocol (next/backend ↔ next/app)

Single persistent WebSocket carrying JSON-RPC 2.0; first message is `auth.handshake`. Method namespaces in v0:

- `auth.*` — handshake, rotateToken
- `workspace.*` — list, open, activate, close, current, findFiles
- `fs.*` — listDir, readFile (workspace-scoped; symlinks cannot escape root)
- `terminal.*` — create, write, resize, dispose, list, history, listExternalSessions, adoptExternalSession
- `git.*` — status, diff, log (read-only in v0)  *(not yet implemented)*
- `plugin.*` — list, enable, disable, install, uninstall, invokeCommand  *(not yet implemented)*
- `ui.*` — event (user interacted with plugin UI; routed to owning plugin)  *(not yet implemented)*

Notifications (push-only, no polling for streams): `terminal.data`, `terminal.exit`, `terminal.detached`, `workspace.closed`, `ui.tree`, `notification.show`, `plugin.stateChanged`.

The workspace/git push surface (tree deltas, decoration deltas, HEAD changes) is being designed per first principles #2–#5 — semantic events carrying a monotonic version, filtered by per-path subscription. Exact event names land when `git.*` and the resident workspace model are implemented; `workspace.fileChanged` / `git.changed` placeholders from earlier drafts are explicitly **not** the target shape.

Full reference in `next/README.md` (currently-shipped surface) and `docs/design/mobile-code-platform.md` §4 (target surface).

### Plugin model (when it lands)

Closer to **LSP** than to **vscode.\***: anything that speaks JSON-RPC over stdio can be a plugin.

- Each plugin ships `plugin.json` declaring `entry`, `activation` events, `capabilities` (fs/terminal/network/secrets/ui), and `contributes` (commands/panels/statusItems).
- Capabilities are declared, not inferred — backend gates every call.
- Activation is event-based (`onStartup`, `onCommand:*`, `onFileType:*`); plugins do not all start at boot.
- **UI is described as data**: a typed widget tree (`UiColumn` / `UiRow` / `UiSection` / `UiCard` / `UiList` / `UiTextField` / `UiButton` / …). Flutter renders. Updates are full re-renders in v0 (reconciled by node id, so focus/scroll/animation survive); incremental `ui.update` patches reserved for v1.

**Plugin host is the largest pending v0 piece.** Until it lands, "AI integration" means: type `Codex` in the terminal.

### Distribution

Backend ships as a self-contained linux tarball (portable Node + production node_modules + compiled JS + `launch.sh`) plus an `install.sh` that drops a `systemd --user` unit and emits one line of JSON (`{port, token, version, linger}`) on success.

Backend tarballs (linux x64 + arm64) and Android APKs (per-ABI + universal) are built and published together on `v*` tags by `.github/workflows/release.yml`. Native runners for backend (x64 + arm64); APK splits emerge from a single host build via `--split-per-abi`. The APK's `kBackendVersion` is substituted from the tag at build time so SSH bootstrap pulls the matching backend. APK signing degrades gracefully: with the four `ANDROID_*` secrets configured it's release-signed, without them it falls back to debug signing with a warning. See [`docs/release.md`](docs/release.md) for the full release workflow and keystore setup. The SSH-bootstrap flow in `next/app/lib/screens/ssh_bootstrap_screen.dart` streams `install.sh` over SSH stdin and parses the JSON line to populate settings.

## Settled architectural decisions (do not propose reverting)

- **No standalone Git tab.** Git is a view layer over Files.
- **No backend Codex CLI wrapper.** Users launch `Codex` from the terminal; rich AI lives in a plugin.
- **Terminal stays local PTY in the Node backend.** Kernel handles nested PTYs (tmux/zellij/`Codex` inside terminal) identically.
- **No WebView plugin host.** Plugins describe UI as a typed widget tree; Flutter renders natively. Missing widget → grow the vocabulary, do not fall back to HTML.
- **No VSCode extension runtime.** No `vscode.*` shim. Themes/grammars/snippets borrowed as data formats only.
- **Settings is a top-level tab, not a More-tab sub-entry.** The current "More tab" is a transient layout artifact during migration.
- **Workspaces are UUID-keyed**, not path-keyed. Same path closed and re-opened gets a fresh id.
- **No raw filesystem path text input anywhere in the UI.** Workspace switcher uses recents list + step-by-step picker.
- **Plugin install is filesystem-only.** Users put a `<plugin-id>/` directory under `~/.local/share/openvsmobile-next/plugins/`. No marketplace, no URL install, no `plugin.install` RPC that pulls from the network. Single-user system; the user trusts their own plugins by virtue of having put them there.
- **No client-side plugin approval flow.** Capability declarations in `plugin.json` are accident-prevention and documentation, not a consent UI. Host enforces silently — calls outside declared capabilities return `RpcError -32011 capabilityNotDeclared`.
- **One process per plugin; no automatic restart on crash.** A crashed plugin freezes its last `ui.tree` and overlays a `[View log] [Reload]` banner. Automatic restart would hide bugs and burn battery.
- **Node plugins can only import `@openvsmobile/sdk` and Node built-ins.** Plugins that need arbitrary npm dependencies declare `entry.kind: "binary"` and ship their own runtime. The SDK route keeps the plugin surface small and the host's responsibilities narrow.

<!-- auto-harness:begin -->
## Project conventions

- Backend: Node ≥ 25 (bundled in release tarball), TypeScript strict, ESM. Package manager: pnpm.
- App: latest stable Flutter SDK, Android API target latest.
- Package management: `pnpm install --frozen-lockfile` (backend), `flutter pub get` (app).
- Formatting: `dart format` (app), Prettier-defaults are fine in backend.
- Validation gate (before committing): `cd next/app && flutter analyze && cd ../backend && pnpm typecheck` must pass.
- Language: discussion in Chinese, code/comments/docs in English.
- All code lives under `next/`. The legacy Go-server / OpenVSCode-fork / pre-`next` Flutter tree has been removed; if you need to reference past behavior, use `git log`.

## Active skills

- dev-loop — implement → test → vibe-verify → AI-review → measure → keep/discard
- north-star — quantifiable optimization targets with observation mechanisms
- long-horizon — autonomous decision-making with escalation ladder (L1-L5)

## North-star targets

1. **Build health** — both halves of `next/` build successfully.
   Measure: `cd next/backend && pnpm typecheck && cd ../app && flutter build apk --debug`
   (Release tarball build is CI's job — `pkg/build-tarball.sh` is not a local gate.)

2. **Test health** — 100% pass rate on what exists.
   Measure: `cd next/app && flutter test && cd ../backend && pnpm test`
   (Backend now has a vitest harness covering the workspace + git push
   surface and the unified-diff parser. The terminal / PTY persistence
   surface is still smoke-only; broaden coverage when that area sees
   changes.)

3. **Code health** — zero warnings from static analysis.
   Measure: `cd next/app && flutter analyze && cd ../backend && pnpm typecheck`

4. **Design alignment** — every `next/` feature maps to a §2 line item in `docs/design/mobile-code-platform.md`, is a plugin, or is explicitly deferred. No fourth bucket.

Secondary tiebreaker: simpler code that maps cleanly to a design-doc section > clever abstractions that don't.
<!-- auto-harness:end -->
