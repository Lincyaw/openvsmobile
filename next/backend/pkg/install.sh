#!/usr/bin/env bash
# Install or upgrade the openvsmobile-next backend as a systemd --user
# service. Intended to be either curl-piped from a release URL or fed
# via stdin over an SSH bootstrap.
#
# stdout contract: on success, exactly ONE line of JSON:
#   {"port":N,"token":"...","version":"X.Y.Z","linger":true|false}
# If Iroh was enabled, the JSON also includes `"iroh":{...}` from runtime.json.
# Everything else (progress, warnings, errors) is on stderr.

set -euo pipefail

# ----- defaults / constants -----
REPO_SLUG="Lincyaw/openvsmobile"
SHARE_ROOT="$HOME/.local/share/openvsmobile"
STATE_DIR="$HOME/.local/state/openvsmobile-next"
RUNTIME_INFO="$STATE_DIR/runtime.json"
CACHE_DIR="$HOME/.cache/openvsmobile"
UNIT_PATH="$HOME/.config/systemd/user/openvsmobile.service"
SERVICE_NAME="openvsmobile.service"
POLL_TIMEOUT_SECS=10
STOP_TIMEOUT_SECS=20

# ----- usage -----
usage() {
  cat <<'EOF'
Usage: install.sh <version> [--tarball <path>] [--dry-run-systemd] [--force]

Args:
  version       Release version without leading 'v' (e.g. 0.1.0).
                When --tarball is omitted, the tarball is downloaded from
                https://github.com/Lincyaw/openvsmobile/releases/download/v<version>/

Flags:
  --tarball <path>      Use a local tarball instead of downloading.
                        The matching .sha256 must sit next to it.
  --dry-run-systemd     Print the unit file to stderr, skip
                        daemon-reload / enable / start. Spawns a sandboxed
                        backend (HOME=mktemp) so it never touches the real
                        ~/.config/openvsmobile-next/ or ~/.local/state/.
                        Refuses to run if the real service is currently
                        active (use --force to override).
  --force               With --dry-run-systemd: proceed even when the real
                        service is active. With a real install: refresh an
                        existing same-version install directory.
  -h, --help            Show this help.

Env:
  GITHUB_MIRROR         Override the GitHub host used for release downloads.
                        Default: https://github.com. Examples:
                          GITHUB_MIRROR=https://ghproxy.com/https://github.com
                          GITHUB_MIRROR=https://gh.example.com
                        Useful when the GitHub releases CDN
                        (release-assets.githubusercontent.com) is slow or
                        blocked on the target host.
  OPENVSMOBILE_IROH=1   Persist optional Iroh remote transport into the
                        systemd unit. Related OPENVSMOBILE_IROH_* variables
                        present during install are persisted too.

Exit codes:
  0   success
  1   generic failure (e.g. backend never wrote runtime.json)
  2   argument error
  3   target not found (e.g. release tarball 404)
  5   conflict (e.g. dry-run requested while real service is active)
  7   missing dependency or unsupported environment

On success, stdout is exactly one JSON line:
  {"port":N,"token":"...","version":"X.Y.Z","linger":true|false}
  {"port":N,"token":"...","version":"X.Y.Z","linger":true,"iroh":{...}}
EOF
}

# ----- helpers -----
log() { printf '[install] %s\n' "$*" >&2; }
fatal() { printf '[install] error: %s\n' "${1:-unspecified error}" >&2; exit "${2:-1}"; }
need() {
  command -v "$1" >/dev/null 2>&1 || fatal "missing dependency: $1 (install it and retry)" 7
}

append_unit_env_if_set() {
  local key="$1" value escaped
  [[ -n "${!key+x}" ]] || return 0
  value="${!key}"
  [[ -n "$value" ]] || return 0
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    fatal "$key contains a newline; refusing to write invalid systemd Environment line" 2
  fi
  escaped="${value//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  UNIT_EXTRA_ENV+=$'\n'"Environment=\"$key=$escaped\""
}

pid_alive() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ "$pid" -gt 0 ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

service_main_pid() {
  local pid
  pid="$(systemctl --user show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$pid"
  else
    printf '0\n'
  fi
}

runtime_version() {
  local path="$1"
  grep -E '"version"[[:space:]]*:' "$path" 2>/dev/null | head -n1 | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true
}

runtime_pid() {
  local path="$1"
  grep -E '"pid"[[:space:]]*:' "$path" 2>/dev/null | head -n1 | sed -E 's/.*"pid"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/' || true
}

wait_service_stopped() {
  local deadline state pid
  deadline=$(( $(date +%s) + STOP_TIMEOUT_SECS ))
  while true; do
    state="$(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || true)"
    pid="$(service_main_pid)"
    if [[ "$state" != "active" && "$state" != "activating" ]] && ! pid_alive "$pid"; then
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      log "diagnostic: $SERVICE_NAME is still ${state:-unknown} (MainPID=${pid:-unknown}) after stop"
      return 1
    fi
    sleep 0.2
  done
}

runtime_ready() {
  local path="$1"
  local got_version got_pid
  [[ -f "$path" ]] || return 1
  got_version="$(runtime_version "$path")"
  if [[ "$got_version" != "$VERSION" ]]; then
    if [[ -n "$got_version" ]]; then
      log "ignoring stale runtime info: file reports version '$got_version', installer expects '$VERSION'"
    else
      log "ignoring malformed runtime info: missing version"
    fi
    rm -f "$path" 2>/dev/null || true
    return 1
  fi
  got_pid="$(runtime_pid "$path")"
  if ! pid_alive "$got_pid"; then
    log "ignoring stale runtime info: pid '${got_pid:-missing}' is not running"
    rm -f "$path" 2>/dev/null || true
    return 1
  fi
  return 0
}

install_agent_hooks() {
  local node_bin="$BUNDLE_DIR/node/bin/node"
  local installer="$BUNDLE_DIR/bin/install-agent-hooks.mjs"
  if [[ ! -x "$node_bin" || ! -x "$installer" ]]; then
    log "warn: agent hook installer missing from bundle; skipping"
    return 0
  fi
  if "$node_bin" "$installer" >&2; then
    log "agent Stop hook scan complete"
  else
    log "warn: agent Stop hook scan failed; backend install will continue"
  fi
}

# Download a URL to <dest>.part and atomically rename on success.
#
# Flags rationale:
#   --connect-timeout 15  fail the initial TCP/TLS handshake fast.
#   --max-time 900        absolute cap so a slow trickle can't hang forever.
#   --speed-time 30       any 30s window averaging below --speed-limit aborts,
#   --speed-limit 10240   so --retry actually kicks in on a stalled CDN
#                         (default --retry only fires on hard errors, not
#                         slow downloads — the original bug here).
#   --retry 3 --retry-all-errors
#                         retry on any failure class, including the timeouts
#                         above.
# Progress is intentionally NOT streamed: curl over an SSH exec channel sees
# a non-tty stderr and suppresses its progress meter anyway, and --progress-bar
# emits \r-overwritten lines that the Flutter client's LineSplitter would
# buffer indefinitely. We log byte size after each download instead.
dl() {
  local url="$1" dest="$2"
  log "downloading $url"
  if ! curl -fL \
      --connect-timeout 15 \
      --max-time 900 \
      --speed-time 30 \
      --speed-limit 10240 \
      --retry 3 \
      --retry-all-errors \
      -o "$dest.part" "$url"; then
    rm -f "$dest.part"
    return 1
  fi
  mv "$dest.part" "$dest"
  local sz
  sz="$(stat -c '%s' "$dest" 2>/dev/null || wc -c <"$dest")"
  log "downloaded $(basename "$dest") (${sz} bytes)"
}

# ----- args -----
VERSION=""
TARBALL_OVERRIDE=""
DRY_RUN_SYSTEMD=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --tarball)
      [[ $# -ge 2 ]] || { usage >&2; fatal "--tarball requires a path" 2; }
      TARBALL_OVERRIDE="$2"; shift 2 ;;
    --dry-run-systemd)
      DRY_RUN_SYSTEMD=1; shift ;;
    --force)
      FORCE=1; shift ;;
    -*)
      usage >&2; fatal "unknown flag: $1" 2 ;;
    *)
      if [[ -z "$VERSION" ]]; then
        VERSION="$1"; shift
      else
        usage >&2; fatal "unexpected positional argument: $1" 2
      fi
      ;;
  esac
done

[[ -n "$VERSION" ]] || { usage >&2; fatal "missing <version>" 2; }
# Strip an accidental leading 'v' to be forgiving.
VERSION="${VERSION#v}"
INSTALL_DIR="$SHARE_ROOT/v$VERSION"
CURRENT_LINK="$SHARE_ROOT/current"

# ----- detect arch -----
RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
  x86_64)  ARCH="x64"   ;;
  aarch64) ARCH="arm64" ;;
  *)
    fatal "unsupported architecture: $RAW_ARCH (need x86_64 or aarch64)" 7
    ;;
esac
log "arch: $ARCH ($RAW_ARCH)"

# ----- check deps -----
need curl
need tar
need sha256sum
need file
# systemctl in user mode — present on any systemd-based distro a non-root
# user can use. We don't require root.
if ! command -v systemctl >/dev/null 2>&1; then
  fatal "missing dependency: systemctl (need systemd --user)" 7
fi

# ----- dry-run vs real-unit conflict guard (B4) -----
if [[ "$DRY_RUN_SYSTEMD" -eq 1 ]] && [[ "$FORCE" -eq 0 ]]; then
  if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    fatal "real $SERVICE_NAME is currently active; --dry-run-systemd would spawn a parallel backend (use --force to override)" 5
  fi
fi

# ----- tarball acquisition -----
TARBALL_NAME="openvsmobile-backend-linux-${ARCH}.tar.gz"
SHA_NAME="${TARBALL_NAME}.sha256"

mkdir -p "$CACHE_DIR"

if [[ -n "$TARBALL_OVERRIDE" ]]; then
  [[ -f "$TARBALL_OVERRIDE" ]] || fatal "tarball not found: $TARBALL_OVERRIDE" 3
  TARBALL_PATH="$TARBALL_OVERRIDE"
  SHA_PATH="${TARBALL_OVERRIDE}.sha256"
  [[ -f "$SHA_PATH" ]] || fatal "matching sha256 not found: $SHA_PATH" 3
  log "using local tarball: $TARBALL_PATH"
else
  GH_HOST="${GITHUB_MIRROR:-https://github.com}"
  GH_HOST="${GH_HOST%/}"
  RELEASE_BASE="$GH_HOST/${REPO_SLUG}/releases/download/v${VERSION}"
  TARBALL_URL="$RELEASE_BASE/$TARBALL_NAME"
  SHA_URL="$RELEASE_BASE/$SHA_NAME"
  TARBALL_PATH="$CACHE_DIR/v${VERSION}-$TARBALL_NAME"
  SHA_PATH="$CACHE_DIR/v${VERSION}-$SHA_NAME"

  if [[ -n "${GITHUB_MIRROR:-}" ]]; then
    log "using GITHUB_MIRROR=$GH_HOST"
  fi

  if ! dl "$TARBALL_URL" "$TARBALL_PATH"; then
    fatal "failed to download tarball (release v$VERSION may not exist, or network is too slow — try setting GITHUB_MIRROR or pre-stage with --tarball)" 3
  fi
  if ! dl "$SHA_URL" "$SHA_PATH"; then
    fatal "failed to download .sha256 (try setting GITHUB_MIRROR or pre-stage with --tarball)" 3
  fi
fi

# ----- verify checksum -----
EXPECTED_HEX="$(awk '{print $1; exit}' "$SHA_PATH")"
[[ -n "$EXPECTED_HEX" ]] || fatal "could not parse sha256 file: $SHA_PATH"
ACTUAL_HEX="$(sha256sum "$TARBALL_PATH" | awk '{print $1}')"
if [[ "$EXPECTED_HEX" != "$ACTUAL_HEX" ]]; then
  fatal "sha256 mismatch: expected $EXPECTED_HEX, got $ACTUAL_HEX"
fi
log "sha256 verified: $ACTUAL_HEX"

# ----- ELF arch verification of bundled .node files (M1) -----
# Cross-target via npm_config_target_arch only redirects prebuild
# downloads; node-pty has no linux prebuilds, so it falls back to
# node-gyp rebuild against the BUILD host's toolchain. An x64 build host
# producing an "arm64" tarball would silently embed an x86-64 .node and
# crash on the target. Probe each native module before we commit to the
# install.
case "$ARCH" in
  x64)   EXPECTED_ELF="x86-64" ;;
  arm64) EXPECTED_ELF="aarch64" ;;
esac

PROBE_DIR="$(mktemp -d -t openvsmobile-probe.XXXXXX)"
# shellcheck disable=SC2064  # we want $PROBE_DIR expanded now, not later
trap "rm -rf '$PROBE_DIR'" EXIT
tar -xzf "$TARBALL_PATH" -C "$PROBE_DIR"
# Only inspect ELF binaries. node-pty's package ships `prebuilds/` dirs
# for darwin and win32 too (Mach-O / PE32+ files); those are never loaded
# on a linux host, so flagging their arch as "wrong" would be a false
# positive. The real risk is a linux .node compiled by node-gyp against
# the wrong toolchain, which lives at `node_modules/<pkg>/build/Release/*.node`.
mapfile -d '' -t ALL_NODE_FILES < <(find "$PROBE_DIR" -name '*.node' -print0)
ELF_NODE_FILES=()
for nf in "${ALL_NODE_FILES[@]}"; do
  if file -b "$nf" | grep -q '^ELF '; then
    ELF_NODE_FILES+=("$nf")
  fi
done
if [[ ${#ELF_NODE_FILES[@]} -eq 0 ]]; then
  log "warn: no linux ELF .node files in tarball — node-gyp cross-compile likely failed silently"
else
  for nf in "${ELF_NODE_FILES[@]}"; do
    desc="$(file -b "$nf")"
    if ! grep -q "$EXPECTED_ELF" <<<"$desc"; then
      fatal "native module $nf is not $EXPECTED_ELF (got: $desc); cross-compile produced a wrong-arch binary"
    fi
  done
  log "verified ${#ELF_NODE_FILES[@]} linux native module(s) match $EXPECTED_ELF"
fi

# ----- stop running service BEFORE swapping anything (B1) -----
# `systemctl --user enable --now` is a no-op when the service is already
# active, so an upgrade flips `current` to a new tree while the old node
# process keeps running. Worse, it might resolve some new files via the
# symlink at runtime. Always stop first; ignore failures (unit may not be
# loaded yet on a first install). `stop` also cancels a pending restart
# job, which matters after a crash loop: `is-active` may already be false
# while systemd still has a restart queued that can rewrite old runtime.json.
if [[ "$DRY_RUN_SYSTEMD" -eq 0 ]]; then
  log "stopping $SERVICE_NAME before upgrade"
  systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  wait_service_stopped || fatal "$SERVICE_NAME did not stop within ${STOP_TIMEOUT_SECS}s"
  systemctl --user reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

# ----- extract (idempotent) -----
mkdir -p "$SHARE_ROOT"

EXISTING_VERSION_FILE="$INSTALL_DIR/openvsmobile-backend/VERSION"
if [[ -f "$EXISTING_VERSION_FILE" ]]; then
  EXISTING="$(head -n1 "$EXISTING_VERSION_FILE" || true)"
  if [[ "$EXISTING" == "$VERSION" ]]; then
    if [[ -n "$TARBALL_OVERRIDE" || "$FORCE" -eq 1 ]]; then
      # Local tarball installs are commonly used by SSH bootstrap and dev
      # upgrades before a new release tag exists. In that path, same version
      # does not imply same contents, so refresh the directory after the
      # service has stopped.
      log "refreshing existing install at $INSTALL_DIR (VERSION=$EXISTING)"
      rm -rf "$INSTALL_DIR"
    else
      log "already installed at $INSTALL_DIR (VERSION=$EXISTING), skipping extraction"
    fi
  else
    # Now safe to wipe: the service is stopped (we did that above) so the
    # node process isn't holding open files in this tree.
    log "stale install dir ($EXISTING != $VERSION); reinstalling"
    rm -rf "$INSTALL_DIR"
  fi
fi

if [[ ! -f "$EXISTING_VERSION_FILE" ]]; then
  log "extracting to $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  tar -xzf "$TARBALL_PATH" -C "$INSTALL_DIR"
fi

BUNDLE_DIR="$INSTALL_DIR/openvsmobile-backend"
LAUNCH_SCRIPT="$BUNDLE_DIR/launch.sh"
[[ -x "$LAUNCH_SCRIPT" ]] || fatal "launch.sh missing or not executable at $LAUNCH_SCRIPT"

# ----- atomic symlink current -> install dir -----
TMP_LINK="$SHARE_ROOT/.current.tmp.$$"
ln -snf "$INSTALL_DIR" "$TMP_LINK"
mv -Tf "$TMP_LINK" "$CURRENT_LINK"
log "current -> $INSTALL_DIR"

# ----- seed example plugins on first install -----
# A fresh environment otherwise lands on an empty Plugins tab. We bundle
# clock / notes / sysinfo in the tarball under share/example-plugins/ and
# copy them into the user's plugins dir the FIRST time install.sh runs,
# but never on subsequent runs — so removing a plugin sticks across
# upgrades. The settled "filesystem-only install" decision (CLAUDE.md)
# is preserved: the user's plugins dir remains the single source of
# truth; this just gives them a non-empty starter set on a host they've
# never installed to before.
#
# "First install" is detected via a sentinel file (.seeded) inside the
# plugins dir. Without it, "delete clock/" would re-seed clock on the
# next upgrade; with it, the seed runs at most once per plugins dir.
PLUGINS_DIR="${OPENVSMOBILE_PLUGINS_DIR:-$HOME/.local/share/openvsmobile-next/plugins}"
EXAMPLES_DIR="$BUNDLE_DIR/share/example-plugins"
SENTINEL="$PLUGINS_DIR/.seeded"
if [[ -d "$EXAMPLES_DIR" ]]; then
  should_seed=0
  if [[ ! -d "$PLUGINS_DIR" ]]; then
    should_seed=1
  elif [[ ! -e "$SENTINEL" ]] && [[ -z "$(ls -A "$PLUGINS_DIR" 2>/dev/null)" ]]; then
    # Pre-existing but empty plugins dir (e.g. user mkdir'd it themselves)
    # AND no prior seed marker → treat as first install.
    should_seed=1
  fi
  if [[ "$should_seed" -eq 1 ]]; then
    mkdir -p "$PLUGINS_DIR"
    # cp each top-level dir individually so a future addition to
    # share/example-plugins doesn't silently propagate to existing users.
    seeded=()
    for plugin in clock notes sysinfo; do
      if [[ -d "$EXAMPLES_DIR/$plugin" ]]; then
        cp -R "$EXAMPLES_DIR/$plugin" "$PLUGINS_DIR/"
        seeded+=("$plugin")
      fi
    done
    # Sentinel goes last so a crash mid-copy leaves the dir in the
    # "non-empty, not sentineled" state and the next run will retry.
    : > "$SENTINEL"
    if [[ ${#seeded[@]} -gt 0 ]]; then
      log "seeded example plugins into $PLUGINS_DIR: ${seeded[*]} — delete a subdir to uninstall (no re-seed on upgrade)"
    fi
  else
    log "plugins dir already initialised at $PLUGINS_DIR; skipping example seed"
  fi
fi

# ----- write systemd unit -----
mkdir -p "$(dirname "$UNIT_PATH")"
UNIT_EXTRA_ENV=""
for env_key in \
  OPENVSMOBILE_IROH \
  OPENVSMOBILE_IROH_ALPN \
  OPENVSMOBILE_IROH_BIND_ADDR \
  OPENVSMOBILE_IROH_RELAY_MODE \
  OPENVSMOBILE_IROH_RELAY_URLS \
  OPENVSMOBILE_IROH_SECRET_KEY \
  OPENVSMOBILE_IROH_ONLINE_TIMEOUT_MS \
  OPENVSMOBILE_IROH_MAX_FRAME_BYTES
do
  append_unit_env_if_set "$env_key"
done
UNIT_CONTENT=$(cat <<UNIT
[Unit]
Description=openvsmobile backend
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=%h/.local/share/openvsmobile/current/openvsmobile-backend/launch.sh
Environment=PORT=0
Environment=NODE_ENV=production
$UNIT_EXTRA_ENV
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT
)

# Track LINGER for the JSON-emit step regardless of branch.
LINGER=false

if [[ "$DRY_RUN_SYSTEMD" -eq 1 ]]; then
  log "--- BEGIN unit (dry-run) ---"
  printf '%s\n' "$UNIT_CONTENT" >&2
  log "--- END unit (dry-run) ---"
  log "dry-run: skipping daemon-reload/enable/start"

  # Sandbox the spawned backend so it never touches the real
  # ~/.config/openvsmobile-next/ or ~/.local/state/openvsmobile-next/.
  # config.ts uses homedir() directly, so the only reliable lever is HOME.
  DRY_HOME="$(mktemp -d -t openvsmobile-dryrun-home.XXXXXX)"
  DRY_RUNTIME="$DRY_HOME/.local/state/openvsmobile-next/runtime.json"
  mkdir -p "$(dirname "$DRY_RUNTIME")"
  # Compose a single EXIT trap that reaps the child AND tears down the
  # tempdir + the earlier $PROBE_DIR trap target.
  # shellcheck disable=SC2064  # intentional eager expansion
  trap "[[ -n \${BG_PID:-} ]] && kill -TERM \"\$BG_PID\" 2>/dev/null || true; wait \"\${BG_PID:-}\" 2>/dev/null || true; rm -rf '$PROBE_DIR' '$DRY_HOME'" EXIT

  log "spawning sandboxed backend (HOME=$DRY_HOME, runtime=$DRY_RUNTIME)"
  (
    cd "$BUNDLE_DIR"
    HOME="$DRY_HOME" \
    PORT=0 \
    NODE_ENV=production \
    OPENVSMOBILE_RUNTIME_INFO_PATH="$DRY_RUNTIME" \
      exec "$LAUNCH_SCRIPT"
  ) >"$DRY_HOME/.backend.log" 2>&1 &
  BG_PID=$!
  # From here on the poll loop reads from $DRY_RUNTIME instead of the
  # real $RUNTIME_INFO.
  POLL_TARGET="$DRY_RUNTIME"
else
  log "writing unit file: $UNIT_PATH"
  printf '%s\n' "$UNIT_CONTENT" > "$UNIT_PATH"

  # Enable lingering so the service survives logout (and starts at boot).
  # Linger requires either root or a polkit policy that permits the user.
  # We do NOT fail the install if this is denied — surface it in the
  # final JSON instead so the caller knows the service is session-bound.
  if loginctl enable-linger "$USER" >/dev/null 2>&1; then
    LINGER=true
    log "linger enabled for $USER"
  else
    log "warn: could not enable linger (non-root SSH without polkit?); service is session-bound"
  fi

  # Wipe any stale runtime.json from the previous version BEFORE start,
  # so the poll loop's "file appeared" signal unambiguously means "the new
  # process wrote it" (B2).
  rm -f "$RUNTIME_INFO"

  systemctl --user daemon-reload
  systemctl --user enable --now "$SERVICE_NAME" >/dev/null
  log "systemd unit enabled and started"
  POLL_TARGET="$RUNTIME_INFO"
fi

# ----- poll runtime.json -----
log "waiting for valid $POLL_TARGET (up to ${POLL_TIMEOUT_SECS}s)"
deadline=$(( $(date +%s) + POLL_TIMEOUT_SECS ))
while ! runtime_ready "$POLL_TARGET"; do
  if (( $(date +%s) >= deadline )); then
    if [[ "$DRY_RUN_SYSTEMD" -eq 1 ]]; then
      log "diagnostic backend log:"
      sed -e 's/^/  /' "$DRY_HOME/.backend.log" >&2 || true
      fatal "backend did not write valid $POLL_TARGET within ${POLL_TIMEOUT_SECS}s (dry-run)"
    fi
    log "diagnostic: 'systemctl --user status openvsmobile' may explain why"
    fatal "backend did not write valid $POLL_TARGET within ${POLL_TIMEOUT_SECS}s"
  fi
  sleep 0.2
done

# ----- install optional Claude Code / Codex Stop hooks -----
# This mutates real user agent configs, so keep dry-run hermetic.
if [[ "$DRY_RUN_SYSTEMD" -eq 0 ]]; then
  install_agent_hooks
else
  log "dry-run: skipping agent Stop hook scan"
fi

# ----- parse + emit single JSON line on stdout -----
# Prefer python3 — it can both parse the input and emit canonical JSON in
# one shot, avoiding any `read`/IFS round-trip that would break tokens
# containing whitespace (M4).
emit_via_python() {
  python3 - "$POLL_TARGET" "$VERSION" "$LINGER" <<'PY'
import json, sys
runtime_path, expected_version, linger = sys.argv[1:4]
with open(runtime_path) as f:
    d = json.load(f)
got_version = d.get("version")
if got_version != expected_version:
    sys.stderr.write(
        f"[install] error: stale runtime info: file reports version "
        f"{got_version!r}, installer expects {expected_version!r}\n"
    )
    sys.exit(1)
out = {
    "port": int(d["port"]),
    "token": d["token"],
    "version": d["version"],
    "linger": linger == "true",
}
iroh = d.get("iroh")
if isinstance(iroh, dict):
    out["iroh"] = iroh
print(json.dumps(out, separators=(",", ":")))
PY
}

emit_via_fallback() {
  # No python3 available. Hand-parse the three fields.
  local port token got_version safe_token linger_bool
  port="$(grep -E '"port"[[:space:]]*:' "$POLL_TARGET" | head -n1 | sed -E 's/.*"port"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/')"
  token="$(grep -E '"token"[[:space:]]*:' "$POLL_TARGET" | head -n1 | sed -E 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  got_version="$(grep -E '"version"[[:space:]]*:' "$POLL_TARGET" | head -n1 | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  [[ -n "$port" && -n "$token" && -n "$got_version" ]] \
    || { fatal "could not parse $POLL_TARGET"; }
  if [[ "$got_version" != "$VERSION" ]]; then
    fatal "stale runtime info: file reports version '$got_version', installer expects '$VERSION'"
  fi
  # Hand-rolled emit only handles tokens drawn from a narrow alphabet —
  # the auto-generated tokens are 48 hex chars (see src/config.ts). If
  # the user injected an arbitrary OPENVSMOBILE_TOKEN that contains
  # characters outside [A-Za-z0-9_-], refuse rather than emit malformed
  # JSON. The python path above handles the general case; install python3
  # to lift this restriction.
  if [[ ! "$token" =~ ^[A-Za-z0-9_-]+$ ]]; then
    fatal "OPENVSMOBILE_TOKEN contains characters that the fallback JSON emitter cannot safely quote; install python3 or use a hex/alphanumeric token"
  fi
  if [[ "$LINGER" == "true" ]]; then linger_bool=true; else linger_bool=false; fi
  if grep -q '"iroh"[[:space:]]*:' "$POLL_TARGET"; then
    log "warn: python3 not available; omitting optional iroh object from install JSON"
  fi
  printf '{"port":%s,"token":"%s","version":"%s","linger":%s}\n' \
    "$port" "$token" "$got_version" "$linger_bool"
}

if command -v python3 >/dev/null 2>&1; then
  if ! emit_via_python; then
    fatal "runtime.json failed validation (see above)"
  fi
else
  emit_via_fallback
fi

log "installed successfully (version=$VERSION, linger=$LINGER)"
