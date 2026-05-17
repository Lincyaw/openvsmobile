# Project conventions

The rulebook both humans and review agents apply when reviewing code under `next/`. Where this document and a specific design doc (e.g. `mobile-code-platform.md`) disagree, **the design doc wins**.

**Living document.** Conventions exist to reduce review friction. If one of these is causing more friction than it removes, update *this document* in the same PR that violates it. Do not silently violate.

## Scope

- These rules apply to everything under `next/`.
- `server/`, `openvscode-server/`, `app/` are legacy and frozen. Read-only history.
- Plugin code (when the plugin host lands) lives outside this repo. Plugin **contract** rules in §3 still apply.

---

## 1. Backend (`next/backend/`)

### Philosophy

The backend is a **thin, well-typed, transport-uniform mediator** between the Flutter client and plugin processes. It is not a CMS, an ORM, or a workflow engine. Its job is: validate, scope, dispatch, stream. Anything that smells like business logic is either a plugin or out of scope.

### Hard rules

**One transport.** A single persistent WebSocket at `/rpc` carries JSON-RPC 2.0 in both directions. `/healthz` is the only other HTTP endpoint. **No REST**, no GraphQL, no separate event channels. Streaming = JSON-RPC notification.

**Streams are notifications, never polled.** Terminal output, file changes, plugin UI tree updates, git change events — pushed from backend to client. Clients never poll `git.status` on a timer. If a future feature wants polling, that's a design discussion, not an implementation choice.

**Statefulness lives in one place.** `state.ts` (`ProcessState`) owns every long-lived resource: workspaces, PTYs, future plugin processes. Handlers in `rpc.ts` reach into `ProcessState` but never instantiate live resources directly. **Connections come and go; `ProcessState` does not.** A client disconnect detaches a subscriber; it does not dispose any resource. Resources are disposed only by explicit RPC (`terminal.dispose`, `workspace.close`).

**Workspace scoping at the gate.** Every `fs.*` and `terminal.*` call carries a `workspaceId`. Path validation (realpath, escape-check) happens before any IO, in one choke point. Per-handler ad-hoc validation is a bug. Out-of-scope vs. not-found errors are intentionally indistinguishable on the wire.

**Capability gating at the gate.** Future plugin RPC calls are gated against the plugin's manifest. Like workspace scoping, this happens in one place (`connection.ts` or `rpc.ts` — pick one, document it), not scattered across handlers.

**Errors are structured.** Every error throws a typed `RpcError` with one of the codes registered in `src/rpc.ts`. No `throw new Error("something went wrong")`. The client switches on the code; the message is human text and may change without semver impact.

**Tokens are not logged.** The bearer token is written to `~/.config/openvsmobile-next/config.json` (0600) and the runtime info file (0600). Never `console.log`'d, never echoed in error responses. The token's *source* (env / config / generated) is OK to log.

**No background polling, ever.** No `setInterval` outside the keepalive heartbeat. State changes flow through events. The backend reacts; it does not patrol.

**Native modules are constrained.** Currently allowed: `node-pty`. Adding another native dep requires updating `pkg/build-tarball.sh`'s ELF-arch verification and `pnpm-workspace.yaml`'s `allowBuilds:` list. Pure-JS is preferred when feasible.

**ESM only.** No `require`. `node:` prefix for builtins (`node:fs`, `node:path`, `node:crypto`). Relative imports include `.js` extension.

**No `utils.ts` / `helpers.ts` dumping grounds.** Each file is one concern. New concerns get their own file.

### Module boundaries inside backend

```
index.ts        bootstrap; reads no protocol, sees no PTY
config.ts       token + recents persistence; no transport
runtimeInfo.ts  atomic runtime.json write; no transport
connection.ts   the ONLY file that knows WebSocket framing
rpc.ts          method dispatch + error codes; speaks JSON-RPC only
state.ts        ProcessState; owns live resources; no transport
terminal.ts     the ONLY file that imports node-pty
workspace.ts    the ONLY file that knows the workspace data model
```

If you want to import node-pty from `rpc.ts`, that means `terminal.ts` is missing an interface. Don't reach across.

---

## 2. Client (`next/app/`)

### Philosophy

The client is **thin, reactive, Flutter-idiomatic**. It is a UI shell over the backend's RPC. Every async path is cancellable; every cross-cutting state lives in one place; no widget owns more state than it absolutely needs.

We do **not** adopt a state-management framework (no Provider / Riverpod / Bloc / GetX). The whole app state lives in a single `ChangeNotifier` (`AppState`). When that becomes painful, we re-evaluate — but not preemptively. *[Open call: §9.]*

### Hard rules

**Single source of truth: `AppState`.** Anything visible to more than one screen lives in `AppState`. Screens subscribe via `addListener`/`removeListener` (or `AnimatedBuilder`). Screens never duplicate state that already exists in `AppState`. The one exception is settings persistence (`SettingsStore` over SharedPreferences).

**One Navigator.** All routes go through the root Navigator. No nested navigators, no tab-internal navigation stacks. Deep transitions: `Navigator.push(MaterialPageRoute(...))`.

**Network through `BackendClient`.** Screens never call `WebSocket.connect` or `http.get`. All RPC goes through `BackendClient`; all state derived from RPC lives in `AppState`. New RPC methods land in `BackendClient` first, surface through `AppState` second, get consumed by screens third.

**Widget statefulness is local UI state only.** A widget is `StatefulWidget` only if it owns a `TextEditingController`, a `ScrollController`, an animation, or a transient "is this sheet expanded" boolean. **Server-derived state is always in `AppState`.** A widget that `setState`s after a backend call is a bug; that data belongs in `AppState`.

**Material 3 by default.** No custom theme until there's a designer in the loop. Use `FilledButton`, `OutlinedButton`, `ListTile`, `ChoiceChip`, `Card` — don't hand-roll equivalents. *[Open call: §9.]*

**Cancellation discipline.** Every async operation inside a State checks `mounted` before `setState`. Every navigation/snackbar uses a `Navigator.of(context)` / `ScaffoldMessenger.of(context)` captured **before** the await, never after. The `use_build_context_synchronously` lint is on; do not ignore it.

**Errors surface uniformly.** SnackBar from `ScaffoldMessenger` for transient errors. Inline error widgets for screen-level errors ("couldn't load files"). No bespoke dialog libraries. No multiple toast plugins.

**English-only strings in v0.** No `intl`, no `arb`, no locale-aware date formatting until the plugin host stabilizes. When i18n arrives it'll touch every screen — do it once, not piecemeal. *[Open call: §9.]*

**No singletons outside `AppState` + `SettingsStore` + `BackendClient`.** No global `key`s outside the navigator. No `static late` instances accessed from widgets.

**One file per screen until ~400 lines.** Then promote to a folder: `screens/foo/foo_screen.dart` + `screens/foo/_widgets.dart`. Files under a screen folder prefixed with `_` are screen-private.

### Module boundaries inside client

```
lib/main.dart            App entry; wires AppState ↔ BackendClient
lib/app_state.dart       Central ChangeNotifier
lib/backend_client.dart  All RPC; speaks JSON-RPC objects only
lib/settings_store.dart  SharedPreferences wrapper
lib/models.dart          Wire types (Workspace, FileEntry, …)
lib/version.dart         Constants (kBackendVersion)
lib/screens/             Top-level screens
lib/services/            Stateful cross-screen logic that doesn't fit
                         AppState (e.g. SshBootstrapService owns SSH
                         lifecycle for the duration of one install run)
```

**No `lib/utils/`, no `lib/helpers/`.** Pure helpers live next to their first caller. If two callers need them, promote to `lib/services/` (stateful) or `lib/<topic>.dart` (pure).

### Component design philosophy

- **Stateless first.** Widgets without a controller/animation/local UI state are stateless. No "future-proofing" with `StatefulWidget`.
- **Composition over inheritance.** No widget subclasses except the framework's.
- **Read only the slice you display.** Widgets consuming `AppState` read only what they render. `AnimatedBuilder` with a narrow `Listenable` beats rebuilding on every `notifyListeners()`.
- **Buttons name their outcome.** "Save and switch", not "Apply". Destructive actions use `colorScheme.error` and require confirmation.
- **No emoji in production UI** unless the user explicitly requests it.
- **No bare spinners.** A `CircularProgressIndicator` is always paired with a label ("Loading workspace…", "Connecting…").

---

## 3. Plugin contract (forward-looking)

When the plugin host lands, plugins live outside this repo but conform to a strict contract enforced by the backend.

### Philosophy

Plugins are **untrusted by default**. They are processes, not modules. The process boundary is the security boundary. Plugin authors do not negotiate access at runtime — they declare it in `plugin.json` and get exactly that, or the call returns `capability_denied`.

### Hard rules

**One process per plugin.** No in-process plugin hosting. No shared-library loading. No JavaScript sandboxing (`vm.runInContext`). The kernel is our sandbox.

**Manifest is the contract.** Capabilities listed in `plugin.json` are the only ones the backend grants. Adding a capability requires a new manifest and a re-install — there is no "request more permissions at runtime" path.

**Capabilities are coarse but explicit.**
- `fs: "read"` → may call `workspace.readFile`, `workspace.listDir`.
- `terminal: "spawn"` → may call `terminal.spawn`.
- `network: ["api.anthropic.com"]` → outbound HTTPS to that exact host, no wildcards.
- `secrets: ["anthropic.apiKey"]` → may read/write that exact secret key.

**No ambient access.** Plugins do not see `$HOME`, `$PATH`, DNS for hosts outside their `network` list, or processes other than their own. The backend mediates everything.

**UI is data, not code.** Plugins return widget trees (`UiNode`). No `eval`-able strings, no function pointers, no Turing-complete escape hatch. If the widget vocabulary can't express a behavior, raise it as a vocabulary-extension request (§4.3 of the design doc).

**Plugin failures are contained.** A plugin crash kills only that plugin. The backend emits `plugin.stateChanged`; the client offers "restart plugin". Other plugins and the backend itself are unaffected.

**Plugin secrets go through the OS keystore.** Plugins never persist secrets to their own storage. The `secrets.*` API reads/writes from the platform keystore, scoped by plugin ID.

**Plugin IDs are reverse-DNS.** `com.example.foo`. Panel/command/status IDs are namespaced under the plugin ID (`com.example.foo.chat`). Backend enforces uniqueness across installed plugins.

**Plugin UI is full-render in v0.** Plugins re-emit the whole panel tree on any state change. Incremental patches are v1.

### What the plugin can and cannot see

```
Plugin process            stdio JSON-RPC              Backend
  workspace.readFile() ──────────────────▶  capability check
                                              ↓ if ok
                                              read with workspaceId scope
                                              ↓
                       ◀──────────────────  result or capability_denied
```

The plugin **does not** see file paths outside its workspace, env vars from the host, the bearer token, the user's other plugins, or any RPC method not explicitly listed in §3.3 of the design doc.

---

## 4. Naming

- **RPC methods:** `namespace.action`, lowercase, dot-separated. `workspace.open`, `terminal.create`, `git.status`.
- **JSON-RPC params / results:** `camelCase`. `workspaceId`, not `workspace_id` or `WorkspaceID`.
- **Backend files:** `camelCase.ts` (matches existing: `runtimeInfo.ts`, `terminal.ts`).
- **Backend types / classes:** `PascalCase`. No `I` prefix on interfaces.
- **Dart files:** `snake_case.dart`. Widget classes `PascalCase`.
- **Plugin IDs:** reverse-DNS. `com.org.plugin-name`.
- **`SharedPreferences` keys:** `kebab-case`. `server-host`, `bearer-token`.
- **Git tags:** `backend-v<semver>`; future `app-v<semver>`.

Avoid abbreviations except the universally understood (`id`, `cli`, `pty`, `pwd`, `cwd`). No `btn`, `usr`, `mgr`, `ctx`.

---

## 5. Error handling

- **Backend:** every public method throws an `RpcError` with a JSON-RPC numeric code from the project table. New error conditions get a new code, registered in `src/rpc.ts`. Reuse over invention.
- **Client:** every catch decides between surface-to-user (SnackBar / inline error) or escalate (rethrow with context). Don't silently swallow.
- **Plugin protocol:** capability denials use `-32001`. Workspace-scope violations use `-32602` (invalid params) — paths outside the workspace and non-existent paths are indistinguishable on the wire.

---

## 6. Testing

- **Client:** widget tests for non-trivial state machines (reconnect logic, terminal lifecycle, settings save flow). No tests for pure layout.
- **Backend:** integration via the smoke script (`scripts/smoke.mjs`). Unit tests for serialization / parsing where bug risk is high (token redaction, runtime-info atomicity).
- **No mocks of the file system, no mocks of PTY.** The real thing is fast on dev machines. Use temp dirs (`mktemp -d`) for isolation.
- **A test mock larger than 20% of the production unit means the unit is wrong**, not the test.

---

## 7. Commits and releases

- **Conventional commits.** `feat(next):`, `fix(next):`, `docs:`, `refactor(next):`, `chore(next):`, `ci(next):`. The `(next)` scope is repo-wide because everything new lives under `next/`; `docs:` is unscoped for top-level docs.
- **One concern per commit.** A commit that touches both backend and app for unrelated reasons is two commits.
- **Tag releases on green CI.** `backend-v<semver>` for backend tarballs.
- **Linear history on `main`.** Fast-forward merges only from worker worktrees. Rebase onto latest `main` before pushing.

---

## 8. When this document is wrong

Open a PR that changes *this document* in the same change that violates a rule. Do not silently violate.

---

## 9. Open calls (the higher-stakes opinionated choices)

These are decisions in this v0 that are worth explicit user sign-off. Flip them by editing this section.

| § | Choice | Why it's the call I made | What to write here to override |
|---|---|---|---|
| 2 | No state-management framework (`ChangeNotifier` only) | Smaller surface, less ceremony, fewer rebuild-trap landmines; can adopt Riverpod later without rewriting | "Adopt Riverpod from start" |
| 2 | Material 3, no custom theme in v0 | Designer not in the loop yet; accessibility audit precedes branding | "Custom theme allowed when X" |
| 2 | English-only strings, no `intl` in v0 | i18n touches every screen; do once, not piecemeal | "i18n adopted with locales: ..." |
| 3 | `network` capability whitelists are exact hosts, no wildcards | Conservative default; widens later if needed | "Allow `*.subdomain.com` wildcards" |
| 6 | No FS / PTY mocks | Real thing is fast enough; mock drift is the main test-failure mode in CI | "FS mocks allowed in <case>" |
