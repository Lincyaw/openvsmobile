## Decisions

> **Note (2026-05-16):** entries from 2026-04-21 and 2026-04-26 below
> describe the *previous* architecture (Go server + OpenVSCode fork +
> in-tree bridge extension). The project is pivoting to a Flutter +
> Node mobile code platform with a plugin model — see
> `docs/design/mobile-code-platform.md`. Those entries will be archived
> wholesale once the design is ratified (§10 of that document). Leave
> them in place for now as a historical record; do not act on them.

### 2026-05-16

Context: design pivot to "minimal mobile-native workbench + plugin
platform" captured in `docs/design/mobile-code-platform.md`. Five
open design points in §4.3 were resolved autonomously via
long-horizon L4 reasoning (north-star: minimalism, mobile-native UX,
keep plugin author cognitive load low, leave future escape hatches).
All five [flagged] for user review.

- **[flagged] Widget vocabulary trimmed to layout + content + input + collection + feedback; `UiImage`/`UiTabs`/`UiChip`/`UiAvatar`/`UiDialog` deferred to v1** (L4). Modal interactions stay on the imperative `ui.showMessage`/`showQuickPick` API rather than the declarative tree; mixing modal lifecycle into a tree node has no good semantics. Reason: adding a widget is cheap on the protocol but expensive in the Flutter renderer, and the three showcase plugins (chat/settings/status feed) don't need the deferred set. `UiIcon` is in because buttons and list items need it constantly.
- **[flagged] `UiButton` and `UiIconButton` unified into a single `UiButton` with both `icon` and `label` optional (at least one required)** (L4). Reason: minimalism — one widget type, less plugin-author cognitive load, no semantic difference between "button with icon" and "icon button".
- **[flagged] Plugins UI lives behind a dedicated "Plugins" bottom-nav tab; bottom nav becomes Files / Terminal / Git / Plugins / Settings** (L4). Pinning a panel to its own bottom-nav slot is a future enhancement, not v0. Reason: preserves the 5-tab pattern users already have; alternatives (side drawer, per-panel top-level tab) are either less discoverable on mobile or require pinning UI we don't need yet.
- **[flagged] v0 ships only `ui.render` (full panel re-render). `ui.update` patch model is documented as the v1 escape hatch but not implemented** (L4). Flutter renderer does id-keyed reconciliation so focus/scroll/animation survive re-renders. Reason: plugin author should not have to manage patch ops and id stability up front; bandwidth cost of full re-render is acceptable for v0 panel sizes; patch path is additive and can be added without breaking the v0 contract.
- **[flagged] Widget node IDs are plugin-assigned, not backend-allocated** (L4). Consistent with LSP convention; plugins know their IDs at render time without round-tripping; ID collisions are an in-plugin bug and `panelId` provides cross-plugin isolation.
- **[flagged] `UiTextField` in v0 only surfaces `onSubmitEvent`; `onChangeEvent` (per-keystroke) is deferred** (L4). Reason: the first showcase plugins (workbuddy review feed, Claude helper) do not need live input; per-keystroke events over JSON-RPC are wasteful without client-side debouncing, and we'd rather design debouncing once when there's a real consumer than guess at it now.

Subsequent direction from user (same day):

- **Files and Git tabs merged; bottom nav becomes Files / Terminal / Plugins / Settings (4 tabs)** (L5: user instruction). Git status decorates entries in the file tree in place; tapping a changed file opens a `git diff` view. No standalone Git tab.
- **Workspace switcher is a global app-bar control, accessible from every tab; switching uses a recents dropdown or step-by-step directory picker. Raw path entry is disallowed** (L5: user instruction). Reason: typing absolute paths on mobile is hostile UX; recents list covers the steady-state case, and the picker covers the cold-start case without dropping the user into a free-text field.
- **First implementation lands in a fresh `next/` subdirectory containing the new Node backend and Flutter client; legacy `server/`, `openvscode-server/`, and `app/` are left untouched until the new tree is stable enough to cut over** (L5: user instruction). Reason: user authorized full rewrite but wants to keep the old artifacts running side-by-side until the new ones prove out. Demolition is P6 in `docs/design/mobile-code-platform.md`.

- **Workspaces are first-class window-like session contexts, not just "the currently viewed directory"** (L5: user instruction). Backend holds N active workspaces concurrently; each owns its PTYs and scopes `fs.*` operations; switching is a focus change, terminals on non-focused workspaces keep running. Recents persist; the active set does not. Protocol gains `workspace.activate`, `workspace.close`; `fs.*` and `terminal.*` carry `workspaceId`; notifications include `workspaceId` for client-side routing.
- **[flagged] Workspaces are keyed by server-generated UUID, not by path** (L4). Reason: same root can be closed and re-opened with fresh state — UUID gives a clean lifecycle handle, path-as-key conflates identity with location.
- **[flagged] Non-focused workspaces stream terminal output as normal; client buffers per-session and renders on focus** (L4). Reason: simpler protocol for v0, bandwidth isn't the bottleneck, throttling can be added in v1 if profiling demands it.
- **[flagged] Workspace close goes through long-press in the switcher with a confirm dialog, not an always-visible × button** (L4). Reason: mobile mis-tap on a × kills multiple terminals; long-press + confirm is the right friction level for a destructive action.
- **[flagged] Terminal tab supports multiple PTYs per workspace from v0 (header chips, "+" to add, long-press to close); files view stays single-rooted** (L4). Reason: the user explicitly called out "multiple terminals per workspace"; deferring the chips UI would force a future protocol-breaking re-shape.

### 2026-04-21

- **Terminal emulator contract is pure Dart and renderer-agnostic** (L2/L4: codebase convention + north-star reasoning). `app/lib/terminal/` avoids Flutter `Color`/widget dependencies so parser, provider, renderer, and tests can evolve independently.
- **TerminalProvider now uses the emulator as its session buffer backend** (L2: codebase research). This keeps the current text-based UI working while moving live terminal state onto the new cell-grid model.
- **TerminalScreen is migrated to the provider/session architecture before full input-handler rewrite** (L4, flagged). This removes the current dual-implementation drift and lets emulator-backed sessions become the main terminal tab path.
- **No new dependency for grapheme handling in the first pass** (L4, flagged). The emulator currently uses lightweight rune grouping with combining-mark/variation-selector support to keep the terminal core dependency-free; richer grapheme-cluster behavior can be tightened during renderer/parser follow-up.
- **TerminalPane keeps both raw-key focus and a draft TextField** (L4, flagged). The terminal surface now owns hardware key events while the draft field remains for soft-keyboard command entry, which avoids a disruptive mobile UX regression while enabling zellij/tmux key handling.
- **TerminalSnapshot now carries both visible lines and display lines** (L2). Visible lines preserve emulator-state semantics for tests and cursor math; display lines let the renderer show scrollback and alternate-buffer output from one contract.
- **Terminal websocket backlog is now an explicit `replay` frame** (L4, flagged). Reconnect no longer relies on text `endsWith` dedupe; the client resets emulator state on replay and only treats later `output` frames as live data.
- **The emulator now handles terminal queries and application cursor mode** (L3/L4). `DA`/`DSR` responses and `DECCKM` are supported because they are a small protocol surface with outsized impact on zellij/vim/tmux startup and navigation.
- **A real zellij startup fixture is checked into `app/test/fixtures/terminal/zellij_startup.base64`** (L2/L3). This keeps at least one real-world alternate-screen capture in regression coverage instead of relying only on synthetic VT sequences.
- **Narrow-screen terminal UX is now inbox-first instead of inline split fallback** (L4, flagged). Mobile opens with a session list, then drills into a dedicated terminal detail screen; swipe-to-close and long-press actions fit the chat-style interaction model better than trying to keep session management and PTY rendering on one cramped screen.

### 2026-04-26

- **Forward git/diagnostics/workspace through the openvsmobile-bridge VSCode extension; delete the local Go fallbacks** (L4). The Go server reads `~/.config/openvscode-mobile/bridge-runtime.json` (port + bearer token written by the extension on activation) and HTTP-forwards. No local CLI fallback — extension-down means `bridge_unavailable` 503. Reasons: (a) `vscode.git` is the source of truth for repo state in any sane setup; (b) language server diagnostics from the extension host beat shelling out to `go vet`/`dart analyze` per request; (c) one well-defined failure surface beats two divergent code paths.

- **Push state changes from extension SSE → Go EventStream → Flutter WebSocket; do not poll** (L4). The previous "let Flutter poll /bridge/git/repository every N seconds" was rejected as unsuitable for mobile (battery, latency on AI-driven commits, stale state on background→foreground). Extension subscribes to `vscode.git` per-repo `onDidChange` and `vscode.languages.onDidChangeDiagnostics` (debounced 200ms), serves an SSE `/events` stream; Go has a long-lived consumer with mtime-aware reconnect; Flutter `BridgeEventsClient` fans events into the affected providers.

- **Terminal stays local PTY (`internal/terminal/` via creack/pty); do NOT migrate to extension** (L4, anchored). `vscode.window.Terminal` has no public stdout reader, and the alternatives (`onDidWriteData` proposed API only available in dev-mode extensions; bundling node-pty in the extension which would require a build pipeline + native bindings) all amount to *reimplementing* PTY in JS rather than *forwarding* to OpenVSCode. The "forward to OpenVSCode" principle exists to avoid reimplementation, so terminal is the one component where local impl honors the principle. Latency is also better (Flutter→Go→PTY is two hops vs Flutter→Go→HTTP-chunked→Node→PTY which is four). Nested PTYs (tmux/zellij/`claude` inside terminal) work identically in both impls because the kernel handles them. **Future agents/refactors: do not propose moving terminal to the bridge.** This is a settled decision.
