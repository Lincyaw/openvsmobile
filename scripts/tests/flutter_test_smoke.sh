#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="${TARGET_SCRIPT:-$REPO_ROOT/scripts/flutter-test.sh}"

fail() {
  echo "[flutter-test-smoke] FAIL: $*" >&2
  exit 1
}

pass() {
  echo "[flutter-test-smoke] PASS: $*"
}

if [[ ! -f "$TARGET_SCRIPT" ]]; then
  fail "expected verification entry at $TARGET_SCRIPT"
fi

# The re-plan requires a reproducible Flutter verification entry that either
# chooses an explicit/local SDK or fails with a clear runner error.
if ! grep -Eq 'FLUTTER|flutter' "$TARGET_SCRIPT"; then
  fail "verification entry does not appear to handle a Flutter runner"
fi

if ! grep -Eq '(/home/.+/flutter/.+/flutter|FLUTTER_BIN|OPENVSMOBILE_FLUTTER|which flutter|command -v flutter)' "$TARGET_SCRIPT"; then
  fail "verification entry does not document a discoverable Flutter runner path/override"
fi

if ! grep -Eqi '(no usable flutter|flutter .*not found|flutter .*executable|unable to .*flutter|missing .*flutter)' "$TARGET_SCRIPT"; then
  fail "verification entry does not advertise a clear missing-runner error"
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
mkdir -p "$workdir/bin"
log_file="$workdir/flutter.log"
mkdir -p "$workdir/bin/cache/artifacts/engine/linux-x64"
cat > "$workdir/bin/flutter" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$PWD::$*" >> "$FAKE_FLUTTER_LOG"
case "${1:-}" in
  --version|doctor|test|analyze|pub|config)
    exit 0
    ;;
  build)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKE
chmod +x "$workdir/bin/flutter"
cat > "$workdir/bin/cache/artifacts/engine/linux-x64/flutter_tester" <<'FAKE_TESTER'
#!/usr/bin/env bash
exit 0
FAKE_TESTER
chmod +x "$workdir/bin/cache/artifacts/engine/linux-x64/flutter_tester"

{
  PATH="$workdir/bin:$PATH" \
  FLUTTER_BIN="$workdir/bin/flutter" \
  OPENVSMOBILE_FLUTTER="$workdir/bin/flutter" \
  FAKE_FLUTTER_LOG="$log_file" \
  "$TARGET_SCRIPT"
} >/dev/null 2>&1

if [[ ! -s "$log_file" ]]; then
  fail "verification entry did not execute the supplied Flutter runner"
fi

if ! grep -Eq '(^|::)(test|analyze|pub|--version)($| )' "$log_file"; then
  fail "verification entry invoked fake Flutter, but not with an expected verification command"
fi

pass "verification entry uses the supplied Flutter runner"

# If the script exposes an explicit override knob, validate that an unusable
# override fails loudly instead of silently falling back.
if grep -Eq 'FLUTTER_BIN|OPENVSMOBILE_FLUTTER' "$TARGET_SCRIPT"; then
  set +e
  failure_output="$({
    PATH="/usr/bin:/bin" \
    FLUTTER_BIN="$workdir/missing/flutter" \
    OPENVSMOBILE_FLUTTER="$workdir/missing/flutter" \
    "$TARGET_SCRIPT"
  } 2>&1)"
  failure_status=$?
  set -e

  if [[ $failure_status -eq 0 ]]; then
    fail "verification entry succeeded with an invalid explicit Flutter runner"
  fi

  if ! grep -Eqi '(flutter|runner).*(missing|not found|executable|usable)' <<<"$failure_output"; then
    fail "verification entry failure for invalid explicit runner was not clear"
  fi

  pass "verification entry reports a clear error for an invalid explicit runner"
else
  pass "skipped invalid-explicit-runner branch; no explicit override knob detected"
fi
