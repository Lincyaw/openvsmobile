# Project conventions

The rulebook both humans and review agents apply when reviewing code under `next/`. Where this document and a specific design doc (e.g. `mobile-code-platform.md`) disagree, **the design doc wins**.

**Living document.** Conventions exist to reduce review friction. If one of these is causing more friction than it removes, update *this document* in the same PR that violates it. Do not silently violate.

## Scope

- These rules apply to everything under `next/`.
- Plugin code (when the plugin host lands) lives outside this repo. Plugin **contract** rules in §3 still apply.

---

## 1. Backend (`next/backend/`)

### Philosophy

The backend is a **thin, well-typed, transport-uniform mediator** between the Flutter client and plugin processes. It is not a CMS, an ORM, or a workflow engine. Its job is: validate, scope, dispatch, stream. Anything that smells like business logic is either a plugin or out of scope.

### Hard rules

**One transport.** A single persistent WebSocket at `/rpc` carries JSON-RPC 2.0 in both directions. `/healthz` is the only other HTTP endpoint. **No REST**, no GraphQL, no separate event channels. Streaming = JSON-RPC notification.

**Streams are notifications, never polled.** Terminal output, file changes, plugin UI tree updates, git change events — pushed from backend to client. Clients never poll `git.status` on a timer. If a future feature wants polling, that's a design discussion, not an implementation choice.

**Statefulness lives in one place.** `state.ts` (`ProcessState`) owns every long-lived resource: workspaces, PTYs, future plugin processes. Handlers reach into `ProcessState` but never instantiate live resources directly. **Connections come and go; `ProcessState` does not.** A client disconnect detaches a subscriber; it does not dispose any resource. Resources are disposed only by explicit RPC (`terminal.dispose`, `workspace.close`).

**Method dispatch lives in `rpc.ts`, not in the transport.** `connection.ts` is purely the WebSocket lifecycle and frame codec — it accepts an inbound JSON-RPC object and hands it to the dispatcher. `rpc.ts` owns the method table, per-method param shape validation, error code mapping, and the handler bodies. This keeps dispatch transport-agnostic (testable without a WebSocket; trivially reusable if a second transport ever appears) and prevents handlers from drifting into the framing layer.

**Workspace scoping at the gate.** Every `fs.*` and `terminal.*` call carries a `workspaceId`. Path validation (realpath, escape-check) happens before any IO, in one choke point. Per-handler ad-hoc validation is a bug. Out-of-scope vs. not-found errors are intentionally indistinguishable on the wire.

**Capability gating at the gate.** Future plugin RPC calls are gated against the plugin's manifest. Like workspace scoping, this happens in one place (`connection.ts` or `rpc.ts` — pick one, document it), not scattered across handlers.

**Errors are structured.** Every error throws a typed `RpcError` with one of the codes registered in `src/rpc.ts`. No `throw new Error("something went wrong")`. The client switches on the code; the message is human text and may change without semver impact.

**Tokens are not logged.** The bearer token is written to `~/.config/openvsmobile-next/config.json` (0600) and the runtime info file (0600). Never `console.log`'d, never echoed in error responses. The token's *source* (env / config / generated) is OK to log.

**No background polling, ever.** No **recurring** timers (`setInterval` / `Timer.periodic`) outside the connection keepalive heartbeat. State changes flow through events. The backend reacts; it does not patrol. One-shot `setTimeout` / `Future.delayed` for shutdown deadlines, reconnect backoff, or request timeouts are fine.

**Native modules are constrained.** Currently allowed: `node-pty`. Adding another native dep requires updating `pkg/build-tarball.sh`'s ELF-arch verification and `pnpm-workspace.yaml`'s `allowBuilds:` list. Pure-JS is preferred when feasible.

**ESM only.** No `require`. `node:` prefix for builtins (`node:fs`, `node:path`, `node:crypto`). Relative imports include `.js` extension.

**No `utils.ts` / `helpers.ts` dumping grounds.** Each file is one concern. New concerns get their own file.

**Module-level constants in TypeScript use `SHOUT_CASE`.** Function-local constants and exported bindings used as values follow `camelCase`. Numeric/string knobs at the top of a file are `SHOUT_CASE` (`DEFAULT_PORT`, `SCROLLBACK_CAP`, `MAX_FILE_BYTES`).

**Never duplicate the version string.** `package.json`'s `version` field is the single source of truth. `runtimeInfo.ts` reads it at boot; the handshake response uses the same value. No file hard-codes `"0.1.0"` etc.

### Module boundaries inside backend

```
index.ts        bootstrap; reads no protocol, sees no PTY
config.ts       token + recents persistence; no transport
runtimeInfo.ts  atomic runtime.json write; no transport
connection.ts   the ONLY file that knows WebSocket framing; thin
                lifecycle wrapper that forwards parsed RPC objects
                to rpc.ts
rpc.ts          method table + per-method param validation + error
                code mapping + handler bodies. Speaks JSON-RPC
                objects, knows nothing about the transport.
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

**Single source of truth: `AppState`.** All **server-derived state** lives in `AppState`, regardless of how many screens consume it today. That includes connection state, workspace lists, file tree caches, picker entry caches, terminal sessions, bootstrap results — anything that arrived via an RPC or notification. Local-only UI state (`TextEditingController`, scroll position, "is this sheet expanded") stays in widget `State`. The two persistence singletons (`SettingsStore` over SharedPreferences; `BackendClient` as the RPC dialer) are the only other places state can live. If `AppState` outgrows one file, split it into composed sub-notifiers, not into widget-local caches.

**One Navigator.** All routes go through the root Navigator. No nested navigators, no tab-internal navigation stacks. Deep transitions: `Navigator.push(MaterialPageRoute(...))`.

**Network through `BackendClient` ↔ `AppState` ↔ screen.** Screens never call `WebSocket.connect`, `http.get`, or `BackendClient` methods directly. The dependency chain is one-way: screens depend on `AppState`; `AppState` depends on `BackendClient`. Screens that need connection status, last error, etc., read them from `AppState` — `BackendClient`'s internals (`client.state`, `client.lastError`) are not a public surface. New RPC methods land in `BackendClient` first, get exposed through `AppState` second, get consumed by screens third.

**Widget statefulness is local UI state only.** A widget is `StatefulWidget` only if it owns a `TextEditingController`, a `ScrollController`, an animation, or a transient "is this sheet expanded" boolean. A widget that `setState`s after a backend call is a bug — that data belongs in `AppState`. The reviewer's quick test: if you removed and re-mounted the widget tree right now, would the state survive? If yes, it's in `AppState`. If no, and it shouldn't (e.g. scroll position), it's allowed.

**Material 3 by default.** Use `FilledButton`, `OutlinedButton`, `ListTile`, `ChoiceChip`, `Card` — don't hand-roll equivalents. A single `seedColor` on the theme is allowed (chrome identity); deeper customization (custom `colorScheme`, bespoke component themes, custom typography) is not. Colors come from `Theme.of(context).colorScheme.*` (e.g. `error`, `primary`, `secondary`) — never hard-code `Colors.red` / `Colors.green` etc.

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

## 9. Settled opinionated calls

These were judgment calls. Recording them so they don't get re-debated every PR.

| § | Decision | Reasoning |
|---|---|---|
| 1 | Dispatch lives in `rpc.ts`, not in `connection.ts` | Transport-agnostic dispatcher; testable without a WebSocket; framing and method routing are different concerns |
| 2 | No state-management framework (`ChangeNotifier` only) | Smaller surface, fewer rebuild-trap landmines; can adopt Riverpod later if it ever hurts |
| 2 | All server-derived state is in `AppState`, not in widgets | One subscription surface; survives screen rebuilds; the "is it server-side?" check is unambiguous |
| 2 | Material 3, seed color allowed, deeper theming deferred | Mild chrome identity has no cost; full theming waits for a designer |
| 2 | English-only strings, no `intl` in v0 | i18n touches every screen; do it once, not piecemeal |
| 3 | `network` capability whitelists are exact hosts, no wildcards | Conservative default; widens later if a real plugin needs it |
| 4 | SharedPreferences keys are kebab-case (`server-host`, `bearer-token`) | No legacy migration — renames break existing installs; we accept that for v0 |
| 6 | No FS / PTY mocks | Real thing is fast enough; mock drift is the main test-failure mode in CI |

Flip any of these by editing this row and the corresponding section. Don't argue with a settled call in a code review — argue in this file.
