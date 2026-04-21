#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[verify-repo] Running Flutter verification for app/"
"$SCRIPT_DIR/flutter-test.sh" "$@"
