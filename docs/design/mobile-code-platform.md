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
2. **File browser + git decorations** — directory tree with
   mobile-appropriate gestures; git status decorates entries in place
   (modified / added / deleted / untracked badges). Tapping a changed
   file offers a `git diff` view. Write operations (commit / push /
   branch) are deferred or pushed to a plugin.
3. **Code viewer** — syntax-highlighted read-mostly viewer with
   selection; selection becomes a structured context object that any
   plugin can consume.
4. **Terminal** — local PTY with ANSI rendering. Touch-friendly key
   bars, gestures for ctrl/tab/esc, paste from clipboard.
5. **Auth / pairing** — bearer-token pairing between Flutter client and
   backend; QR-code first-run flow.
6. **Plugin loader and IPC** — discover installed plugins, spawn their
   processes, route messages, surface their declared UI contributions.
7. **Notification surface** — a place plugins can post user-visible
   messages (toasts, badges) without owning the chrome.

The Flutter bottom navigation is **Files / Terminal / Plugins /
Settings** (4 tabs). Git lives inside Files — there is no standalone
Git tab. The "Plugins" tab is the entry point for every plugin
panel: it lists active panels and drills into the panel renderer
defined in §4.3. Pinning a heavily-used panel to its own bottom-nav
slot is a future enhancement, not v0.

Anything not in this list — Claude integration, LSP, code review UI,
GitHub PRs, search-across-files, debugger — is a plugin.

## 3. Plugin model

The model is deliberately closer to **LSP** than to **vscode.\***. The
goal is "anything that can speak JSON-RPC over stdio can be a plugin",
because this keeps the surface small, language-neutral, and amenable to
sandboxing.

### 3.1 Manifest

Each plugin ships a `plugin.json`:

```json
{
  "id": "com.example.claude-helper",
  "name": "Claude Helper",
  "version": "0.1.0",
  "protocolVersion": "1.0",
  "entry": { "kind": "process", "command": ["node", "main.js"] },
  "activation": ["onStartup", "onCommand:claude.ask", "onFileType:dart"],
  "capabilities": {
    "fs":       "read",
    "terminal": "spawn",
    "network":  ["api.anthropic.com"],
    "secrets":  ["anthropic.apiKey"],
    "ui":       ["panel", "command", "statusItem"]
  },
  "contributes": {
    "commands":    [{ "id": "claude.ask", "title": "Ask Claude" }],
    "panels":      [{ "id": "claude.chat", "title": "Claude", "icon": "sparkles" }],
    "statusItems": [{ "id": "claude.status" }]
  }
}
```

Three principles:

- **Capabilities are declared, not inferred.** A plugin that doesn't
  declare `terminal: spawn` cannot spawn a process even if it tries;
  the backend rejects the JSON-RPC call.
- **Activation is event-based.** Plugins do not all start at boot;
  activation events scope when they wake.
- **Contributions are data, not code.** What the user sees in the UI
  (commands, panels, status items) is declared in the manifest; the
  plugin process only handles the events.

### 3.2 Plugin host

- Plugins run as **child processes** of the backend (one process per
  active plugin). Process boundary = capability boundary; the host
  enforces `fs`, `network`, `terminal`, and `secrets` gates by
  mediating the API calls, not by relying on the plugin to behave.
- Language of the plugin process is its own business. Node is the
  expected default because the LSP ecosystem is there, but a Go,
  Python, or Rust plugin is fine as long as it speaks the protocol.
- Each plugin has a lifecycle: `installed → enabled → activated →
  deactivated → disabled → uninstalled`. Backend persists the
  `installed/enabled` flags; `activated` is derived from activation
  events at runtime.

### 3.3 API surface exposed to plugins

Method namespaces, all reachable via JSON-RPC from the plugin to the
backend. Each call is gated by the matching capability in §3.1.

- `workspace.*` — `readFile`, `listDir`, `findFiles`, `findText`,
  `getCurrentSelection`, `onDidChangeFile` (notification stream).
- `editor.*` — `getOpenedFile`, `revealRange`, `applyEdit` (if/when
  editing arrives in core).
- `terminal.*` — `spawn`, `write`, `onData` (subscription), `dispose`.
- `git.*` — read-only status/diff/log; write ops gated and deferred.
- `ui.*` — `renderPanel`, `setStatusItem`, `showMessage`,
  `showQuickPick`. See §4.3 for the UI tree schema. Incremental patch
  (`updatePanel`) is reserved for v1; v0 plugins re-render the whole
  panel.
- `secrets.*` — `get(key)`, `set(key, value)`, scoped to the plugin id
  and backed by an OS keystore on the phone (never persisted in plugin
  storage).
- `lm.*` (optional, defined in v1) — a uniform "language model"
  interface so AI plugins are interchangeable.

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
| `workspace`  | `list` (→ `{ active: Workspace[], recents: string[] }`), `open({ root })`, `activate({ id })`, `close({ id })`, `current`, `findFiles({ workspaceId, ... })` |
| `fs`         | `listDir({ workspaceId, path })` or `listDir({ path, picker: true })`; `readFile({ workspaceId, path })` |
| `terminal`   | `create({ workspaceId, cols, rows, cwd? })`, `write`, `resize`, `dispose`, `list({ workspaceId? })` |
| `git`        | `status({ workspaceId })`, `diff({ workspaceId, ... })`, `log({ workspaceId, ... })` |
| `plugin`     | `list`, `enable`, `disable`, `install`, `uninstall`, `invokeCommand` |
| `ui`         | `event` (user interacted with plugin UI; routed to owning plugin)    |

`Workspace = { id: string (UUID), root: string, label: string, createdAt: number }`. Backend assigns the UUID; the same path opened, closed, then reopened gets a fresh id. `fs.*` operations on paths outside their `workspaceId`'s root are rejected; the `picker: true` form of `fs.listDir` is the only OS-scoped escape hatch and is intended exclusively for the workspace picker UI.

Notifications (backend → frontend, push-only):

| Method            | Params                                          |
|-------------------|-------------------------------------------------|
| `terminal.data`   | `{ sessionId, workspaceId, bytesBase64 }`       |
| `terminal.exit`   | `{ sessionId, workspaceId, exitCode }`          |
| `workspace.fileChanged` | `{ workspaceId, path, change: "added"\|"modified"\|"deleted" }` |
| `workspace.closed`| `{ id }` (server-initiated, e.g. on backend shutdown) |
| `git.changed`     | `{ workspaceId }`                               |
| `ui.tree`         | `{ panelId, tree: UiPanel }` (full render; only render protocol in v0) |
| `notification.show` | `{ level, title, message, pluginId? }`        |
| `plugin.stateChanged` | `{ pluginId, state }`                       |

Output streaming (terminal `data`, file changes) is **always** a
notification — never a polled request. Bytes are base64-encoded inside
JSON to keep the channel debuggable; a v1 binary side-channel can move
PTY traffic off JSON if profiling demands it.

Streams from **all active workspaces** are pushed at all times, even
for workspaces the client is not currently focused on. The client
buffers per-`sessionId` and renders the active workspace's terminals
on demand. Backend-side throttling of non-focused workspaces is a
performance optimization reserved for v1 if profiling shows it
matters; v0 keeps the protocol simple.

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
