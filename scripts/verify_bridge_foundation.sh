#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/verify_bridge_foundation.sh [--extension-only]

Runs the reproducible validation flow for the mobile runtime bridge foundation.
  --extension-only  Only compile the built-in OpenVSCode bridge extension.
USAGE
}

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "required command '$1' is not available in PATH"
  fi
}

find_go() {
  local candidate
  for candidate in \
    "${GO_BINARY:-}" \
    "$(command -v go 2>/dev/null || true)" \
    "${HOME}/go-sdk/go/bin/go" \
    "${HOME}/.local/go/bin/go" \
    "/usr/local/go/bin/go"
  do
    if [[ -n "${candidate}" && -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

extension_only=0
case "${1:-}" in
  "")
    ;;
  --extension-only)
    extension_only=1
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    die "unknown argument: $1"
    ;;
esac

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
openvscode_dir="${repo_root}/openvscode-server"
server_dir="${repo_root}/server"
openvscode_gulp="${openvscode_dir}/node_modules/gulp/bin/gulp.js"
openvscode_server_main="${openvscode_dir}/out/server-main.js"
go_bin=""

[[ -d "${openvscode_dir}" ]] || die "openvscode-server/ is missing; sync the submodule checkout first"
[[ -f "${openvscode_dir}/package.json" ]] || die "openvscode-server/package.json is missing"
[[ -d "${server_dir}" ]] || die "server/ is missing"

need_cmd node
need_cmd npm

if [[ "${extension_only}" != "1" ]]; then
  go_bin="$(find_go)" || die "required command 'go' is not available; set GO_BINARY or install Go (for example ${HOME}/go-sdk/go/bin/go)"
fi

if [[ ! -x "${openvscode_gulp}" ]]; then
  die "openvscode-server dependencies are missing; run 'cd ${openvscode_dir} && npm install' (or 'npm ci') first"
fi

log "Compiling mobile-runtime-bridge from openvscode-server/"
(
  cd "${openvscode_dir}"
  npm run gulp -- compile-extension:mobile-runtime-bridge
)

if [[ "${extension_only}" == "1" ]]; then
  log "Bridge extension compile completed"
  exit 0
fi

log "Running targeted Go bridge tests"
(
  cd "${server_dir}"
  "${go_bin}" test ./internal/vscode ./internal/api
)

log "Running Go vet"
(
  cd "${server_dir}"
  "${go_bin}" vet ./...
)

if make -s -C "${repo_root}" flutter-prereq >/dev/null 2>&1; then
  log "Running repo-wide test and lint targets with detected Flutter SDK"
  make -C "${repo_root}" test
  make -C "${repo_root}" lint
else
  log "Skipping repo-wide Flutter validation (run 'make FLUTTER=/absolute/path/to/flutter test lint' once a Flutter SDK is available)"
fi

if [[ "${VSCODE_INTEGRATION_TEST:-}" == "1" ]]; then
  if [[ ! -f "${openvscode_server_main}" ]]; then
    die "VSCODE_INTEGRATION_TEST=1 requires '${openvscode_server_main}'; build openvscode-server first"
  fi

  log "Running gated bridge restart integration test"
  (
    cd "${server_dir}"
    GO_BINARY="${go_bin}" OPENVSCODE_SERVER_DIR="${openvscode_dir}" "${go_bin}" test ./internal/vscode -run TestIntegration_BridgeLifecycle_EndToEnd -count=1
  )
else
  log "Skipping gated bridge restart integration test (set VSCODE_INTEGRATION_TEST=1 after building openvscode-server)"
fi

log "Bridge foundation validation completed"
