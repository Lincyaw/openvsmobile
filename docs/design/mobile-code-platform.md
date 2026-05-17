# Mobile Code Platform — Design v0

Status: **draft, supersedes the "wrap OpenVSCode Server" architecture**
Owner: project lead
Last updated: 2026-05-16

> This document replaces the current architectural posture described in
> `CLAUDE.md` ("forward to OpenVSCode, don't reimplement"; fork hosts an
> in-tree extension; Go server wraps Claude CLI). Once this design is
> ratified, `CLAUDE.md` and `decisions.md` must be rewritten to match.
> Until then, treat this doc as the source of truth for *intent* and the
> existing code as the source of truth for *current behavior*.

## 1. Project identity

**What we are building:** a minimal, mobile-native code workbench with a
plugin platform. Core surface ≈ "read code + run a terminal"; everything
else (AI assistants, language services, git enrichment, code review
flows, notification fanout) ships as plugins. The client is **Flutter**.
There is no embedded browser; plugin UI is rendered by Flutter natively
through a typed widget-tree protocol (see §4.3).

**What we are explicitly not building:**

- A mobile rendering of desktop VSCode.
- A consumer of the VSCode extension marketplace at the runtime level.
  We will **not** stub `vscode.*` or run extension `.js` code. We will
  borrow VSCode's *data formats* — themes, grammars, snippets, language
  configurations (see §6).
- An on-device heavy editor. Editing is a non-goal for v0; refinements
  may be added later, but the design must not assume it.
- A custom backend wrapper for the Claude CLI. Users launch `claude`
  from the terminal. AI integration richer than that, if any, lives in
  a plugin.
- A WebView-based plugin UI host. Plugins describe UI as data; Flutter
  renders. Anything a plugin cannot express in the widget vocabulary is
  a signal to **grow the vocabulary**, not to fall back to HTML.

**Why this shape:** the previous architecture inherited the entire
weight of VSCode (Monaco workbench, extension host, IPC channels, fork
maintenance) in order to "forward, don't reimplement". An audit of what
we actually consume (terminal PTY, git status/diff, file read, recursive
find, diagnostics events) showed each item is a few-dozen-to-few-hundred
lines of standard library work. Maintaining a VSCode fork to host one
in-tree extension is paying a recurring cost for a benefit that has
evaporated. Pivoting to a Flutter-native, plugin-extensible platform
lets us optimize the chrome for mobile from day one and own the plugin
contract end-to-end.

## 2. Minimal core (v0 scope)

The core is intentionally narrow. If a capability is not on this list,
it is either deferred or assigned to a plugin.

1. **Workspaces as window-like session contexts** — a workspace is a
   first-class object on the backend (`{ id: UUID, root, label,
   createdAt }`), not just "the directory currently being viewed". The
   backend holds **multiple active workspaces simultaneously**; each
   owns its own PTY sessions and is the scope for `fs.*` operations.
   Switching workspaces is a focus change, not a teardown — non-focused
   workspaces keep their terminals running in the background (matches
   VSCode-window semantics). The recents list (paths, persisted)
   survives restarts; the active set does not. Switcher lives in a
   **global app-bar control** visible from any tab; switching happens
   via a list of currently-open workspaces, a recents dropdown, or a
   step-by-step directory picker. The client never asks the user to
   type a raw filesystem path.
2. **File browser + git decorations + diff viewer.** The Files tab
   renders a single directory tree fed by `fs.listDir`; git status
   decorates each file in place (M / A / D / ? / U badges; folder
   entries show a neutral count badge — see §4.1 "Decoration is
   file-level"). A thin status bar at the top reads
   `<branch> · ↑N ↓M · K changed`; non-git workspaces show
   `Not a git repository` and the bar is inert. **The status bar is not
   a control surface** — branch switches, commits, fetches, pulls all
   happen in the terminal (first principle #6); the bar exists to
   observe, not to act. Tapping the bar enters a **Changes view**:
   same tree, filtered to changed files and their ancestor chains,
   with directory expansion state preserved across the toggle. Tapping
   a file in Changes view opens the diff (unified, hunks default
   expanded, binary / >500KB / deleted files render an explanatory
   placeholder, not the diff). Tapping a file in normal view opens
   the read-only viewer — to see a diff, enter Changes view. **No
   write operations** (commit / push / branch / stage / unstage /
   stash) live in the app's core; an opinionated git workflow is a
   plugin's job. **No git-log UI in v0**: the `git.log` RPC exists for
   future plugin consumers but no core UI exposes it; users wanting
   history run `git log` in the terminal.
3. **Code viewer** — syntax-highlighted read-mostly viewer with
   selection; selection becomes a structured context object that any
   plugin can consume.
4. **Terminal** — local PTY with ANSI rendering. Touch-friendly key
   bars, gestures for ctrl/tab/esc, paste from clipboard.
5. **Auth / pairing** — bearer-token pairing between Flutter client and
   backend; QR-code first-run flow.
6. **Plugin loader and IPC** — discover installed plugins, spawn their
   processes, route messages, surface their declared UI contributions.
7. **Notification system** — a multi-source, mobile-delivered surface
   where structured messages from any sender (CLI tool from a dev
   machine, webhook from CI, plugin running in the host, or the
   backend itself) reach the user even when the app is not in the
   foreground. Senders post over a single HTTP endpoint; the backend
   persists, fans out to connected clients over the existing WS, and
   the Flutter app's foreground service posts to the Android system
   tray. No third-party push provider (FCM, ntfy, UnifiedPush) — the
   transport is the same WS we already operate. Detail in §4.5.

The Flutter bottom navigation is **Files / Terminal / Plugins /
Settings** (4 tabs). Git lives inside Files — there is no standalone
Git tab. The "Plugins" tab is the entry point for every plugin
panel: it lists active panels and drills into the panel renderer
defined in §4.3. Pinning a heavily-used panel to its own bottom-nav
slot is a future enhancement, not v0.

Anything not in this list — Claude integration, LSP, code review UI,
GitHub PRs, search-across-files, debugger — is a plugin.

## 3. Plugin model

Closer to **LSP** than to **vscode.\***: anything that can speak JSON-RPC over stdio is a plugin. The host treats plugins as untrusted peers reached over a process boundary, not as extensions inheriting the host's runtime authority.

**The system is single-user.** No marketplace, no central registry, no install flow with user-facing confirmation prompts. The user installs plugins by writing files into a directory on their backend host; they trust their own plugins by virtue of having put them there. Capability declarations exist for accident-prevention and documentation, not for a security boundary against the user themselves.

### 3.1 Installation, discovery, lifecycle

**Plugins live on disk.** Directory layout (single source of truth):

```
~/.local/share/openvsmobile-next/plugins/
├── <plugin-id>/
│   ├── plugin.json          # manifest
│   ├── main.mjs             # entry (or whatever manifest names)
│   └── ...                  # plugin's own files
└── <other-plugin-id>/
```

Override the root via env `OPENVSMOBILE_PLUGINS_DIR`. The `<plugin-id>` directory name must match `manifest.id`; mismatch → load skipped + warning logged.

**Installation = filesystem write.** There is no `plugin.install` RPC that "pulls a plugin from a URL", no centralized registry, no marketplace. The user installs by:

```bash
# on the backend host (or any machine that can write into the plugins dir over SSH/rsync)
mkdir -p ~/.local/share/openvsmobile-next/plugins/com.me.timer
cp -r ./my-built-plugin/* ~/.local/share/openvsmobile-next/plugins/com.me.timer/
# either restart the backend or call plugin.reload via RPC
```

Local dev gets a friendly path: symlink the plugin's working tree into the plugins dir and `plugin.reload` picks up changes without restart.

**Discovery is a scan.** On startup and on `plugin.reload`, the host scans `plugins/`, parses each `plugin.json`, validates it, and registers the plugin in its in-memory registry. Invalid manifest → skip + log to `~/.local/state/openvsmobile-next/plugin-logs/<id>.log`. Persisted enable/disable state lives in `~/.config/openvsmobile-next/plugin-state.json` (`{ "<id>": { "enabled": true } }`); new plugins default to enabled.

**Lifecycle states** (visible to the client via `plugin.list`):

| State        | Meaning                                                                 |
|--------------|-------------------------------------------------------------------------|
| `registered` | Manifest parsed, plugin known to the host. No process yet.              |
| `disabled`   | Registered but `enabled: false` in plugin-state — host won't activate.  |
| `activating` | Activation event matched; process spawning; `initialize` handshake in flight. |
| `active`     | Initialize handshake completed; plugin is serving RPCs.                 |
| `crashed`    | Process exited unexpectedly. Stays in this state until user reloads.    |
| `errored`    | Manifest invalid or capability conflict at activation time.             |

**Client-side surface** (kept to the bare minimum — see §2 capability #6):
- Settings → Plugins shows a list with `id / version / state / [Disable] [Enable] [View log] [Reload]`.
- No "Install" button. No "Approve capabilities" prompt. No "Update available" indicator.
- Plugin panels render through the §4.3 widget renderer in the Plugins tab; the renderer does not know which plugin owns a panel, only the `panelId`.

### 3.2 Manifest

```json
{
  "id": "com.example.claude-helper",
  "name": "Claude Helper",
  "version": "0.1.0",
  "protocolVersion": "1.0",
  "entry": { "kind": "node", "main": "main.mjs" },
  "activation": ["onStartup", "onCommand:claude.ask", "onWorkspaceOpen"],
  "capabilities": {
    "fs": "read",
    "terminal": "spawn",
    "network": ["api.anthropic.com"],
    "secrets": ["anthropic.apiKey"],
    "ui": ["panel", "command", "statusItem", "notification"]
  },
  "contributes": {
    "commands":      [{ "id": "claude.ask", "title": "Ask Claude" }],
    "panels":        [{ "id": "claude.chat", "title": "Claude", "icon": "sparkles" }],
    "statusItems":   [{ "id": "claude.status" }],
    "notifications": [{ "source": "claude-helper:*" }]
  }
}
```

**`id`** must be a reverse-DNS string `[a-z0-9._-]+`. The host uses it as both the directory name and the namespace prefix for the plugin's `source` strings in the notification system.

**`entry.kind`** is one of:

| Kind     | Shape                                      | Semantics                                                 |
|----------|--------------------------------------------|-----------------------------------------------------------|
| `node`   | `{ kind: "node", main: "main.mjs" }`       | Default. Host spawns the bundled portable Node with `--experimental-permission` (if available); main is resolved relative to the plugin directory. Plugin can only `import` from `@openvsmobile/sdk` and Node built-ins — see §3.4. |
| `binary` | `{ kind: "binary", command: [...], env? }` | Escape hatch for non-Node plugins (Go, Rust, Python). Host spawns the command unchanged. The plugin must speak the stdio JSON-RPC protocol itself (no SDK injection). Capability gating still applies on the wire side. |

`node` is the recommended path; `binary` exists so a plugin that genuinely needs to spawn a foreign-language process is possible without forcing it through a Node shim.

**`activation`** events:

| Event                  | Fires when                                                                   |
|------------------------|------------------------------------------------------------------------------|
| `onStartup`            | Backend startup, after all `registered` plugins are scanned.                 |
| `onWorkspaceOpen`      | Any `workspace.open` call succeeds.                                          |
| `onWorkspaceOpen:<id>` | A workspace with this stable `label`-derived id opens (rare; v1).            |
| `onCommand:<cmdId>`    | The user invokes `<cmdId>` from the command palette or another contribution.|
| `onFileType:<ext>`     | A file matching `*.<ext>` is opened in the viewer.                           |
| `onNotificationSource:<source>` | A notification with matching `source` is published (lets a plugin react to other plugins' notifications). |

Activation is **lazy**: a `registered`-state plugin sits idle until one of its events fires. The host spawns the process, sends `initialize`, and transitions to `active`. Plugins with no `activation` field never activate (useful for "library" plugins that other plugins might reference — though plugin-to-plugin RPC is out of scope for v0).

**`capabilities`** must be declared exhaustively; any RPC call that requires an undeclared capability returns `RpcError{ code: -32011, message: "capabilityNotDeclared" }`. The host enforces this silently — there is no user-facing prompt (this is single-user; the user wrote the manifest). The capability matrix is fully specified in §3.5.

**`contributes`** is data only — declared at manifest parse time, surfaced to the client by `plugin.list` and the command palette / status bar / Plugins tab. Plugins never imperatively register a command at runtime; they declare and handle.

### 3.3 Process model and failure isolation

- **One process per active plugin.** Process boundary = capability boundary. Crash blast radius is one plugin.
- **stdio JSON-RPC** (line-delimited, one JSON object per line — same as LSP). See §4.2 for the protocol.
- **Standard streams**: stdin/stdout carry RPC; stderr is captured by the host and tee'd to `~/.local/state/openvsmobile-next/plugin-logs/<id>.log` (rotated at 10MB, last 3 retained). Anything the plugin `console.error`s lands there.
- **Crash policy**: a plugin process exiting non-zero — or its `initialize` handshake failing — transitions it to `crashed`. **No automatic restart.** The Plugins-tab UI shows a banner inside the plugin's panel(s): `Plugin <name> crashed · [View log] [Reload]`. The user-issued `plugin.reload` is the only way back to `active`. (Rationale: automatic restart hides bugs and burns battery; one-shot crashes deserve human attention.)
- **UI on crash**: the last `ui.tree` the plugin rendered stays visible (frozen) with the crash banner overlaid. The client doesn't blank the screen — context preservation lets the user see what the plugin was doing when it died.
- **In-flight RPC**: when a plugin crashes, the host fails every pending plugin-bound RPC with `RpcError{ code: -32012, message: "pluginCrashed" }`. Calls that come in after the crash but before reload return the same error.
- **Process limits**: each plugin is spawned with conservative `ulimit`s (RSS soft cap, CPU-quota nice value) via the host's spawn options. Hardcoded for v0; configurable in v1 if a real plugin needs more.

### 3.4 Plugin SDK (`@openvsmobile/sdk`)

For `entry.kind: "node"` plugins, **the SDK is the only allowed import surface** outside Node's built-ins. The host spawns the plugin under Node's experimental permission model (or, where unavailable, with a custom `--require` shim that throws on disallowed `import`s) so that `import "axios"` inside a plugin fails fast. Plugins that need richer dependencies use `entry.kind: "binary"`.

The SDK is an in-repo workspace package (`next/backend/packages/sdk/`); plugins reference it as `@openvsmobile/sdk`. Resolution is "host-injected" in the literal sense: the host spawns Node with `--import` pointing at a side-effect loader (`@openvsmobile/sdk/runtime/sdk-loader.mjs`) which uses `module.register()` to map the bare specifier `@openvsmobile/sdk` to the package's compiled entry. This avoids NODE_PATH (which ESM does not consult) and avoids writing into user-controlled plugin directories.

The SDK that ships in v0 is intentionally narrow — just enough to write the plugin contracts already on the wire (`host.log`, `ui.render`, `ui.event`, `command.invoke`) plus the §4.3 widget vocabulary. The richer surface area sketched below (`workspace.*`, `terminal.*`, `git.*`, `secrets.*`, `notify.*`) lands as those host RPCs come online, not before; the SDK does not export wrappers for methods the host doesn't yet implement, because the SDK-side capability double-check has no useful work to do when there's nothing on the other end.

```ts
// v0 surface — exactly what `next/examples/plugins/hello/` uses.
import { createPlugin, ui } from "@openvsmobile/sdk";

const plugin = createPlugin({
  onActivate(ctx) {
    ctx.renderPanel(
      "home",
      ui.section({
        id: "home-section",
        title: "Hello",
        children: [
          ui.text({ id: "greeting", text: "Hello, stranger." }),
          ui.textField({ id: "name-field", label: "Your name" }),
          ui.button({ id: "greet-btn", label: "Greet", style: "primary" }),
        ],
      }),
    );
  },
  onUiEvent(ctx, event) { /* re-render with new state */ },
  onCommand(ctx, commandId, args) { /* return value echoes back */ },
});
plugin.run();
```

`ctx` exposes:

- `log(level, msg)` → `host.log` (always allowed).
- `renderPanel(panelId, tree)` → `ui.render` (gated by `capabilities.ui`).
- `invokeCommand(targetPluginId, commandId, args)` → `plugin.invokeCommand` (cross-plugin call; gated by the host).

Each SDK call is a thin wrapper that:
1. Checks the plugin's declared capabilities (fail-fast `Error: capability "X" not declared`). *Reserved for richer capabilities; today the SDK trusts the manifest and lets the host's gate produce the error, since v0 only has `ui`.*
2. Issues the stdio JSON-RPC call to the host.
3. The host re-checks the capability declaration server-side (defense in depth).

This double-check is deliberate: SDK-side check gives the plugin author a fast, in-process error during dev; host-side check gives the host an authoritative gate even if the plugin tampers with the SDK.

UI rendering uses constructors on the `ui` namespace that mirror the §4.3 widget vocabulary one-for-one. Re-rendering is the plugin author's job: build a fresh tree with stable node ids and pass it back to `ctx.renderPanel`. v0 has no `definePanel` / `fire` indirection — the explicit call site is easier to reason about for a 30-line `index.js` and adds no boilerplate, and the §4.3 reconciler keys on node id either way.

### 3.5 Capability matrix

Declared capabilities resolve to host-enforced RPC gates:

| Capability key | Allowed values                              | RPC methods gated                                                            | Scope rule                                                                 |
|----------------|---------------------------------------------|------------------------------------------------------------------------------|----------------------------------------------------------------------------|
| `fs`           | `"read"` \| `"write"`                       | `workspace.readFile`, `workspace.listDir`, `workspace.findFiles`, `workspace.findText`; `write` additionally unlocks `workspace.writeFile` (v1) | Always workspace-scoped — plugins cannot traverse outside the active workspace's root, even with `write`. |
| `terminal`     | `"spawn"`                                   | `terminal.spawn`, `terminal.write`, `terminal.dispose`, `terminal.onData`    | Plugins get **their own** PTY; cannot read or write the user's terminal sessions. |
| `network`      | `string[]` — domain allowlist               | Plugin-side `fetch` is intercepted via SDK helper that checks host policy; `entry.kind: "binary"` plugins must use the host's network proxy RPC to make outbound HTTP. | Strict host-prefix match (no wildcards in v0 except `"*"` which means "no restriction"). |
| `secrets`      | `string[]` — secret-key allowlist           | `secrets.get(key)`, `secrets.set(key, value)`                                | Keys outside the allowlist → `capabilityNotDeclared`. v0 stores in plain JSON at `~/.config/openvsmobile-next/plugin-secrets.json` (0600); v1 moves to an OS keystore via Android Keystore over the WS. |
| `ui`           | `string[]` — surface types                  | Each surface gates a contribution: `"panel"` → `definePanel`/`ui.render`; `"command"` → `defineCommand`/`contributes.commands`; `"statusItem"` → `defineStatusItem`/`contributes.statusItems`; `"notification"` → `notify()` to the §4.5 notification system | UI contributions appear in the client only if the matching capability is declared. |

Capabilities declared but unused are fine. Capabilities used but not declared → `-32011` and the call fails. The plugin process keeps running — capability errors are programming bugs surfaced like type errors, not crashes.

### 3.6 API surface plugins can call

(All gated by §3.5.) Method namespaces from the plugin side:

| Namespace    | Methods                                                                        |
|--------------|--------------------------------------------------------------------------------|
| `workspace.` | `readFile`, `listDir`, `findFiles`, `findText`, `getCurrentSelection`, `onChange` (subscription)        |
| `editor.`    | `getOpenedFile`, `revealRange`. `applyEdit` reserved for v1 (depends on editor capability arriving in core). |
| `terminal.`  | `spawn`, `write`, `dispose`, `onData` (subscription)                           |
| `git.`       | `diff`, `log` (read-only). Write ops are out of scope (first principle #6).    |
| `ui.`        | `render(panelId, tree)`, `setStatusItem(itemId, props)`, `showMessage`, `showQuickPick`. Incremental `update` reserved for v1; v0 re-renders full panels. |
| `secrets.`   | `get(key)`, `set(key, value)`                                                  |
| `notify.`    | `post(notification)` — wraps §4.5 `POST /notify` with the plugin's `id` auto-prefixed to `source` |

Notifications from the plugin to the client (host pushes back to plugin):

| Method                  | Params                                                          |
|-------------------------|-----------------------------------------------------------------|
| `ui.event`              | `{ panelId, eventId, sourceId, payload }` — see §4.3            |
| `workspace.changed`     | `{ workspaceId, files: { added, removed, modified } }` — filtered to capability scope |
| `terminal.data`         | `{ sessionId, bytesBase64 }` — only for plugin-owned sessions   |
| `terminal.exit`         | `{ sessionId, exitCode }`                                       |
| `commandInvoked`        | `{ commandId, args }` — activation hook handoff                 |

### 3.7 Versioning

Plugin manifests declare `protocolVersion`. The host advertises a `supportedProtocolVersions: ["1.0"]` in the `initialize` handshake. A mismatch on major version → plugin transitions to `errored` with a clear message; minor version mismatches are allowed (plugins should treat unknown RPCs / widgets as best-effort).

## 4. Communication contracts

Three protocols, all JSON, all versioned. Wire format is JSON for v0
to keep things debuggable; a binary streaming side-channel is reserved
for v1 if terminal/file throughput becomes a problem.

```
 ┌──────────┐  WS JSON-RPC   ┌──────────┐  stdio JSON-RPC  ┌─────────┐
 │ Flutter  │ ─────────────▶ │ Backend  │ ───────────────▶ │ Plugin  │
 │ client   │ ◀───────────── │ (Node)   │ ◀─────────────── │ proc    │
 └──────────┘   ui.tree /    └──────────┘   ui.render /    └─────────┘
               ui.event             routes
```

### 4.1 Frontend ↔ Backend (Flutter ↔ Node)

Transport: **single persistent WebSocket** carrying JSON-RPC 2.0 in
both directions. No separate REST endpoints in v0 — keeps the auth
story and the eventing story unified.

Envelope (TypeScript-style for readability):

```ts
type ClientMessage =
  | { jsonrpc: "2.0"; id: string | number; method: string; params?: unknown }
  | { jsonrpc: "2.0"; id: string | number; result?: unknown; error?: RpcError }
  | { jsonrpc: "2.0"; method: string; params?: unknown };  // notification

type RpcError = { code: number; message: string; data?: unknown };
```

Handshake (first message after WebSocket open):

```json
{ "jsonrpc": "2.0", "id": 1, "method": "auth.handshake",
  "params": { "token": "<bearer>", "protocolVersion": "1.0",
              "client": { "name": "openvsmobile-flutter", "version": "0.1.0" } } }
```

Method surface (frontend → backend):

| Namespace    | Methods                                                              |
|--------------|----------------------------------------------------------------------|
| `auth`       | `handshake`, `rotateToken`                                           |
| `workspace`  | `list` (→ `{ active: Workspace[], recents: string[] }`), `open({ root })`, `activate({ id })`, `close({ id })`, `current`, `findFiles({ workspaceId, ... })`, `subscribe({ workspaceId, sinceVersion?, paths? })`, `unsubscribe({ workspaceId })` |
| `fs`         | `listDir({ workspaceId, path })` or `listDir({ path, picker: true })`; `readFile({ workspaceId, path, ifEtag? })` |
| `terminal`   | `create({ workspaceId, cols, rows, cwd? })`, `write`, `resize`, `dispose`, `list({ workspaceId? })` |
| `git`        | `diff({ workspaceId, path, baseSha?, workingHash? })`, `log({ workspaceId, path?, limit, beforeSha? })` |
| `plugin`     | `list`, `enable`, `disable`, `install`, `uninstall`, `invokeCommand` |
| `ui`         | `event` (user interacted with plugin UI; routed to owning plugin)    |

`Workspace = { id: string (UUID), root: string, label: string, createdAt: number }`. Backend assigns the UUID; the same path opened, closed, then reopened gets a fresh id. `fs.*` operations on paths outside their `workspaceId`'s root are rejected; the `picker: true` form of `fs.listDir` is the only OS-scoped escape hatch and is intended exclusively for the workspace picker UI.

**Workspace subscription model.** Opening a workspace is not the same as subscribing to its events; the client makes an explicit `workspace.subscribe` call (typically right after `open`/`activate`). The backend maintains a resident model per active workspace (file tree + git status + branch state) and replies with one of three modes:

| `mode`     | Meaning                                                                      | Follows up with                     |
|------------|------------------------------------------------------------------------------|-------------------------------------|
| `current`  | Client's `sinceVersion` matches the live version; nothing to send.           | nothing                             |
| `replay`   | Backend can replay missed events from its journal.                           | a burst of `workspace.*.delta`s     |
| `snapshot` | Gap is too large; backend resets the baseline.                               | one `workspace.decoration.snapshot` at `baseVersion` — client also invalidates all cached `fs.listDir` responses |

The `paths` parameter scopes the subscription to a subset of the tree. v0 backend accepts but does not yet honor `paths` (subscription is always whole-tree); the protocol shape supports per-path filtering from day one so a future large-repo optimization is not a breaking change. See CLAUDE.md "First principles" #5.

**Content-addressed pull RPCs.** `fs.readFile` accepts `ifEtag?` and may return `{ etag, notModified: true }` (client uses its cached content). The `etag` is an opaque server-issued string; v0 happens to format it as `${mtimeMs|0}-${size}` but clients MUST treat it as a blob and only compare it for equality. `git.diff` is keyed by `{ workspaceId, path, baseSha?, workingHash? }` — same key → same hunks, allowing client and backend to cache aggressively. An unchanged file returns `{ kind: "text", hunks: [] }` (in-band signal; there is no separate "unchanged" kind). Decoration status is **never** a pull RPC; it is push-only via `workspace.decoration.delta`. See CLAUDE.md "First principles" #3.

Notifications (backend → frontend, push-only). Every workspace-scoped event carries a monotonic `version` so the client can detect gaps and request resync:

| Method                          | Params                                                                                     |
|---------------------------------|--------------------------------------------------------------------------------------------|
| `terminal.data`                 | `{ sessionId, workspaceId, bytesBase64 }`                                                  |
| `terminal.exit`                 | `{ sessionId, workspaceId, exitCode }`                                                     |
| `workspace.closed`              | `{ id }` (server-initiated, e.g. on backend shutdown)                                      |
| `workspace.tree.delta`          | `{ workspaceId, added: path[], removed: path[], renamed: {from,to}[], version }` — **cache-invalidation signal only**; the client uses it to mark affected directories' `fs.listDir` caches stale and re-fetch on demand |
| `workspace.decoration.delta`    | `{ workspaceId, entries: {path, status: "M"\|"A"\|"D"\|"?"\|"U"\|null}[], version }` (status `null` = cleared; **file-level only**) |
| `workspace.decoration.snapshot` | `{ workspaceId, entries: {path, status}[], version }` — sent only as the result of a `subscribe` returning `mode:"snapshot"`; carries only non-clean files (typically <100 entries even on large repos) |
| `workspace.head.changed`        | `{ workspaceId, branch, headSha, ahead, behind, version }`                                 |
| `workspace.commit.added`        | `{ workspaceId, branch, sha, subject, version }` (affects ahead/behind on current branch)  |
| `ui.tree`                       | `{ panelId, tree: UiPanel }` (full render; only render protocol in v0)                     |
| `notification.show`             | `{ notification: Notification }` — full payload, see §4.5                                  |
| `notification.readChanged`      | `{ ids: string[], readByDevice: string, ts: number }` — multi-device sync                  |
| `notification.deleted`          | `{ ids: string[] }`                                                                        |
| `notification.superseded`       | `{ oldId: string, newId: string }`                                                         |
| `plugin.stateChanged`           | `{ pluginId, state }`                                                                      |

Vague broadcasts (a `git.changed` that just says "something happened") are explicitly **not** in this surface — they would force every client to re-pull and defeat the point of a push. Each event tells the client exactly what changed; the client never needs a follow-up query to act on it. See CLAUDE.md "First principles" #2.

**The tree is never materialized on the client as one graph; it is lazy via `fs.listDir`.** The client holds (a) a forest of cached `fs.listDir` responses keyed by directory path and (b) a global decoration map per workspace. Tree shape comes from on-demand `listDir` calls; `workspace.tree.delta` is purely a cache-invalidation signal that tells the client which directories' cached entries are stale. No `tree.snapshot` event exists — on `mode:"snapshot"` resync, the client invalidates all `listDir` caches and re-fetches on next render, while the backend only needs to push the decoration snapshot. This keeps the protocol identical for tiny and monorepo-sized workspaces.

`fs.listDir` returns:

```ts
type TreeEntry = {
  name: string;             // entry name only, not a path
  kind: "file" | "dir" | "symlink";
  size?: number;            // bytes; files only
  symlinkTarget?: string;   // symlinks only; raw POSIX `readlink(2)` value —
                            // opaque, may be relative or absolute, may point
                            // outside the workspace; backend does NOT resolve
                            // it. Client decides what to do (treat as opaque,
                            // attempt scope-checked traversal, or display only).
};
// → { entries: TreeEntry[], version }
```

`listDir` does **not** carry git status (decoration is a separate channel — client looks up by path) and does **not** carry mtime (`fs.readFile` handles freshness via ETag). The returned `version` is the workspace-model version at the moment of listing, so the client can detect "the listDir result was already stale before I got it" races against concurrent `tree.delta` events.

**Decoration is file-level; directory roll-up is a client view concern.** The backend never emits a "directory has changes inside" status — git itself has no such concept, and mixing it into the protocol would make a single event carry both an authoritative file fact and a derived ancestor summary. The client maintains its own path-trie counter over the file-level statuses it has received and renders directory adornments (a badge with the descendant change count) from that. Consequences:

- Folders show one neutral "has changes" badge with a count (e.g. `5↑`), never a mixed M/A/?/U color.
- `.gitignore`-matched files are hidden from the tree by default (mirrors VSCode `Files: Exclude`) and do not contribute to roll-up. A Files-tab toggle ("Show ignored") makes them visible; even when shown, they do not contribute to roll-up.
- Untracked files (`?`) **do** contribute to roll-up — they are real working-tree changes the user wants visible at the folder level.
- The `.git` directory itself is always hidden.

**Event delivery contract.** The backend processes filesystem and `.git/` watcher events through a single drain loop with a small debounce window. Each drain emits a coherent burst of notifications in causal order: `workspace.head.changed` (if HEAD moved) → `workspace.tree.delta` (if entries changed) → `workspace.decoration.delta` (after one `git status --porcelain=v2 -z` diff against the in-memory baseline) → `workspace.commit.added` (one per new commit on the current branch). `.git/HEAD` writes bypass the debounce so branch switches feel instant.

Within a drain window:

- Repeat events for the same path coalesce. A file modified ten times produces one decoration entry; add+delete inside the window produces nothing.
- Watchers are configured to ignore `.git/`'s internal tree (except the handful of files the backend deliberately watches: `HEAD`, `index`, `refs/heads/*`, `MERGE_HEAD`, `FETCH_HEAD`, `packed-refs`) and `.gitignore`-matched paths, so noise from `npm install` / `node_modules` does not enter the queue at all.
- A single `decoration.delta` is unbounded in entry count. Bulk operations (a branch checkout touching 1000 files) emit one large delta, not chunks.
- Drains are serial; the next drain waits for the current one to finish.

When `.gitignore` itself changes, the backend rebuilds its matcher and triggers a full re-scan drain (equivalent to walking every tracked path through `git status` once); the client receives a larger-than-usual `decoration.delta` and applies it normally.

**Journal and resync.** The backend keeps a ring-buffered event journal per workspace, bounded by both event count and wall-clock age. `workspace.subscribe` returns `replay` when the client's `sinceVersion` lies within the journal, otherwise `snapshot`. Disconnects beyond the journal horizon resync via one `workspace.decoration.snapshot` (smaller than replaying hundreds of stale events on a real repo, since the snapshot carries only non-clean files) plus client-side invalidation of every `fs.listDir` cache. The exact debounce duration, journal size, and age cap are implementation parameters tunable in code; the contract — drain model, causal ordering, monotonic versioning, no rate-limit guarantee for clients — is what's locked here.

**Client obligations.**

- Apply events in version order. A gap (`receivedVersion != lastSeen + 1`) triggers `subscribe(sinceVersion: lastSeen)` to either replay or resnapshot.
- Treat any single delta as potentially large. Batch UI updates over a delta — do not `setState` per entry.
- Do not assume rate limits. The wire can deliver an arbitrary-size delta in one frame.

Output streaming (terminal `data`, workspace deltas) is **always** a
notification — never a polled request. Bytes are base64-encoded inside
JSON to keep the channel debuggable; a v1 binary side-channel can move
PTY traffic off JSON if profiling demands it.

Streams from **all active workspaces** are pushed at all times, even
for workspaces the client is not currently focused on. The client
buffers per-`sessionId` and renders the active workspace's terminals
on demand. Backend-side throttling of non-focused workspaces is a
performance optimization reserved for v1 if profiling shows it
matters; v0 keeps the protocol simple.

**Multi-client semantics — a workspace is a shared backend object, not a per-client view.** Several WebSocket clients may subscribe to the same workspace simultaneously (phone + tablet, multiple browser tabs in the future). The backend treats them symmetrically:

- **Terminal streams are shared.** Each terminal session has one underlying PTY in the backend. Every connected client that has the workspace subscribed receives the same `terminal.data` notifications; any client can `terminal.write` and the bytes flow into the shared PTY. There is no concept of a "terminal owner" or "primary client" — the model is `tmux`-style multi-attach, not Mosh-style single-owner. Cursor position, scroll offset, soft-keyboard state, and `focusedTerminalId` are client-local.
- **`terminal.history` replay is per-connection.** A client joining mid-stream gets its own history payload on subscribe; the underlying scrollback lives on the backend.
- **Workspace events fan out to all subscribers.** `workspace.tree.delta` / `decoration.delta` / `head.changed` etc. go to every subscribed connection. Each subscriber tracks its own `lastSeenVersion` independently; the journal and snapshot logic in §4.5 work per-subscriber.
- **Notifications fan out to all clients** (§4.5); read state syncs via `deviceId` + `notification.readChanged`.
- **Workspace lifecycle is detached from any one client.** Closing a workspace requires `workspace.close({ id })` from a client; a client disconnect alone does NOT close the workspace or its terminals — non-focused clients can come back later. Backend GC of idle workspaces is a v1 concern.

### 4.2 Backend ↔ Plugin

Transport: **JSON-RPC 2.0 over stdio**, line-delimited (one JSON
object per line). Standard JSON-RPC framing keeps it identical to LSP
in feel; existing LSP-style implementations port cleanly.

Initialization (backend initiates after spawn):

```json
// backend → plugin
{ "jsonrpc": "2.0", "id": 1, "method": "initialize",
  "params": {
    "protocolVersion": "1.0",
    "host": { "name": "openvsmobile", "version": "0.1.0" },
    "workspace": { "root": "/path/to/workspace" },
    "grantedCapabilities": { "fs": "read", "terminal": "spawn", "network": ["api.anthropic.com"] }
  }
}

// plugin → backend
{ "jsonrpc": "2.0", "id": 1, "result": { "name": "claude-helper", "version": "0.1.0" } }

// backend → plugin
{ "jsonrpc": "2.0", "method": "initialized" }
```

Method surface (plugin → backend) is exactly the §3.3 API. Capability
check happens on every call; unauthorized calls return JSON-RPC error
`-32001` (custom: `"capability denied"`).

Notifications (backend → plugin):

| Method            | Triggered when                                              |
|-------------------|-------------------------------------------------------------|
| `command.invoke`  | User triggered a command the plugin contributed             |
| `ui.event`        | User interacted with a UI node owned by this plugin         |
| `activation.event`| One of the manifest's activation events fired               |
| `workspace.change`| Workspace switched / closed (plugin should reset state)     |
| `shutdown`        | Plugin is about to be deactivated; clean up                 |

### 4.3 UI descriptor protocol (the no-WebView part)

This is the most novel piece. Plugins describe UI as a **typed widget
tree**; Flutter renders each node as a native widget. Updates are
explicit patches against node ids.

#### Widget vocabulary (v0)

The vocabulary is deliberately small. Adding a widget type is cheap on
the protocol side but expensive on the Flutter renderer side, so v0
covers what's needed for three reference plugin shapes (chat, settings,
status feed) and nothing more. `UiImage`, `UiTabs`, `UiChip`,
`UiAvatar`, `UiDialog` are explicitly deferred; modal interactions go
through the imperative `ui.showMessage` / `ui.showQuickPick` API rather
than the declarative tree.

```ts
type UiNode =
  | UiColumn | UiRow | UiSection | UiCard | UiDivider | UiSpacer
  | UiText | UiMarkdown | UiCodeBlock | UiStatusRow | UiIcon
  | UiButton | UiTextField | UiToggle | UiChoice
  | UiList | UiListItem
  | UiSpinner | UiProgress;

interface UiBase { id?: string }   // id is required for any node that emits events

interface UiColumn  extends UiBase { type: "column"; children: UiNode[]; spacing?: number; padding?: number }
interface UiRow     extends UiBase { type: "row";    children: UiNode[]; spacing?: number; align?: "start"|"center"|"end" }
// section: titled, optionally collapsible — for organizing forms / grouping by topic
interface UiSection extends UiBase { type: "section"; title: string; child: UiNode; collapsible?: boolean }
// card: pure visual grouping with no semantic structure — for list items, alerts, ad-hoc containers
interface UiCard    extends UiBase { type: "card";    child: UiNode; tone?: SemanticColor }
interface UiDivider extends UiBase { type: "divider" }
interface UiSpacer  extends UiBase { type: "spacer"; size?: number }

interface UiText      extends UiBase { type: "text"; text: string; style?: "body"|"title"|"subtitle"|"caption"|"code"; color?: SemanticColor }
interface UiMarkdown  extends UiBase { type: "markdown"; markdown: string; codeTheme?: string }
interface UiCodeBlock extends UiBase { type: "codeBlock"; code: string; language?: string }
interface UiStatusRow extends UiBase { type: "statusRow"; label: string; value: string; tone?: SemanticColor }
// icon: drawn from the bundled curated icon set; plugins reference icons by name, not by URL
interface UiIcon      extends UiBase { type: "icon"; name: string; size?: number; tone?: SemanticColor }

// button: at least one of icon or label must be present; icon-only and label-only buttons share this type
interface UiButton    extends UiBase { type: "button"; id: string; label?: string; icon?: string; style?: "primary"|"secondary"|"destructive"; onTapEvent?: string; enabled?: boolean }
// textField: v0 only surfaces onSubmitEvent. onChangeEvent (per-keystroke) is deferred until a plugin needs it; clients will be expected to debounce when it lands.
interface UiTextField extends UiBase { type: "textField"; id: string; label?: string; value?: string; placeholder?: string; multiline?: boolean; onSubmitEvent?: string }
interface UiToggle    extends UiBase { type: "toggle"; id: string; label: string; value: boolean; onChangeEvent?: string }
interface UiChoice    extends UiBase { type: "choice"; id: string; label?: string; options: { value: string; label: string }[]; value?: string; onChangeEvent?: string }

interface UiList     extends UiBase { type: "list"; children: UiListItem[] }
interface UiListItem extends UiBase { type: "listItem"; id: string; title: string; subtitle?: string; trailing?: UiNode; onTapEvent?: string }

interface UiSpinner  extends UiBase { type: "spinner"; label?: string }
interface UiProgress extends UiBase { type: "progress"; value: number; label?: string }

type SemanticColor = "neutral" | "info" | "success" | "warning" | "danger";
```

IDs are **plugin-assigned**. Backend does not generate them and does
not enforce uniqueness across plugins — collisions inside a single
plugin's panel are the plugin's bug, and `panelId` scopes the namespace
between plugins. The handshake's `protocolVersion` covers vocabulary
changes; older clients render unknown node types as a placeholder card
with the unrecognized type label.

A **panel** is the top-level addressable unit:

```ts
interface UiPanel {
  id: string;          // matches contributes.panels[].id
  title: string;
  icon?: string;
  body: UiNode;        // any UiNode subtree
}
```

#### Render call (plugin → backend)

```json
{ "jsonrpc": "2.0", "method": "ui.render",
  "params": {
    "panel": {
      "id": "claude.chat",
      "title": "Claude",
      "body": {
        "type": "column",
        "children": [
          { "type": "list", "id": "messages", "children": [] },
          { "type": "row", "children": [
            { "type": "textField", "id": "input", "placeholder": "Ask Claude…", "onSubmitEvent": "submit" },
            { "type": "iconButton", "id": "send", "icon": "send", "onTapEvent": "submit" }
          ]}
        ]
      }
    }
  } }
```

#### Updates: full re-render only in v0

There is **only `ui.render`** in v0. To "append a chat message", the
plugin emits a new `ui.render` with the updated panel tree; the
backend forwards verbatim to Flutter as a `ui.tree` notification.

Flutter holds an immutable tree per panel. On a new `ui.tree`, the
renderer reconciles against the previous tree by **node id**: any node
whose id and type are unchanged keeps its widget instance (so a
`textField` doesn't lose focus, a `list` doesn't lose scroll position,
animations don't restart). Unkeyed children fall back to positional
reconciliation.

This keeps the plugin author's mental model trivially simple — "compute
the new tree, send it" — at the cost of bandwidth for large panels.
Profiling will tell us whether this matters in practice; the §4.3
escape hatch below is reserved for that case.

#### Reserved for v1: incremental patches

If profiling shows the full-tree path is too costly for a real plugin
(e.g. a chat panel growing past a few thousand messages), an additive
`ui.update` method will be defined with this shape:

```ts
type UiPatch =
  | { op: "replace"; id: string; node: UiNode }
  | { op: "appendChildren"; id: string; children: UiNode[] }
  | { op: "removeChildren"; id: string; childIds: string[] }
  | { op: "setProps"; id: string; props: Record<string, unknown> };
```

This is **not implemented in v0**; documented here so plugin authors
know the upgrade path exists and don't design themselves into a corner
expecting it.

#### Event flow (Flutter → backend → plugin)

```json
// Flutter → backend
{ "jsonrpc": "2.0", "id": 17, "method": "ui.event",
  "params": { "panelId": "claude.chat", "eventId": "submit",
              "sourceId": "send", "payload": { "input": "Hello" } } }
```

Backend resolves `panelId` to the owning plugin, then forwards as a
`ui.event` notification:

```json
// backend → plugin
{ "jsonrpc": "2.0", "method": "ui.event",
  "params": { "panelId": "claude.chat", "eventId": "submit",
              "sourceId": "send", "payload": { "input": "Hello" } } }
```

Backend acknowledges to Flutter with `{ result: { delivered: true } }`
once the plugin process has consumed the event. Plugins respond by
issuing a fresh `ui.render` call; there is no synchronous "return a new tree
from this event" path. This matches how a real reactive UI behaves —
the event causes state to change, which causes a re-render.

#### Why a typed widget tree (not WebView, not raw Flutter widgets)

- **Style consistency on mobile.** A curated vocabulary forces all
  plugin UIs to look native. WebViews each ship their own visual
  language; on a phone that is a mess.
- **No JS engine, no HTML parser, no CSS layout.** Each node maps to a
  Flutter widget; rendering is cheap, theming is uniform, dark mode is
  free.
- **Forward compatibility.** New widget types are additive; older
  clients render unknown nodes as a typed placeholder so a plugin built
  for v1.2 degrades gracefully on v1.0.
- **Plugin portability.** A plugin emitting `ui.render` works whether
  the client is Flutter today or a different surface tomorrow.

The cost is **expressiveness ceiling** — anything not in the vocabulary
cannot be drawn. We treat that as a feature, not a bug: if a plugin
needs to draw something the platform doesn't have, the platform should
grow the vocabulary, not punt to a WebView.

### 4.4 Versioning

- Each protocol carries a `protocolVersion` exchanged at handshake.
- Major version mismatch → core refuses the plugin/client (loud
  failure, not silent fallback).
- Minor version is additive (new widgets, new methods); older runtimes
  ignore unknown methods and render unknown widget types as
  placeholders.
- The three protocols (§4.1, §4.2, §4.3) share a single version
  number for v0 to keep mental load low; they can be split later.

### 4.5 Notification system

A multi-source, mobile-delivered status surface. Any sender (CLI tool, webhook, plugin, the backend itself) posts to one endpoint; the backend persists, fans out to connected clients over the same WebSocket already used for everything else, and the Flutter client's Android foreground service posts entries to the system tray so notifications arrive even when the app is not on screen.

**No third-party push provider.** FCM, ntfy, and UnifiedPush were considered and rejected for v0. The transport is the same WS we operate; the foreground service holds the connection open. Future addition of an external transport (FCM/UnifiedPush) is a backend-side adapter at the fan-out layer — wire schema and sender surface do not change.

**Sender API (HTTP).**

```
POST /notify        Authorization: Bearer <token>
Content-Type: application/json
Body: Notification (minus server-assigned fields)
→ 200 { id }
```

**Notification payload.**

```ts
type Notification = {
  id: string;                        // server-assigned uuid; clients echo it back
  source: string;                    // free-form, recommended "<kind>:<scope>"
                                     //   e.g. "claude-code:openvsmobile",
                                     //        "ci:nightly", "experiment:e0421"
  level: "info" | "success" | "warning" | "error";
  title: string;                     // ≤80 chars
  body?: string;                     // markdown, no size cap but ≤16KB recommended
  fields?: { key: string; value: string }[];      // structured key/value pairs
  links?: { title: string; url: string }[];       // tap → external browser
  action?:                                         // tap on the notif itself
    | { kind: "open-url"; url: string }
    | { kind: "copy"; text: string }
    | { kind: "open-workspace"; workspaceId: string };
  groupKey?: string;                 // consecutive notifs with same key collapse in UI
  supersedes?: string;               // id of an earlier notif this replaces
                                     //   (progress updates → final result)
  important?: boolean;               // pinned; never auto-deleted by TTL
  ttl?: number;                      // seconds; default 7 days; important wins
  timestamp: number;                 // unix epoch ms; server fills if omitted
  widget?: UiPanel;                  // optional override; renderer reuses §4.3
                                     //   if absent → default layout from fields/links
};
```

**RPC surface (client-facing).**

| Method                        | Direction        | Purpose                                    |
|-------------------------------|------------------|--------------------------------------------|
| `notification.subscribe`      | client → backend | start receiving live `notification.*` push |
| `notification.unsubscribe`    | client → backend | stop receiving                             |
| `notification.list`           | client → backend | `{ since?, limit, source?, includeRead? }` → `{ items, cursor? }` |
| `notification.markRead`       | client → backend | `{ ids }` → broadcasts `notification.readChanged` |
| `notification.delete`         | client → backend | `{ ids }` → broadcasts `notification.deleted` |
| `notification.markImportant`  | client → backend | `{ id, important }` — pins / unpins from TTL GC |

Push notifications already listed in §4.1: `notification.show`, `notification.readChanged`, `notification.deleted`, `notification.superseded`.

**Persistence (SQLite).** Backend uses `better-sqlite3` (synchronous, single-file db). Schema:

```sql
CREATE TABLE notifications (
  id            TEXT PRIMARY KEY,
  source        TEXT NOT NULL,
  level         TEXT NOT NULL,
  title         TEXT NOT NULL,
  body          TEXT,
  payload       TEXT,        -- JSON blob: fields, links, action, widget
  group_key     TEXT,
  supersedes    TEXT,        -- id of notif this replaced (history pointer)
  superseded_by TEXT,        -- non-null = this notif was superseded (history entry)
  important     INTEGER DEFAULT 0,
  timestamp     INTEGER NOT NULL,
  ttl_until     INTEGER,
  read_by       TEXT,        -- JSON array of device ids
  created_at    INTEGER NOT NULL
);
CREATE INDEX idx_notifs_ts        ON notifications(timestamp DESC);
CREATE INDEX idx_notifs_source_ts ON notifications(source, timestamp DESC);
CREATE INDEX idx_notifs_group     ON notifications(group_key);
```

Garbage collection runs opportunistically — at most once per hour on `notification.list` calls, and once per 100 inserts. Backends with no client traffic and no inserts perform no sweep, which is fine since nothing is changing. Sweeps delete rows where `ttl_until < now AND important = 0 AND superseded_by IS NULL`. Important and superseding-chain history are preserved indefinitely.

**`groupKey` semantics:** the client groups consecutive notifications with the same `groupKey` into one collapsible card. Backend does not enforce; render hint only.

**`supersedes` semantics:** when a new notification arrives with `supersedes: <id>`, the backend writes `superseded_by` on the old row, persists the new row, and broadcasts `notification.superseded { oldId, newId }`. The new notification also fires `notification.show` as usual. Clients hide superseded entries from the main feed but can reveal them via "show history" on the superseding entry.

**Multi-device semantics.** Every client maintains a stable `deviceId` (UUID, persisted in SharedPreferences). `notification.markRead` writes the device id into the `read_by` JSON array; backend broadcasts `notification.readChanged` so other devices update their UI. Notifications fan out to **all** connected clients — there is no concept of a "primary" device.

**CLI tool (`mobile-notify`).** Single Node script, bundled in the backend tarball under `bin/`. Behavior:

- Local: reads `~/.config/openvsmobile-next/config.json` for port and token; POSTs to `http://127.0.0.1:<port>/notify`.
- Remote: `--server host:port --token $TOKEN`, or env `OPENVSMOBILE_SERVER` / `OPENVSMOBILE_TOKEN`.
- Args: `--source`, `--level`, `--title`, `--body`, `--field k=v` (repeatable), `--link title=url` (repeatable), `--action open-url:URL` or `copy:TEXT` or `open-workspace:ID`, `--group-key`, `--supersedes`, `--important`, `--ttl`.
- `--from-json -` reads the full payload from stdin (for scripts that already have JSON ready).
- Exit codes: 0 success, 2 args, 3 network, 4 auth, 5 server error.

**Foreground service (Flutter / Android).** App starts a `flutter_foreground_task`-backed service on launch (gated by a Settings toggle, default on). The service holds the WebSocket, calls `notification.subscribe`, and on `notification.show` posts to the Android system tray via a channel chosen from the `level` field:

| level     | Android channel importance | Sound  |
|-----------|----------------------------|--------|
| `info`    | low                        | no     |
| `success` | low                        | no     |
| `warning` | default                    | default|
| `error`   | high                       | default|

The persistent foreground notification ("openvsmobile-next active") is low-importance, silent, and serves only as Android's required indicator that a foreground service is running. OEMs (Xiaomi/Huawei/Oppo) that aggressively kill background services require a battery-whitelist exception; the onboarding flow documents this — same trade-off as Telegram / K-9 Mail.

**UI placement (chrome).** A bell icon in the app bar, visible from every tab with an unread-count badge. Tap → full-screen notification center with:

- List sorted by `timestamp DESC`, grouped by `groupKey` when consecutive.
- Per-source filter pills along the top.
- Each item: source pill, level color stripe, title, expandable body (markdown), action button row from `links`, relative timestamp.
- Long-press: mark read / delete / pin / mute source.
- Tap: execute `action` if present (open url, open workspace, copy text); else expand inline.
- Rendering: if `widget` is present, use the §4.3 panel renderer; on render error fall back to the default field-and-links layout. (v0 reserves the widget field but ships only the default renderer; the §4.3 renderer slot is wired but disabled until plugin host lands.)

**Settings.** Per-source rules (mute, priority override, sound override), quiet hours, default TTL, foreground-service toggle.

**Auth.** v0 uses the same single bearer token for both WS and HTTP `/notify`. Per-source scoped publish tokens are deferred to v1.

## 5. Backend stack and deployment

- Language: **Node.js / TypeScript** for the backend and plugin host.
  Rationale: aligns with the JSON-RPC + node-pty + LSP ecosystem;
  removes language seam between core and plugins; single binary surface.
- Backend exposes a single WebSocket endpoint to the Flutter client
  (auth, workspace ops, terminal, git, plugin events all multiplexed).
- Where the backend runs:
  - **Primary target**: paired developer machine (laptop, workbuddy
    node, etc.). The phone is a thin client over network.
  - **Secondary target**: on-device under Termux (advanced users only).
- Pairing: QR code emits `{ host, port, token }`; Flutter stores it.
  Token is rotatable. No multi-user / multi-tenant story in v0.

### 5.1 Session persistence (process-level state)

Backend state is **process-global**, not per-connection. A `Connection`
object is an authenticated subscriber to the shared registries; it does
not own them. Implications:

- **Workspaces survive client disconnects.** Closing the WebSocket does
  not implicitly close any workspace. Workspaces only end on explicit
  `workspace.close` or on backend process exit.
- **PTYs survive client disconnects.** Each terminal session is owned
  by its workspace, not its originating connection. When no client is
  attached, the PTY keeps running and its output accrues into a
  **per-session circular scrollback buffer** (default ~1 MB / ~8 000
  lines, configurable).
- **Reattach on reconnect.** After `auth.handshake`, the client calls
  `workspace.list` to see what's already running. For each session it
  cares about, it calls `terminal.history({ sessionId, maxBytes? })`
  to drain the scrollback, then subscribes to live `terminal.data`
  notifications. The history call returns
  `{ scrollbackBase64, bytesDropped }` so the client knows whether the
  buffer overflowed.
- **Multi-client by accident.** Two clients connecting concurrently
  see the same workspaces and terminals. PTY input from either client
  is serialized at the kernel; output streams to both. This is closer
  to VSCode Live Share than to "one user, one window" — a feature for
  "I left my phone open and now my laptop wants to follow along",
  not a bug.
- **Process restart is not persistence.** When the backend process
  itself dies, workspaces and PTYs go with it. Persisting full PTY
  state across process restarts is tmux-grade work and is **not** a
  v0 goal — users who need that run `tmux` inside our terminal.

### 5.2 Deployment / installation roadmap

The phone is a thin client; the backend lives on a paired machine.
Getting the backend onto that machine is the friction we're optimizing.

- **v0**: manual install via the repo (`git clone`, `pnpm install`,
  `pnpm run dev`). Acceptable for the author's own use; hostile to
  anyone else.
- **v0.5 — install one-liner.** Ship a static `install.sh` that:
  1. Detects platform via `uname -a` (`linux-x64`, `linux-arm64`,
     `macos-arm64`, `macos-x64`).
  2. Downloads the matching backend tarball from a hosted location
     (GitHub Releases is the obvious choice). The tarball bundles a
     compiled Node runtime (`bun build --compile` or `pkg`) plus the
     `node-pty` prebuilt for that platform.
  3. Unpacks to `~/.openvsmobile-next/`, writes a `config.json` with
     a generated token, optionally drops a systemd-user unit / launchd
     plist for autostart.
  4. Prints `host:port:token` (and a QR code form) for the user to
     paste into the Flutter app.
  Cost: a release pipeline that fans out per-platform tarballs, plus
  hosting. No SSH client on the phone, no Live-Share-grade tunnelling.
  This is the next major deployment step after the post-P1 hardening
  passes. See §8.
- **v1+ — full Remote-SSH-style bootstrap (deferred).** Embed an SSH
  client in the Flutter app, let the user enter `user@host`, app
  SSHes in, runs the install script if needed, opens an SSH local
  forward, and connects to the backend through the tunnel.
  Cost: real SSH client in Dart (`dartssh2`-class), platform-specific
  key storage, known_hosts management, port forwarding, and a
  permanent maintenance debt for the release pipeline. See §9 for the
  open question; this is not in v0 and not in v0.5.

## 6. Borrowed VSCode data formats (and what we don't borrow)

We are not consuming VSCode extensions as code, but VSCode normalized
several useful data formats. We can adopt them without coupling to the
runtime.

**Borrowed (data-only, no JS executed):**

- **TextMate grammars** for syntax highlighting — tokenizer libraries
  exist in many languages; bundle a curated set in core, allow plugins
  to contribute more.
- **JSON color themes** — directly loadable.
- **Snippets** — same JSON format VSCode uses.
- **Language configurations** — bracket pairs, comment markers, etc.
- **LSP servers** — language-agnostic by design. A "language plugin"
  wraps an LSP binary and bridges LSP ↔ our `lm.*`/`editor.*`/`ui.*`
  methods.

**Not borrowed:**

- The `vscode.*` API surface. We do not stub it, even partially.
- `extension.js` entry points. Plugins targeting our platform write
  their own entry; we do not auto-translate.
- `.vsix` packaging. Our plugin is just `plugin.json` + entry files in
  a directory or archive; the manifest is ours.

A loader utility can read a `.vsix`, extract `contributes.themes` /
`contributes.grammars` / `contributes.snippets` / language configs, and
register those into our catalogs — without ever running the bundled
JS. This gives us ~70% of the "feels marketplace-shaped" benefit
(themes / syntax / snippets / language servers) at zero runtime cost.

## 7. What gets deleted, reshaped, or kept

Legacy code is not load-bearing for the new direction. The user has
authorized a full client rewrite. Items marked **reusable** are
convenience reuse, not constraints — anything that fights the new
shape should be rewritten, not retrofitted.

| Component                                 | Disposition          | Notes |
|-------------------------------------------|----------------------|-------|
| `openvscode-server/` submodule            | **Delete**           | Drop the fork; no in-tree extension to host. |
| `extensions/openvsmobile-bridge`          | **Delete**           | Subsumed by the new backend. |
| `server/internal/bridge`                  | **Delete**           | No bridge to forward to. |
| `server/internal/claude` (CLI wrapper)    | **Delete**           | Users launch claude via terminal. |
| `server/internal/github` (device-flow)    | Reusable (port to TS)| Device-flow auth is independent of the rest. Keep behavior, rewrite in Node. |
| `server/internal/terminal` (Go PTY)       | **Replace** with `node-pty` | Behavior reusable as a reference; code itself goes. |
| `server/` (Go entry, routing, WS)         | **Delete**           | Replaced by Node backend. |
| `app/` Flutter chat UI / session browser  | **Delete**           | Out of scope. |
| `app/` Flutter file viewer + terminal UI  | **Reusable**         | Components of the new core surface. |
| `app/` Flutter git status / diff views    | **Reusable** (trim)  | Keep read-only paths; write actions deferred. |
| `docs/claude-session-format.md`           | Archive              | No longer load-bearing. |
| `docs/terminal-vt-validation.md`          | Reusable             | Still relevant to the new terminal. |
| `docs/github-auth-backend.md`             | Reusable             | Update for Node port. |
| `decisions.md`                            | Rewrite              | Most entries assume the old architecture. |
| `CLAUDE.md`                               | Rewrite              | See §10. |
| `project-index.yaml`                      | Rewrite              | Requirements need to be re-derived for the new scope. |

## 8. Migration plan (sketch)

Phases, not deadlines. Each phase is small enough to be a single PR.

- **P0 — Doc ratification.** ✅ landed at `a4f9677`. Design doc
  committed; `CLAUDE.md` and `project-index.yaml` rewrite still
  deferred to a later doc-hygiene pass.
- **P1 — Node backend skeleton + Flutter core.** ✅ landed at
  `2d54792` (a single commit; backend and client co-developed). Auth,
  workspace-as-window registry, scoped `fs.*`, multi-PTY per
  workspace, WebSocket JSON-RPC, app-bar workspace switcher with
  step-by-step picker, Files tree + read-only viewer, Terminal tab
  chip strip backed by `xterm.dart`. Legacy `server/`, `app/`, and
  `openvscode-server/` are untouched.
- **P1.5 — Hardening pass.** Reviewer-flagged correctness items
  (symlink-safe `fs.*`, ID lifecycle nits) and WeChat-style network
  resilience (state machine, exponential backoff, `connectivity_plus`
  awareness, `AppLifecycleState.resumed` reconnect, `system.ping`
  heartbeat, request queueing during reconnect). Banner stays neutral
  until terminal failure.
- **P1.6 — Terminal session persistence.** Lift `WorkspaceRegistry`
  to process-global; add per-session circular scrollback buffer
  (~1 MB / 8 000 lines); add `terminal.history({sessionId, maxBytes?})`
  RPC; client replays history on reconnect/focus. After this lands,
  closing the app or losing the network no longer kills running
  `claude`/`tmux`/`vim` sessions on the backend. Multi-client view
  of the same registry falls out for free. See §5.1.
- **P1.7 — Install one-liner + release tarballs.** Compile a static
  Node binary per `(linux x64, linux arm64, macos arm64, macos x64)`
  including the `node-pty` native binding; host on GitHub Releases;
  ship `install.sh` that detects platform, downloads, unpacks to
  `~/.openvsmobile-next/`, writes config + token, prints
  `host:port:token` for the Flutter app. See §5.2. **No SSH from the
  phone in this phase**; the user runs the one-liner via their own
  terminal.
- **P2 — Flutter UX hardening + Plugins tab placeholder.** A pass
  focused on real device testing (the P1 build was structurally
  verified but not device-tested), add the Settings/Plugins tabs as
  placeholders, polish gestures and key-bar on small screens.
- **P3 — Plugin host.** JSON-RPC over stdio, capability gating,
  declarative-only contributions first (commands, status items).
- **P4 — UI tree protocol.** Implement `ui.render` and `ui.event`
  (v0 scope; `ui.update` patch is v1 only); Flutter-side renderer for
  the §4.3 vocabulary with id-keyed reconciliation.
- **P5 — First real plugin.** Likely candidate: a code-review feed
  driven by workbuddy, or a Claude-helper that drives the terminal and
  offers a chat panel — proves the plugin model carries weight that
  used to be in core.
- **P6 — Demolition.** Delete `openvscode-server/`, `server/`,
  `extensions/openvsmobile-bridge`, and the legacy Flutter screens.
  Update build pipelines and CI.

## 9. Open questions and risks

- **Plugin distribution.** v0 supports side-loading from a local
  directory; do we want a registry (self-hosted) or git-URL install?
  Defer the decision; design the manifest so either works later.
- **UI vocabulary churn.** Adding widget types is cheap on the server
  side but every addition has to land in Flutter too. Establish a
  process for "vocabulary RFC" before the first external plugin.
- **PTY on Android.** Local PTY in Termux works; PTY *from the phone
  client connecting to a remote backend* is the primary path and just
  needs network. The Termux-on-device path is a stretch goal.
- **Plugin security model for secrets.** Plugins that talk to APIs
  (Anthropic, GitHub) need somewhere to store tokens. The `secrets.*`
  API is the answer; backing storage on the phone uses the OS keystore.
  Open: how does a paired-machine backend store secrets — file with
  OS-level perms, or push to the phone?
- **Performance budget for plugin host.** N plugin processes on a
  modest backend is fine; on Termux it isn't. Decide whether on-device
  hosting is supported or "use a paired machine" is the official
  answer.
- **Reactive UI cost.** v0 uses full-tree re-render with id-keyed
  reconciliation. This is fine up to a few hundred nodes per panel;
  long-running chat / log panels will eventually need either the v1
  `ui.update` patch path or list virtualization in the renderer. We
  haven't built either yet; profile a real plugin first.
- **What does "Claude Code as a plugin" actually offer over a bare
  terminal?** If the answer is "not much," the plugin doesn't need to
  exist and the platform's first showcase plugin should be something
  else (e.g., a code-review feed driven by workbuddy).
- **SSH-driven auto-bootstrap from the phone (Remote-SSH parity).**
  Deferred to v1+. Trigger to reopen: the install one-liner from
  §5.2 / P1.7 becomes a friction point users complain about (e.g.,
  onboarding new machines weekly, or shipping the app to non-devs).
  Open sub-questions when it does: SSH library on Dart for Android
  and iOS, secure key storage on the phone, known_hosts handling,
  jump-host / proxy-jump support, the binary-distribution maintenance
  matrix that goes with it. Not in v0, not in v0.5.
- **Cross-process-restart terminal persistence.** §5.1 calls out that
  P1.6 terminal persistence covers client disconnect, not backend
  restart. If users want `claude`/`tmux` to survive backend restarts,
  the answer for now is "run `tmux` yourself inside our terminal".
  Reopen if users push back; persisting full PTY state to disk is
  tmux-grade work and we don't want to build it speculatively.

## 9a. Appendix: §3 plugin host — as-implemented status (issue C1)

The first slice of the plugin host (issue C1) ships in `next/backend/src/plugins/`. It deliberately stays invisible to the Flutter client — no `plugin.*` RPCs surface in C1; that lands with C2. This appendix records what is live now versus what remains scheduled for C2–C5 so the design doc is not read as a promise of features that haven't shipped.

### Live in v0 (this build)

- **§3.1 — Discovery & registry.** `OPENVSMOBILE_PLUGINS_DIR` (default `~/.local/share/openvsmobile-next/plugins/`) scanned at backend boot. Each direct child with a `plugin.json` becomes a registry entry. Missing `plugin.json` is a silent skip; invalid manifest produces a registry entry in state `errored`. Directory name is canonical id; a mismatching `plugin.json.id` logs a warning and the directory wins.
- **§3.1 — Lifecycle states.** `registered` / `active` / `crashed` / `errored` are observed and held in the registry. `disabled` is defined in the type but no `plugin.reload`/`plugin.disable` RPC reaches it yet (C2). `activating` is folded into the synchronous spawn → `active` transition for now.
- **§3.2 — Manifest subset.** `id`, `name`, `version`, `entry { kind, path }`, `activation`, `capabilities { fs, terminal, network, secrets, ui }`, `contributes.commands[{id,title}]` are parsed and honored. Unknown top-level keys and unknown `contributes.*` keys are preserved verbatim (round-tripped forward) and trigger a warning so C2's richer parser doesn't have to re-discover them.
- **§3.3 — Process model.** One `child_process.spawn` per active plugin, stdio piped, stderr tee'd to `~/.local/state/openvsmobile-next/plugins/<id>.stderr.log` with 5 MiB rotation + one backup. **No automatic restart on crash** (settled). Spawn CWD is the plugin's own directory.
- **§4.2 — stdio JSON-RPC.** Backend autodetects Content-Length framing vs newline-delimited JSON from the plugin's first non-whitespace byte and uses the matching encoding for outbound writes.
- **§3.5 — Capability gate.** Every plugin → host request is gated by `capabilities` declared in the manifest. Calls outside declared capabilities receive `RpcError -32011 capabilityNotDeclared`. `host.log({ level, msg })` is the one host method exposed in C1 and requires no capability; it serves as a stdio-path smoke target.
- **`onStartup` activation.** Plugins listing `onStartup` spawn at backend boot; other activation events (`onCommand:*`, `onFileType:*`, …) are parsed and stored but do not fire any trigger in C1.

### Deferred — C2 (`plugin.*` RPC surface to the Flutter client)

- §3.1 client-side surface — `plugin.list`, `plugin.enable`, `plugin.disable`, `plugin.reload`, `plugin.invokeCommand`, log-tailing.
- `initialize` handshake (backend → plugin) and `protocolVersion` negotiation.
- `onCommand:*` activation triggered by `plugin.invokeCommand`.
- `RpcError -32012 pluginCrashed` for in-flight RPCs at crash time (no host-initiated RPC channel until C2 needs one).
- Manifest fields beyond the C1 subset (`panels`, `statusItems`, `secrets[]`, `network` allowlists, `protocolVersion`, …) — currently round-tripped but unused.

### Deferred — C3 (UI descriptor protocol)

- §4.3 `ui.render` / `ui.tree` / `ui.event` end-to-end.
- §3.5 `ui:panel` / `ui:command` / `ui:statusItem` / `ui:notification` granularity (today `ui` is a single boolean gate).

### Deferred — C4 (Plugins tab in the app)

- Settings → Plugins list + log viewer + disable/reload UI.

### Partially live — C5 (`@openvsmobile/sdk`)

- §3.4 SDK package (`next/backend/packages/sdk/`) is in-tree, with the v0 surface area: `createPlugin({ onActivate, onCommand, onUiEvent })` + `ui.*` constructors covering the §4.3 widget vocabulary. Host injects the resolver via `node --import .../sdk-loader.mjs` so `import "@openvsmobile/sdk"` resolves regardless of where the plugin lives on disk. Exercised end-to-end by `next/examples/plugins/hello/`.
- **Deferred to a later C5 slice**: import-surface restriction (Node `--experimental-permission` / `--require` shim that blocks `import "axios"`), and SDK-side defense-in-depth capability checks. The v0 SDK trusts its caller and leans on the host's capability gate as the authoritative check. Wider host RPCs (`workspace.*`, `terminal.*`, `git.*`, `secrets.*`, `notify.*`) and their matching SDK wrappers land alongside the issues that first need them.

### Intentional simplifications in v0

- The capability gate maps method namespaces (`fs.*`, `terminal.*`, `git.*`, `ui.*`, …) to a single key in the manifest's `capabilities`. The §3.5 fine-grained matrix (e.g. `network` as an allowlist of hosts) lands in C2 alongside the methods it gates.
- The `errored` registry sentinel attached to a broken manifest carries a placeholder manifest object so the registry shape stays uniform; consumers check `state === "errored"` before relying on manifest fields.

## 10. Document follow-ups (once §1–§9 are ratified)

- Rewrite `CLAUDE.md` to drop "forward, don't reimplement" and the
  OpenVSCode submodule references; replace with this document's
  identity and core scope.
- Rewrite `decisions.md` — most existing entries (terminal-stays-local,
  bridge-events, extension-as-bridge) become irrelevant; archive them
  with a pointer to this design.
- Re-derive `project-index.yaml` requirements against the new core
  scope.
- Update north-star targets: "Spec coverage" and "Build health" remain;
  the build commands change (no Go, no openvscode-server build; add a
  Node backend build target once P1 lands).
