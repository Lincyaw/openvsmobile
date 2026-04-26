# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## What this project is

A Flutter Android client for talking to a workspace-bound "main Claude Code" instance, paired with a Go server that wraps the Claude Code CLI and forwards file/terminal/git operations to OpenVSCode Server. The user's working model is: chat with the main Claude Code on the phone → it publishes GitHub issues / merges PRs → [workbuddy](https://github.com/Lincyaw/workbuddy) worker nodes execute the actual coding work. The mobile app is a chat + observability surface, **not** a mobile IDE.

## Architecture

```
app/              — Flutter Android client (chat + read views)
server/           — Go server (Claude CLI wrapper + thin OpenVSCode forwarder)
openvscode-server/ — Git submodule: forked OpenVSCode Server
  └── extensions/openvsmobile-bridge/ — VSCode extension exposing runtime
                                        APIs (currently vscode.git) over local
                                        HTTP. Future channels (terminal, LSP,
                                        workspace) iterate inside this extension.
```

### Design principle: forward, don't reimplement

If OpenVSCode Server already provides a feature (LSP, search, git, terminal, file watching), the mobile stack should **forward** to it rather than reimplement. Custom code is justified only for AI/Claude integration and workbuddy-specific orchestration. The fork's role is to host the `openvsmobile-bridge` extension; **do not add new code to OpenVSCode core** — extend the extension instead.

### OpenVSCode Server submodule
- Origin: git@github.com:Lincyaw/openvscode-server.git (fork)
- Upstream: https://github.com/gitpod-io/openvscode-server.git
- Sync workflow: `cd openvscode-server && git fetch upstream && git merge upstream/main`
- Native IPC channels the Go server consumes:
  - `REMOTE_FILE_SYSTEM_CHANNEL_NAME` — file read/write/watch
- `extensions/openvsmobile-bridge/` exposes `vscode.git` API over a local HTTP server; runtime info (port + token) is written to `~/.config/openvscode-mobile/git-runtime.json`. The Go server discovers the bridge by reading this file.

### Flutter client (app/)
- Bottom navigation: **Files, Terminal, Chat, Git** (4 tabs)
- Workspace management: switch between project directories, persisted recent list (SharedPreferences)
- Read-only code viewer with syntax highlighting (selection → AI chat context)
- Terminal: local PTY shell with ANSI color rendering
- Git status + diff (read-mostly; write actions are increasingly handed to chat)
- AI chat: select code region → send to Claude with file:lines context
- Full-screen AI chat: chat-app style, tool-use cards, thinking blocks, session history browser

### Go server (server/)
- Claude CLI process manager: spawns `claude --verbose --input-format stream-json --output-format stream-json`, relays via WebSocket
- Claude session index: reads `~/.claude/sessions/` + `~/.claude/projects/` for conversation metadata
- File system: forwards to OpenVSCode `remoteFilesystem` channel
- Terminal: local PTY (`internal/terminal/`) — to be migrated to OpenVSCode `remoteterminal` channel via the bridge extension
- Git: local `git` CLI (`internal/git/`) — to be migrated to read from `openvsmobile-bridge` extension over HTTP
- Diagnostics: shells out to `go vet`, `dart analyze`, etc. (pragmatic CLI approach, no LSP proxy)
- GitHub auth: device-flow only (workbuddy needs the token; UI for issues/PRs lives in workbuddy itself or the main Claude Code chat)
- REST + WebSocket API for the Flutter client

### Removed scope (do not reintroduce without discussion)
- On-device source editing (CodeEditor widget, LSP RPC plumbing)
- Bridge document sync protocol, capabilities discovery, lifecycle event stream — replaced by the openvsmobile-bridge extension approach
- GitHub PR/issue browsing UI (collaboration screens, repo-context backend) — handled in workbuddy + chat
- Custom IPC channels in OpenVSCode core (`mobileRuntimeBridgeChannel.ts`, `mobileRuntimeTerminalChannel.ts`) — replaced by the in-tree extension to keep upstream merges clean

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
