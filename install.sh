#!/usr/bin/env bash
# Stable entrypoint for curl-piped installs from the main branch.
#
# The real installer lives at next/backend/pkg/install.sh because release
# packaging and the Flutter SSH bootstrap both consume that path directly.
# Keep this wrapper tiny so install logic does not fork into two copies.

set -euo pipefail

REPO="${OPENVSMOBILE_INSTALL_REPO:-Lincyaw/openvsmobile}"
REF="${OPENVSMOBILE_INSTALL_REF:-main}"
SCRIPT_URL="${OPENVSMOBILE_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/next/backend/pkg/install.sh}"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$SCRIPT_URL" | bash -s -- "$@"
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "$SCRIPT_URL" | bash -s -- "$@"
else
  printf '[install-wrapper] error: missing dependency: curl or wget\n' >&2
  exit 7
fi
