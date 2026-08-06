#!/usr/bin/env bash
# Install or upgrade the openvsmobile-next backend as a per-user service:
# systemd --user on Linux, LaunchAgent/launchctl on macOS. Intended to be
# either curl-piped from a release URL or fed via stdin over an SSH bootstrap.
#
# stdout contract: on success, exactly ONE line of JSON:
#   {"port":N,"token":"...","version":"X.Y.Z","linger":true|false}
# When Iroh starts successfully, the JSON also includes `"iroh":{...}` from runtime.json.
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
LAUNCHD_LABEL="dev.lincyaw.openvsmobile.backend"
PLIST_PATH="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
LAUNCHD_LOG_PATH="$STATE_DIR/launchd.log"
POLL_TIMEOUT_SECS=10
STOP_TIMEOUT_SECS=20

# ----- usage -----
usage() {
  cat <<'EOF'
Usage: install.sh <version> [--tarball <path>] [--dry-run-service] [--force]

Args:
  version       Release version without leading 'v' (e.g. 0.1.0).
                When --tarball is omitted, the tarball is downloaded from
                https://github.com/Lincyaw/openvsmobile/releases/download/v<version>/

Flags:
  --tarball <path>      Use a local tarball instead of downloading.
                        The matching .sha256 must sit next to it.
  --dry-run-service     Print the service file to stderr, skip service
                        install/start. Spawns a sandboxed backend
                        (HOME=mktemp) so it never touches the real
                        ~/.config/openvsmobile-next/ or ~/.local/state/.
                        Refuses to run if the real service is currently
                        active (use --force to override).
  --dry-run-systemd     Deprecated alias for --dry-run-service.
  --force               With --dry-run-service: proceed even when the real
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
  OPENVSMOBILE_IROH=0   Force a WebSocket-only backend. Iroh is bundled and
                        starts by default; related OPENVSMOBILE_IROH_*
                        variables present during install are persisted.
  OPENVSMOBILE_PAIRING_QR=auto|1|0
                        Print a terminal QR code with the token and ticket
                        on stderr after install. Default "auto" prints only
                        when stderr is an interactive terminal. "1" forces it;
                        "0" disables it.

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

need_sha256() {
  if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
    return 0
  fi
  fatal "missing dependency: sha256sum or shasum (install it and retry)" 7
}

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
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

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

append_plist_env_if_set() {
  local key="$1" value
  [[ -n "${!key+x}" ]] || return 0
  value="${!key}"
  [[ -n "$value" ]] || return 0
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    fatal "$key contains a newline; refusing to write invalid launchd EnvironmentVariables entry" 2
  fi
  PLIST_EXTRA_ENV+=$'\n'"    <key>$(xml_escape "$key")</key><string>$(xml_escape "$value")</string>"
}

pid_alive() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ "$pid" -gt 0 ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

service_main_pid() {
  local pid
  case "$PLATFORM" in
    linux)
      pid="$(systemctl --user show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || true)"
      ;;
    darwin)
      pid="$(launchctl print "${LAUNCHD_DOMAIN}/${LAUNCHD_LABEL}" 2>/dev/null \
        | awk -F'= ' '/^[[:space:]]*pid = / {print $2; exit}' || true)"
      ;;
    *)
      pid="0"
      ;;
  esac
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
    case "$PLATFORM" in
      linux)
        state="$(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || true)"
        ;;
      darwin)
        if launchctl print "${LAUNCHD_DOMAIN}/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
          state="active"
        else
          state="inactive"
        fi
        ;;
      *)
        state="inactive"
        ;;
    esac
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

service_is_active() {
  case "$PLATFORM" in
    linux)
      systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null
      ;;
    darwin)
      local pid
      pid="$(service_main_pid)"
      pid_alive "$pid"
      ;;
    *)
      return 1
      ;;
  esac
}

stop_installed_service() {
  case "$PLATFORM" in
    linux)
      systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true
      wait_service_stopped || fatal "$SERVICE_NAME did not stop within ${STOP_TIMEOUT_SECS}s"
      systemctl --user reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
      ;;
    darwin)
      launchctl bootout "$LAUNCHD_DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 \
        || launchctl remove "$LAUNCHD_LABEL" >/dev/null 2>&1 \
        || true
      wait_service_stopped || fatal "$LAUNCHD_LABEL did not stop within ${STOP_TIMEOUT_SECS}s"
      ;;
  esac
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

show_pairing_qr() {
  local mode="${OPENVSMOBILE_PAIRING_QR:-auto}"
  [[ "$mode" != "0" ]] || return 0
  if [[ "$mode" != "1" && ! -t 2 ]]; then
    return 0
  fi
  local node_bin="$BUNDLE_DIR/node/bin/node"
  local qr_script="$BUNDLE_DIR/bin/openvsmobile-pairing-qr.mjs"
  if [[ ! -x "$node_bin" || ! -x "$qr_script" ]]; then
    log "warn: pairing QR generator missing from bundle; skipping QR"
    return 0
  fi
  log "pairing QR follows (scan from Backends > Add backend > Scan QR)"
  if ! "$node_bin" "$qr_script" --runtime "$POLL_TARGET" --version "$VERSION" >&2; then
    log "warn: pairing QR generation failed; backend install will continue"
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
DRY_RUN_SERVICE=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --tarball)
      [[ $# -ge 2 ]] || { usage >&2; fatal "--tarball requires a path" 2; }
      TARBALL_OVERRIDE="$2"; shift 2 ;;
    --dry-run-service)
      DRY_RUN_SERVICE=1; shift ;;
    --dry-run-systemd)
      DRY_RUN_SERVICE=1; shift ;;
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

# ----- detect platform -----
RAW_OS="$(uname -s)"
case "$RAW_OS" in
  Linux)
    PLATFORM="linux"
    ;;
  Darwin)
    PLATFORM="darwin"
    LAUNCHD_DOMAIN="gui/$(id -u)"
    ;;
  *)
    fatal "unsupported operating system: $RAW_OS (need Linux or macOS)" 7
    ;;
esac
log "platform: $PLATFORM ($RAW_OS)"

# ----- detect arch -----
RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
  x86_64)  ARCH="x64"   ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)
    fatal "unsupported architecture: $RAW_ARCH (need x86_64 or arm64/aarch64)" 7
    ;;
esac
log "arch: $ARCH ($RAW_ARCH)"

# ----- check deps -----
need curl
need tar
need_sha256
need file
case "$PLATFORM" in
  linux)
    # systemctl in user mode — present on any systemd-based distro a non-root
    # user can use. We don't require root.
    need systemctl
    ;;
  darwin)
    need launchctl
    ;;
esac

# ----- dry-run vs real-unit conflict guard (B4) -----
if [[ "$DRY_RUN_SERVICE" -eq 1 ]] && [[ "$FORCE" -eq 0 ]]; then
  if service_is_active; then
    fatal "real backend service is currently active; --dry-run-service would spawn a parallel backend (use --force to override)" 5
  fi
fi

# ----- tarball acquisition -----
TARBALL_NAME="openvsmobile-backend-${PLATFORM}-${ARCH}.tar.gz"
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
ACTUAL_HEX="$(sha256_hex "$TARBALL_PATH")"
if [[ "$EXPECTED_HEX" != "$ACTUAL_HEX" ]]; then
  fatal "sha256 mismatch: expected $EXPECTED_HEX, got $ACTUAL_HEX"
fi
log "sha256 verified: $ACTUAL_HEX"

# ----- native arch verification of bundled .node files (M1) -----
# Cross-target via npm_config_target_arch only redirects prebuild
# downloads; native packages can still silently embed a wrong-host binary
# when a build job runs on the wrong runner. Probe native modules before
# we commit to the install.
EXPECTED_NATIVE_DESC=""
NATIVE_KIND=""
case "$PLATFORM/$ARCH" in
  linux/x64)    EXPECTED_NATIVE_DESC="x86-64"; NATIVE_KIND="ELF" ;;
  linux/arm64)  EXPECTED_NATIVE_DESC="aarch64"; NATIVE_KIND="ELF" ;;
  darwin/x64)   EXPECTED_NATIVE_DESC="x86_64"; NATIVE_KIND="Mach-O" ;;
  darwin/arm64) EXPECTED_NATIVE_DESC="arm64"; NATIVE_KIND="Mach-O" ;;
esac

PROBE_DIR="$(mktemp -d -t openvsmobile-probe.XXXXXX)"
# shellcheck disable=SC2064  # we want $PROBE_DIR expanded now, not later
trap "rm -rf '$PROBE_DIR'" EXIT
tar -xzf "$TARBALL_PATH" -C "$PROBE_DIR"
# Only inspect native binaries for the target platform. Packages can ship
# prebuilds for several platforms; non-target .node files are ignored.
ALL_NODE_FILES=()
while IFS= read -r -d '' nf; do
  ALL_NODE_FILES+=("$nf")
done < <(find "$PROBE_DIR" -name '*.node' -print0)
TARGET_NODE_FILES=()
for nf in "${ALL_NODE_FILES[@]}"; do
  if file -b "$nf" | grep -q "^${NATIVE_KIND} "; then
    TARGET_NODE_FILES+=("$nf")
  fi
done
if [[ ${#TARGET_NODE_FILES[@]} -eq 0 ]]; then
  log "warn: no ${PLATFORM} ${NATIVE_KIND} .node files in tarball — native dependency packaging may have failed silently"
else
  for nf in "${TARGET_NODE_FILES[@]}"; do
    desc="$(file -b "$nf")"
    if ! grep -q "$EXPECTED_NATIVE_DESC" <<<"$desc"; then
      # Some packages ship multiple same-platform prebuilds in one package
      # (for example node-pty/prebuilds/darwin-x64 and darwin-arm64). Skip
      # the explicitly non-target sibling; still fail wrong-arch binaries in
      # generic build/Release locations where the path gives no such excuse.
      if [[ "$nf" == *"/${PLATFORM}-"* && "$nf" != *"/${PLATFORM}-${ARCH}"* ]]; then
        continue
      fi
      fatal "native module $nf is not $EXPECTED_NATIVE_DESC (got: $desc); packaging produced a wrong-arch binary"
    fi
  done
  log "verified ${#TARGET_NODE_FILES[@]} ${PLATFORM} native module(s) match $EXPECTED_NATIVE_DESC"
fi

# ----- stop running service BEFORE swapping anything (B1) -----
# `systemctl --user enable --now` is a no-op when the service is already
# active, so an upgrade flips `current` to a new tree while the old node
# process keeps running. Worse, it might resolve some new files via the
# symlink at runtime. Always stop first; ignore failures (unit may not be
# loaded yet on a first install). `stop` also cancels a pending restart
# job, which matters after a crash loop: `is-active` may already be false
# while systemd still has a restart queued that can rewrite old runtime.json.
if [[ "$DRY_RUN_SERVICE" -eq 0 ]]; then
  log "stopping existing backend service before upgrade"
  stop_installed_service
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
if ! mv -Tf "$TMP_LINK" "$CURRENT_LINK" 2>/dev/null; then
  rm -f "$CURRENT_LINK"
  mv -f "$TMP_LINK" "$CURRENT_LINK"
fi
log "current -> $INSTALL_DIR"

# ----- seed example plugins on first install -----
# A fresh environment otherwise lands on an empty Plugins tab. We bundle
# clock / notes / sysinfo / agentm-gateway / codex-client in the tarball under
# share/example-plugins/ and
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
    for plugin in clock notes sysinfo agentm-gateway codex-client; do
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

# ----- write per-user service -----
UNIT_EXTRA_ENV=""
PLIST_EXTRA_ENV=""
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
  append_plist_env_if_set "$env_key"
done

case "$PLATFORM" in
  linux)
    SERVICE_FILE_PATH="$UNIT_PATH"
    mkdir -p "$(dirname "$SERVICE_FILE_PATH")"
    SERVICE_CONTENT=$(cat <<UNIT
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
    ;;
  darwin)
    SERVICE_FILE_PATH="$PLIST_PATH"
    mkdir -p "$(dirname "$SERVICE_FILE_PATH")" "$STATE_DIR"
    SERVICE_CONTENT=$(cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(xml_escape "$LAUNCHD_LABEL")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$LAUNCH_SCRIPT")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$(xml_escape "$HOME")</string>
    <key>PORT</key><string>0</string>
    <key>NODE_ENV</key><string>production</string>$PLIST_EXTRA_ENV
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>StandardOutPath</key><string>$(xml_escape "$LAUNCHD_LOG_PATH")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$LAUNCHD_LOG_PATH")</string>
</dict>
</plist>
PLIST
)
    ;;
esac

# Track LINGER for the JSON-emit step regardless of branch.
LINGER=false

if [[ "$DRY_RUN_SERVICE" -eq 1 ]]; then
  log "--- BEGIN service file (dry-run: $SERVICE_FILE_PATH) ---"
  printf '%s\n' "$SERVICE_CONTENT" >&2
  log "--- END service file (dry-run) ---"
  log "dry-run: skipping service install/start"

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
  log "writing service file: $SERVICE_FILE_PATH"
  printf '%s\n' "$SERVICE_CONTENT" > "$SERVICE_FILE_PATH"

  # Wipe any stale runtime.json from the previous version BEFORE start,
  # so the poll loop's "file appeared" signal unambiguously means "the new
  # process wrote it" (B2).
  rm -f "$RUNTIME_INFO"

  case "$PLATFORM" in
    linux)
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
      systemctl --user daemon-reload
      systemctl --user enable --now "$SERVICE_NAME" >/dev/null
      log "systemd unit enabled and started"
      ;;
    darwin)
      launchctl bootstrap "$LAUNCHD_DOMAIN" "$PLIST_PATH"
      launchctl kickstart -k "${LAUNCHD_DOMAIN}/${LAUNCHD_LABEL}" >/dev/null
      LINGER=true
      log "LaunchAgent bootstrapped and started ($LAUNCHD_LABEL)"
      ;;
  esac
  POLL_TARGET="$RUNTIME_INFO"
fi

# ----- poll runtime.json -----
log "waiting for valid $POLL_TARGET (up to ${POLL_TIMEOUT_SECS}s)"
deadline=$(( $(date +%s) + POLL_TIMEOUT_SECS ))
while ! runtime_ready "$POLL_TARGET"; do
  if (( $(date +%s) >= deadline )); then
    if [[ "$DRY_RUN_SERVICE" -eq 1 ]]; then
      log "diagnostic backend log:"
      sed -e 's/^/  /' "$DRY_HOME/.backend.log" >&2 || true
      fatal "backend did not write valid $POLL_TARGET within ${POLL_TIMEOUT_SECS}s (dry-run)"
    fi
    case "$PLATFORM" in
      linux) log "diagnostic: 'systemctl --user status openvsmobile' may explain why" ;;
      darwin) log "diagnostic: 'launchctl print ${LAUNCHD_DOMAIN}/${LAUNCHD_LABEL}' and $LAUNCHD_LOG_PATH may explain why" ;;
    esac
    fatal "backend did not write valid $POLL_TARGET within ${POLL_TIMEOUT_SECS}s"
  fi
  sleep 0.2
done

# ----- install optional Claude Code / Codex Stop hooks -----
# This mutates real user agent configs, so keep dry-run hermetic.
if [[ "$DRY_RUN_SERVICE" -eq 0 ]]; then
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
show_pairing_qr
