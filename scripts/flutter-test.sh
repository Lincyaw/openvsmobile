#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
FLUTTER_CONFIG_FILE="${OPENVSMOBILE_FLUTTER_CONFIG:-$REPO_ROOT/.flutter-bin}"

log() { echo "[flutter-test] $*"; }
err() { echo "[flutter-test] ERROR: $*" >&2; }

check_flutter() {
    local flutter_bin="$1"
    local source_name="$2"
    local bin_dir tester

    if [[ -z "$flutter_bin" ]]; then
        return 1
    fi

    if [[ ! -f "$flutter_bin" ]]; then
        err "$source_name points to '$flutter_bin', but that file does not exist."
        return 1
    fi

    if [[ ! -x "$flutter_bin" ]]; then
        err "$source_name points to '$flutter_bin', but it is not executable."
        return 1
    fi

    bin_dir="$(cd "$(dirname "$flutter_bin")" && pwd)"
    tester="$bin_dir/cache/artifacts/engine/linux-x64/flutter_tester"

    if [[ ! -e "$tester" ]]; then
        err "$source_name points to '$flutter_bin', but '$tester' is missing."
        err "Run '$flutter_bin precache --linux' for that SDK or point to a different Flutter install."
        return 1
    fi

    if [[ ! -x "$tester" ]]; then
        err "$source_name points to '$flutter_bin', but '$tester' is not executable."
        err "This Flutter SDK cannot run widget tests in this environment."
        return 1
    fi

    return 0
}

resolve_flutter() {
    local configured=""

    if [[ -n "${OPENVSMOBILE_FLUTTER:-}" ]]; then
        configured="$OPENVSMOBILE_FLUTTER"
        if check_flutter "$configured" "OPENVSMOBILE_FLUTTER"; then
            echo "$configured"
            return 0
        fi
        return 1
    fi

    if [[ -n "${FLUTTER_BIN:-}" ]]; then
        configured="$FLUTTER_BIN"
        if check_flutter "$configured" "FLUTTER_BIN"; then
            echo "$configured"
            return 0
        fi
        return 1
    fi

    if [[ -f "$FLUTTER_CONFIG_FILE" ]]; then
        configured="$(head -n 1 "$FLUTTER_CONFIG_FILE" | tr -d '\r')"
        if check_flutter "$configured" "$FLUTTER_CONFIG_FILE"; then
            echo "$configured"
            return 0
        fi
        return 1
    fi

    if check_flutter "/home/ddq/flutter/bin/flutter" "default SDK"; then
        echo "/home/ddq/flutter/bin/flutter"
        return 0
    fi

    if command -v flutter >/dev/null 2>&1; then
        configured="$(command -v flutter)"
        if check_flutter "$configured" "PATH flutter"; then
            echo "$configured"
            return 0
        fi
    fi

    err "Could not find a usable Flutter SDK."
    err "Set OPENVSMOBILE_FLUTTER or FLUTTER_BIN to a working flutter executable."
    err "You can also write the executable path to '$FLUTTER_CONFIG_FILE'."
    return 1
}

main() {
    local flutter_bin

    flutter_bin="$(resolve_flutter)" || exit 1

    log "Using Flutter SDK: $flutter_bin"
    cd "$APP_DIR"
    exec "$flutter_bin" test "$@"
}

main "$@"
