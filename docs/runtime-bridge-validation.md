# Runtime bridge validation

ASE-41's bridge foundation work is only useful if other developers can rerun the same checks without guessing tool paths or the OpenVSCode working directory. This document defines the repo-local validation flow and the prerequisite gates behind it.

## Prerequisites

Required for the bridge foundation helper:

- `go` in `PATH`, or `GO_BINARY=/absolute/path/to/go`
- `node` and `npm` in `PATH`
- `openvscode-server/` checked out in this repo
- `openvscode-server` dependencies installed with `cd openvscode-server && npm install` (or `npm ci`)

Optional for the gated restart integration check:

- `VSCODE_INTEGRATION_TEST=1`
- a compiled OpenVSCode server at `openvscode-server/out/server-main.js`

Optional for repo-wide Flutter targets:

- a runnable Flutter binary in `PATH`, or an explicit override such as `make FLUTTER=/absolute/path/to/flutter test`

## Canonical commands

Compile only the built-in bridge extension from the `openvscode-server/` root:

```bash
make verify-bridge-extension
```

Run the full bridge foundation validation helper:

```bash
make verify-bridge-foundation
```

The helper lives at `scripts/verify_bridge_foundation.sh` and runs these checks in order:

1. validates required toolchain and `openvscode-server` dependency prerequisites
2. compiles `mobile-runtime-bridge` from the `openvscode-server/` root
3. runs targeted Go bridge tests in `server/internal/vscode` and `server/internal/api`
4. runs `go vet ./...` in `server/`
5. runs `make test` and `make lint` when Flutter is available through the repo's normal discovery rules
6. optionally runs `TestIntegration_BridgeLifecycle_EndToEnd` when `VSCODE_INTEGRATION_TEST=1`

## Gated checks

The helper intentionally separates always-on checks from heavier environment-gated validation:

- The bridge extension compile, targeted Go tests, and `go vet` are mandatory.
- Repo-wide `make test` and `make lint` run automatically when Flutter is available; otherwise the helper logs the missing prerequisite and leaves a deterministic rerun command.
- The restart end-to-end integration test is gated because it needs a compiled OpenVSCode server and the `VSCODE_INTEGRATION_TEST=1` opt-in used by the existing integration suite.
- Full repo targets such as `make test` and `make lint` fail fast with a setup hint instead of assuming a machine-specific SDK path.

## Flutter path resolution

The root `Makefile` resolves Flutter in this order:

1. `make FLUTTER=/absolute/path/to/flutter <target>`
2. `flutter` discovered in `PATH`
3. `${HOME}/flutter/bin/flutter`
4. `${HOME}/flutter-sdk/flutter/bin/flutter`
5. `/home/faydev/flutter-sdk/flutter/bin/flutter`

If none of those locations work, Flutter-backed targets stop immediately with a message that explains how to provide an explicit override.
