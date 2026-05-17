# openvsmobile-next backend

Node / TypeScript backend for the mobile code workbench. One persistent
WebSocket at `/rpc` carries JSON-RPC 2.0; everything that streams (terminal
output, workspace deltas) is a notification, never a polled request. See
`docs/design/mobile-code-platform.md` §4.1 for the full wire contract.

## Local development

```bash
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test           # vitest, real git in temp dirs
pnpm dev            # tsx — picks up source edits live
```

`pnpm dev` writes a runtime file at
`~/.local/state/openvsmobile-next/runtime.json` (mode 0600) with the bound
port + bearer token. The smoke script reads it automatically.

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
