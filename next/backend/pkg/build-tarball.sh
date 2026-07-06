#!/usr/bin/env bash
# Build a self-contained tarball of the openvsmobile-next backend.
#
# Output:
#   <output_dir>/openvsmobile-backend-linux-<arch>.tar.gz
#   <output_dir>/openvsmobile-backend-linux-<arch>.tar.gz.sha256
#
# The tarball bundles a portable Node 25 runtime, the compiled JS, the
# production node_modules tree (with the native node-pty prebuild for the
# target arch), and a thin launch.sh. The result must be runnable on a
# fresh linux-<arch> host with no extra dependencies.
#
# Cross-target works because node-pty publishes prebuilt binaries; we set
# npm_config_target_{arch,platform} so npm pulls the right one.

set -euo pipefail

# ----- constants -----
NODE_VERSION="v25.9.0"
NODE_DIST_BASE="https://nodejs.org/dist/${NODE_VERSION}"

# ----- usage / args -----
usage() {
  cat <<'EOF'
Usage: build-tarball.sh <arch> [<output_dir>]

Args:
  arch         Target CPU architecture. One of: x64, arm64
  output_dir   Directory to write the tarball + sha256 file
               (default: next/backend/dist-pkg/)

Flags:
  -h, --help   Show this help and exit

The script must run on a linux-x64 host. Cross-targeting arm64 works
because node-pty ships prebuilt binaries; the npm install is driven with
npm_config_target_arch / npm_config_target_platform so the right native
binary is downloaded into node_modules.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  echo "error: missing <arch>" >&2
  usage >&2
  exit 2
fi

ARCH="$1"
case "$ARCH" in
  x64|arm64) ;;
  *)
    echo "error: unsupported arch '$ARCH' (want x64 or arm64)" >&2
    exit 2
    ;;
esac

# Repo paths (this script lives at next/backend/pkg/build-tarball.sh).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_OUT="$BACKEND_DIR/dist-pkg"
OUTPUT_DIR="${2:-$DEFAULT_OUT}"
CACHE_DIR="$BACKEND_DIR/dist-pkg/.cache"
STAGING_ROOT="$BACKEND_DIR/dist-pkg/.stage-${ARCH}"

mkdir -p "$OUTPUT_DIR" "$CACHE_DIR"

log() { printf '[build-tarball] %s\n' "$*" >&2; }

# ----- 1. Validate arch (done) and prepare staging -----
log "target: linux-${ARCH}"
log "backend: $BACKEND_DIR"
log "output:  $OUTPUT_DIR"

rm -rf "$STAGING_ROOT"
mkdir -p "$STAGING_ROOT"

# ----- 2. Download portable Node -----
NODE_TARBALL="node-${NODE_VERSION}-linux-${ARCH}.tar.xz"
NODE_URL="${NODE_DIST_BASE}/${NODE_TARBALL}"
CACHED_NODE="$CACHE_DIR/$NODE_TARBALL"

if [[ ! -f "$CACHED_NODE" ]]; then
  log "downloading $NODE_URL"
  curl -fsSL --retry 3 -o "$CACHED_NODE.part" "$NODE_URL"
  mv "$CACHED_NODE.part" "$CACHED_NODE"
else
  log "using cached node: $CACHED_NODE"
fi

# Extract into a per-arch dir so re-runs don't pollute each other.
NODE_EXTRACT="$STAGING_ROOT/.node-extract"
mkdir -p "$NODE_EXTRACT"
tar -xf "$CACHED_NODE" -C "$NODE_EXTRACT"
NODE_HOME="$NODE_EXTRACT/node-${NODE_VERSION}-linux-${ARCH}"
if [[ ! -x "$NODE_HOME/bin/node" ]]; then
  log "error: node binary not found at $NODE_HOME/bin/node"
  exit 1
fi

# ----- 3. Install production deps for target arch -----
# The repo's authoritative lockfile is pnpm-lock.yaml (lockfileVersion 9.0).
# Using `npm install --no-package-lock` would silently ignore it and risk
# installing drifted versions, so we use pnpm with --frozen-lockfile.
#
# --config.node-linker=hoisted asks pnpm to produce a flat node_modules
# (the layout npm/yarn-classic produce), not pnpm's default
# .pnpm/<symlinked> store. That matters because the portable Node bundled
# into the tarball must be able to resolve every dep with plain CommonJS
# resolution — no pnpm runtime, no symlink farm to repoint.
#
# TODO: consider adding a `packageManager` field to package.json so CI
# pins the exact pnpm version (e.g. via corepack) for reproducible builds.
if ! command -v pnpm >/dev/null 2>&1; then
  echo "error: pnpm required (install via 'corepack enable' or npm i -g pnpm)" >&2
  exit 7
fi
log "pnpm: $(pnpm --version)"

BUILD_DIR="$STAGING_ROOT/build"
mkdir -p "$BUILD_DIR"
cp "$BACKEND_DIR/package.json" "$BUILD_DIR/"
if [[ ! -f "$BACKEND_DIR/pnpm-lock.yaml" ]]; then
  echo "error: pnpm-lock.yaml not found in $BACKEND_DIR (required by --frozen-lockfile)" >&2
  exit 1
fi
cp "$BACKEND_DIR/pnpm-lock.yaml" "$BUILD_DIR/"
if [[ -d "$BACKEND_DIR/scripts" ]]; then
  cp -R "$BACKEND_DIR/scripts" "$BUILD_DIR/"
fi
# pnpm 11+ reads `allowBuilds:` from pnpm-workspace.yaml to decide which
# packages may run install scripts. Without this file pnpm refuses to
# compile node-pty's native binding and the tarball ships broken.
if [[ -f "$BACKEND_DIR/pnpm-workspace.yaml" ]]; then
  cp "$BACKEND_DIR/pnpm-workspace.yaml" "$BUILD_DIR/"
fi

# The backend depends on `@openvsmobile/sdk` via `workspace:*`, so pnpm
# will materialise it as a symlink into `packages/sdk`. Stage the SDK
# alongside (with its TypeScript already compiled) so the symlink
# resolves during install; we'll replace it with a real copy below.
if [[ -d "$BACKEND_DIR/packages/sdk" ]]; then
  log "building @openvsmobile/sdk"
  (
    cd "$BACKEND_DIR/packages/sdk"
    export PATH="$NODE_HOME/bin:$PATH"
    npm install --no-audit --no-fund --no-package-lock --no-save \
      typescript@5 @types/node@20 >/dev/null
    npx --no-install tsc
  )
  mkdir -p "$BUILD_DIR/packages"
  # `cp -R` follows the dist/runtime layout; we explicitly skip node_modules
  # from the SDK to keep it lean — the SDK has no runtime npm deps.
  rm -rf "$BUILD_DIR/packages/sdk"
  mkdir -p "$BUILD_DIR/packages/sdk"
  cp -R \
    "$BACKEND_DIR/packages/sdk/package.json" \
    "$BACKEND_DIR/packages/sdk/dist" \
    "$BACKEND_DIR/packages/sdk/runtime" \
    "$BACKEND_DIR/packages/sdk/src" \
    "$BUILD_DIR/packages/sdk/"
fi

log "installing production deps for linux-${ARCH} (pnpm, frozen lockfile, hoisted)"
(
  cd "$BUILD_DIR"
  # Front-load the bundled Node so pnpm and every lifecycle script run
  # under the same ABI the tarball ships. Without this, the host's Node
  # (e.g. v24 / NMV 137) drives prebuild-install and downloads native
  # binaries built for the wrong NODE_MODULE_VERSION; the tarball
  # extracts cleanly but blows up on `require('better_sqlite3.node')` at
  # runtime under the bundled v25 / NMV 141.
  export PATH="$NODE_HOME/bin:$PATH"
  # Cross-target env: node-pty and friends consult npm_config_target_arch
  # / npm_config_target_platform when downloading prebuilt natives. pnpm
  # propagates these to lifecycle scripts the same way npm does.
  # npm_config_target pins the ABI version so prebuild-install grabs the
  # binary that matches the bundled Node even if host Node differs.
  npm_config_target="${NODE_VERSION#v}" \
  npm_config_target_arch="$ARCH" \
  npm_config_target_platform="linux" \
    pnpm install \
      --prod \
      --frozen-lockfile \
      --node-linker=hoisted \
      --ignore-scripts=false
)

# Dereference the workspace `@openvsmobile/sdk` symlink into a real
# directory under node_modules. pnpm always materialises workspace deps as
# symlinks even with --node-linker=hoisted; the bundle is extracted to an
# arbitrary path on the target host without `packages/sdk/` alongside, so
# the symlink would dangle. Copy in the staged SDK and rewrite the link.
SDK_LINK="$BUILD_DIR/node_modules/@openvsmobile/sdk"
if [[ -L "$SDK_LINK" ]]; then
  log "materialising @openvsmobile/sdk into node_modules"
  rm "$SDK_LINK"
  cp -R "$BUILD_DIR/packages/sdk" "$SDK_LINK"
fi

# Sanity-check that the layout is actually relocatable. The bundle gets
# extracted to an arbitrary install path on the target host, so any symlink
# pointing into pnpm's content-addressed store (which lives outside the
# extraction root) is a bug. Relative symlinks that stay *inside*
# node_modules are fine — npm/yarn-classic both produce these for `.bin/`
# entries, and they resolve correctly post-relocation.
BAD_SYMLINKS=()
while IFS= read -r link; do
  target="$(readlink "$link")"
  # Absolute target → definitely points outside the bundle.
  if [[ "$target" = /* ]]; then
    BAD_SYMLINKS+=("$link -> $target (absolute)")
    continue
  fi
  # Relative target — resolve against the link's parent and confirm it
  # stays under $BUILD_DIR/node_modules.
  parent="$(dirname "$link")"
  resolved="$(cd "$parent" && readlink -f "$target" 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    # Dangling — bundle won't work either way.
    BAD_SYMLINKS+=("$link -> $target (dangling)")
    continue
  fi
  case "$resolved" in
    "$BUILD_DIR/node_modules"/*) ;;  # ok — stays inside
    *) BAD_SYMLINKS+=("$link -> $target (escapes node_modules)") ;;
  esac
done < <(find "$BUILD_DIR/node_modules" -type l || { echo "symlink scan failed" >&2; exit 1; })

if [[ ${#BAD_SYMLINKS[@]} -gt 0 ]]; then
  echo "error: pnpm produced symlinks under node_modules that escape the bundle:" >&2
  printf '  %s\n' "${BAD_SYMLINKS[@]:0:10}" >&2
  exit 1
fi

# ----- 4. Compile TypeScript -----
log "compiling TypeScript"
COMPILE_DIR="$STAGING_ROOT/compile"
mkdir -p "$COMPILE_DIR"
cp -R "$BACKEND_DIR/src" "$COMPILE_DIR/"
cp "$BACKEND_DIR/tsconfig.json" "$COMPILE_DIR/"
# Strip `workspace:*` deps from the compile-step package.json — npm
# (used here to fetch typescript) rejects them with EUNSUPPORTEDPROTOCOL.
# The backend source doesn't import `@openvsmobile/sdk` at TS level
# (it's loaded by plugin child processes via runtime resolve), so tsc
# is fine without it on the typeRoots.
node -e "
  const fs = require('fs');
  const pkg = require('$BACKEND_DIR/package.json');
  for (const field of ['dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies']) {
    const obj = pkg[field];
    if (!obj) continue;
    for (const k of Object.keys(obj)) {
      if (typeof obj[k] === 'string' && obj[k].startsWith('workspace:')) delete obj[k];
    }
  }
  delete pkg.scripts;
  fs.writeFileSync('$COMPILE_DIR/package.json', JSON.stringify(pkg, null, 2) + '\n');
"
# We use the project's own typescript devDep — install it locally for
# the compile step only (small, doesn't end up in the tarball).
(
  cd "$COMPILE_DIR"
  export PATH="$NODE_HOME/bin:$PATH"
  npm install --no-audit --no-fund --no-package-lock --no-save typescript@5 >/dev/null
  npx --no-install tsc
)

# ----- 5. Assemble layout -----
VERSION="$(node -e "process.stdout.write(require('$BACKEND_DIR/package.json').version)")"
BUNDLE_DIR="$STAGING_ROOT/openvsmobile-backend"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

# Portable Node — we only need bin/node and the small set of files it
# resolves at runtime (include/, lib/, share/ are unused; keep just bin/).
# Bundle ONLY bin/node to keep the tarball small; node has no shared-lib
# dependencies inside its own tree.
mkdir -p "$BUNDLE_DIR/node/bin"
cp "$NODE_HOME/bin/node" "$BUNDLE_DIR/node/bin/node"

# Compiled JS
cp -R "$COMPILE_DIR/dist" "$BUNDLE_DIR/dist"

# Production node_modules
cp -R "$BUILD_DIR/node_modules" "$BUNDLE_DIR/node_modules"

# CLI tools (mobile-notify et al). Single-file ESM scripts with no dependency
# on the compiled dist/. Most import only node:* builtins; pairing QR rendering
# also resolves qrcode-terminal from the production node_modules copied above.
# Users invoke them directly with the bundled portable Node:
#   ~/.local/share/openvsmobile/current/node/bin/node \
#       ~/.local/share/openvsmobile/current/bin/mobile-notify.mjs ...
# (install.sh symlinks bin/ onto $PATH; see docs/design §4.5.)
if [[ -d "$BACKEND_DIR/bin" ]]; then
  mkdir -p "$BUNDLE_DIR/bin"
  cp -R "$BACKEND_DIR/bin/." "$BUNDLE_DIR/bin/"
  # Ensure every script in bin/ is executable in the staged copy — git's
  # filemode bit may have been lost during checkout on some hosts.
  find "$BUNDLE_DIR/bin" -type f -name '*.mjs' -exec chmod +x {} +
fi

# Example plugins. install.sh seeds these into the user's plugins dir on
# first install so a fresh environment isn't a blank Plugins tab. The
# settled "filesystem-only install" decision still holds: the source of
# truth is the user's plugins dir; this just gives them a starter set
# they can delete. Bundle clock / notes / sysinfo — small, no npm deps,
# each exercises a different slice of the host (timer, fs read+write,
# os introspection). We never ship a plugin's node_modules even if one
# accidentally appears in-tree; the host SDK is injected at runtime.
EXAMPLES_SRC="$BACKEND_DIR/../examples/plugins"
EXAMPLES_DEST="$BUNDLE_DIR/share/example-plugins"
if [[ -d "$EXAMPLES_SRC" ]]; then
  mkdir -p "$EXAMPLES_DEST"
  for plugin in clock notes sysinfo; do
    src="$EXAMPLES_SRC/$plugin"
    if [[ ! -d "$src" ]]; then
      echo "error: example plugin '$plugin' missing at $src" >&2
      exit 1
    fi
    # rsync would be cleaner but isn't guaranteed on minimal CI runners;
    # fall back to cp + a defensive find to strip any node_modules.
    rm -rf "$EXAMPLES_DEST/$plugin"
    cp -R "$src" "$EXAMPLES_DEST/$plugin"
    find "$EXAMPLES_DEST/$plugin" -type d -name node_modules -prune -exec rm -rf {} +
  done
  log "bundled example plugins: clock notes sysinfo"
fi

# A "production-mode" package.json — same content, but stripped of
# devDependencies and scripts that aren't useful at runtime.
node -e "
  const fs = require('fs');
  const pkg = require('$BACKEND_DIR/package.json');
  delete pkg.devDependencies;
  pkg.scripts = { start: 'node dist/index.js' };
  fs.writeFileSync('$BUNDLE_DIR/package.json', JSON.stringify(pkg, null, 2) + '\n');
"

# VERSION file
printf '%s\n' "$VERSION" > "$BUNDLE_DIR/VERSION"

# launch.sh — resolves its own location so the unit file can use an
# absolute path through ~/.local/share/openvsmobile/current/launch.sh.
cat > "$BUNDLE_DIR/launch.sh" <<'LAUNCH'
#!/usr/bin/env bash
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$HERE/node/bin/node" "$HERE/dist/index.js" "$@"
LAUNCH
chmod +x "$BUNDLE_DIR/launch.sh"

# ----- 6. Pack -----
TARBALL_NAME="openvsmobile-backend-linux-${ARCH}.tar.gz"
TARBALL_PATH="$OUTPUT_DIR/$TARBALL_NAME"
log "creating $TARBALL_PATH"
tar -C "$STAGING_ROOT" -czf "$TARBALL_PATH" "openvsmobile-backend"

# ----- 7. Checksum -----
(
  cd "$OUTPUT_DIR"
  sha256sum "$TARBALL_NAME" > "${TARBALL_NAME}.sha256"
)

log "done: $TARBALL_PATH"
log "sha256: $(cut -d' ' -f1 "$OUTPUT_DIR/${TARBALL_NAME}.sha256")"

# stdout: print the produced tarball path so callers can chain.
echo "$TARBALL_PATH"
