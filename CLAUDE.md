# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## What this project is

A Flutter Android client for talking to a workspace-bound "main Claude Code" instance, paired with a Go server that wraps the Claude Code CLI and forwards file/git/diagnostics/workspace operations to OpenVSCode Server. The user's working model is: chat with the main Claude Code on the phone → it publishes GitHub issues / merges PRs → [workbuddy](https://github.com/Lincyaw/workbuddy) worker nodes execute the actual coding work. The mobile app is a chat + observability surface, **not** a mobile IDE.

## Architecture

```
app/              — Flutter Android client (chat + read views)
server/           — Go server (Claude CLI wrapper + thin OpenVSCode forwarder
                    + local PTY for terminal)
openvscode-server/ — Git submodule: forked OpenVSCode Server
  └── extensions/openvsmobile-bridge/ — VSCode extension exposing runtime
                                        APIs (git, diagnostics, workspace,
                                        SSE event stream) over local HTTP.
```

### Design principle: forward, don't reimplement

If OpenVSCode Server already provides a feature **and exposes it through an API we can call**, forward to it rather than reimplement. Custom code is justified only for AI/Claude integration, workbuddy-specific orchestration, **and the terminal** (see decisions.md 2026-04-26: vscode.window.Terminal has no public stdout reader, so going through extension would mean reimplementing PTY in JS rather than forwarding — local PTY in Go is the right answer). The fork's role is to host the `openvsmobile-bridge` extension; **do not add new code to OpenVSCode core** — extend the extension instead.

### OpenVSCode Server submodule
- Origin: https://github.com/Lincyaw/openvscode-server.git (fork)
- Upstream: https://github.com/gitpod-io/openvscode-server.git
- Sync workflow: `cd openvscode-server && git fetch upstream && git merge upstream/main`
- Native IPC channels the Go server consumes:
  - `REMOTE_FILE_SYSTEM_CHANNEL_NAME` — file read/write/watch
- `extensions/openvsmobile-bridge/` is a zero-deps Node extension that activates on startup, binds an HTTP server on `127.0.0.1:0`, and writes runtime info to `~/.config/openvscode-mobile/bridge-runtime.json` (override env: `OPENVSCODE_MOBILE_BRIDGE_INFO_PATH`). All routes require `Authorization: Bearer <token>`. Endpoints: `/git/*` (delegates to `git.bridge.*` VS Code commands in `extensions/git/src/bridgeApi.ts`), `/diagnostics`, `/workspace/{folders,findFiles,findText}`, `/healthz`. The Go server reads the runtime info file on startup and forwards.
- Terminal is **deliberately not** forwarded to the extension. See decisions.md 2026-04-26.

### Flutter client (app/)
- Bottom navigation: **Files, Terminal, Chat, Git, More** (5 tabs)
- Workspace management: switch between project directories, persisted recent list (SharedPreferences)
- Read-only code viewer with syntax highlighting (selection → AI chat context)
- Terminal: local PTY shell with ANSI color rendering
- Git status + diff (read-mostly; write actions are increasingly handed to chat)
- AI chat: select code region → send to Claude with file:lines context
- Full-screen AI chat: chat-app style, tool-use cards, thinking blocks, session history browser
- More tab: GitHub Connection (device-flow auth for workbuddy), Settings (server URL + token), About

### Go server (server/)
- Claude CLI process manager: spawns `claude --verbose --input-format stream-json --output-format stream-json`, relays via WebSocket
- Claude session index: reads `~/.claude/sessions/` + `~/.claude/projects/` for conversation metadata
- File system: forwards to OpenVSCode `remoteFilesystem` channel
- **Bridge client (`internal/bridge/`)**: HTTP client that reads `bridge-runtime.json` and forwards to the openvsmobile-bridge extension. Failures return `bridge_unavailable` 503 — no local fallback by design.
- Git: forwarded to bridge → `git.bridge.*` commands. URLs: `/bridge/git/*` (genuine bridge, retained).
- Workspace: forwarded to bridge → workspace folders/findFiles/findText. Endpoints: `/api/workspace/{folders,findFiles,findText}`. No Flutter UI consumer today; intended for programmatic use (main Claude Code, workbuddy).
- Terminal: **local** PTY (`internal/terminal/`) — by design (decisions.md 2026-04-26). URLs: `/api/terminal/{create,attach,resize,close,rename,split,sessions}` REST and `/ws/terminal/{id}` WebSocket.
- Bridge events: extension SSE → Go `EventStream` → `/bridge/ws/events` WebSocket. Carries `git.repositoryChanged`, `diagnostics.changed`, and `terminal.session.{created,updated,closed}`. ONE WebSocket connection per Flutter client; `BridgeEventsClient` fans out to providers via `.on()` registry.
- GitHub auth: device-flow only (4 endpoints under `/github/auth/*`). Token consumed primarily by workbuddy. The github package is auth-only — no PR/issue/repo-context endpoints.
- REST + WebSocket API for the Flutter client

### Removed scope (do not reintroduce without discussion)
- On-device source editing (CodeEditor widget, LSP RPC plumbing)
- Bridge document sync protocol, capabilities discovery, lifecycle event stream — replaced by the openvsmobile-bridge extension
- GitHub PR/issue browsing UI (collaboration screens, repo-context backend) — handled in workbuddy + chat
- Custom IPC channels in OpenVSCode core (`mobileRuntimeBridgeChannel.ts`, `mobileRuntimeTerminalChannel.ts`) — replaced by the in-tree extension to keep upstream merges clean
- Search UI + `/api/search` endpoint — users ask Claude to find things
- `/api/diagnostics` REST endpoint — extension still emits `diagnostics.changed` events for future consumption
- `FileWatcher` / `FileWatchHub` / `/ws/files` — never broadcasted anything

<!-- auto-harness:begin -->
## Project conventions

- Flutter: latest stable SDK, latest Android API target
- Go: latest stable version, Go modules
- Package management: `flutter pub get` (Dart), `go mod tidy` (Go)
- Formatting: `dart format` (Dart), `gofmt` (Go)
- Testing: `flutter test` (Dart), `go test ./...` (Go)
- Validation gate: `flutter analyze` + `go vet ./...` must pass before committing
- Language: discussion in Chinese, code/comments/docs in English

## Active skills

- dev-loop — implement → test → vibe-verify → AI-review → measure → keep/discard
- north-star — quantifiable optimization targets with observation mechanisms
- long-horizon — autonomous decision-making with escalation ladder (L1-L5)

## North-star targets

1. **Spec coverage** — 100% of active requirements at `tested` status
   Measure: `python ~/.autoharness/domains/softdev/scripts/validate_index.py project-index.yaml`
   Note: `dropped` REQs are excluded from the denominator.

2. **Build health** — Flutter APK + Go binary both build successfully
   Measure: `cd server && go build ./... && cd ../app && flutter build apk`

3. **Test health** — 100% pass rate, all implemented requirements have tests
   Measure: `cd server && go test ./... && cd ../app && flutter test`

4. **Code health** — zero warnings from static analysis
   Measure: `flutter analyze && cd server && go vet ./...`

Secondary: simpler code that maps clearly to requirements > clever abstractions. Forwarding to OpenVSCode > reimplementing.
<!-- auto-harness:end -->
