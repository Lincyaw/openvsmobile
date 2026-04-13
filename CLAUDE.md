# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## What this project is

A Flutter-based Android client for OpenVSCode Server (Gitpod), paired with a Go server binary that wraps Claude Code CLI and provides session history access. The goal is a mobile-friendly code browsing and AI-assisted review experience.

## Architecture

```
app/              — Flutter Android client
server/           — Go server binary (Claude Code wrapper + session index)
openvscode-server/ — Git submodule: forked OpenVSCode Server (Gitpod)
```

### OpenVSCode Server submodule
- Origin: git@github.com:Lincyaw/openvscode-server.git (fork)
- Upstream: https://github.com/gitpod-io/openvscode-server.git
- Sync workflow: `cd openvscode-server && git fetch upstream && git merge upstream/main`
- Communication protocol: Custom IPC over WebSocket (not REST). Key channels:
  - `REMOTE_FILE_SYSTEM_CHANNEL_NAME` — file read/write/watch
  - `REMOTE_TERMINAL_CHANNEL_NAME` — terminal/PTY access
  - `RemoteAgentEnvironmentChannel` — server environment info
  - LSP runs inside extension host on server side (language extensions run remotely)
- May need modifications to expose additional APIs for the Flutter client

### Flutter client (app/)
- Code file browser with syntax highlighting and LSP support (via OpenVSCode Server)
- Project-level file management
- Simple code editing (mobile-optimized, no advanced editor features)
- Git status and diff viewer
- AI chat: select code region → send to Claude → conversational review
- Full-screen AI chat view (chat-app style) with clickable references to files/edits

### Go server (server/)
- Process manager: spawn/manage `claude` CLI processes, WebSocket relay of stream-json
- Session index: scan `~/.claude/sessions/` + `~/.claude/projects/` for conversation metadata
- JSONL parser: structured message list API with file-operation block annotations
- REST + WebSocket API for the Flutter client

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

1. **Spec coverage** — 100% of active requirements at `tested` status (currently: 0%)
   Measure: `python ~/.autoharness/domains/softdev/scripts/validate_index.py project-index.yaml`

2. **Build health** — Flutter APK + Go binary both build successfully (currently: Go builds OK, Flutter unmeasured)
   Measure: `cd server && go build ./... && cd ../app && flutter build apk`

3. **Test health** — 100% pass rate, all implemented requirements have tests (currently: Go tests pass, Flutter smoke test needs fixing)
   Measure: `cd server && go test ./... && cd ../app && flutter test`

4. **Code health** — zero warnings from static analysis (currently: go vet OK, flutter analyze OK)
   Measure: `flutter analyze && cd server && go vet ./...`

Secondary: simpler code that maps clearly to requirements > clever abstractions.
<!-- auto-harness:end -->
