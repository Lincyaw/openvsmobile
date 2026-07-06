# openvsmobile-next backend

Node / TypeScript backend for the mobile code workbench. One persistent
JSON-RPC stream carries the app protocol; the default transport is a
WebSocket at `/rpc`, and an optional Iroh bidirectional stream can expose
the same protocol for NAT-traversed remote access. Everything that streams
(terminal output, workspace deltas) is a notification, never a polled
request. See `docs/design/mobile-code-platform.md` §4.1 for the full wire
contract.

## Local development

```bash
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test           # vitest, real git in temp dirs
pnpm dev            # tsx — picks up source edits live
```

`pnpm dev` writes a runtime file at
`~/.local/state/openvsmobile-next/runtime.json` (mode 0600) with the bound
port + bearer token. When `OPENVSMOBILE_IROH=1` is set it also includes an
`iroh` object with `endpointId`, `ticket`, `alpn`, relay URL, and direct
addresses. The smoke script reads the WebSocket fields automatically.

## Node version

`package.json` pins `engines.node >= 25`. The release tarball bundles its
own Node 25 runtime so end users are unaffected. For local development on
Node 24:

- Preferred: `nvm use 25` (or `corepack` equivalent).
- Quick escape: add `engine-strict=false` to `.npmrc` and re-run
  `pnpm install`. Everything currently compiles and runs on Node 24, but
  this is a workaround — fix the engine version when convenient.

## Wire surface

See `docs/design/mobile-code-platform.md` §4.1 for the canonical reference.
Quick map:

- `auth.handshake`, `system.ping`
- `workspace.list` / `open` / `activate` / `close` / `current`
- `workspace.findFiles` (fuzzy file-name search, gitignore-aware, scope-safe)
- `workspace.subscribe` / `unsubscribe` (per-workspace push registration)
- `fs.listDir` (returns `{ entries, version }`; `version === 0` in picker mode)
- `fs.readFile` (accepts `ifEtag`; returns `{ etag, content }` or `{ etag, notModified: true }`)
- `terminal.create` / `write` / `resize` / `dispose` / `list` / `history`
- `git.diff` / `git.log`

Push notifications, all carrying a monotonic per-workspace `version`:

- `terminal.data` / `terminal.exit`
- `workspace.closed`
- `workspace.tree.delta` / `decoration.delta` / `head.changed` / `commit.added`
- `workspace.decoration.snapshot` (only after `subscribe` → `mode:"snapshot"`)

## Plugin host (issue C1)

- Discovery dir: `OPENVSMOBILE_PLUGINS_DIR` (default
  `~/.local/share/openvsmobile-next/plugins/`).
- Per-plugin stderr log: `~/.local/state/openvsmobile-next/plugins/<id>.stderr.log`
  (rotates at 5 MiB, one backup).
- `host.log({ level, msg })` is the only host method exposed in v0.
- Capability gate returns `RpcError -32011 capabilityNotDeclared`.
- `plugin.*` RPCs to the Flutter client are not wired yet (lands in C2).

See `docs/design/mobile-code-platform.md` §3 and §9a for what's live now
vs deferred.
