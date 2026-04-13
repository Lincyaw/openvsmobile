#!/usr/bin/env bash
# Sync the openvscode-server submodule with upstream (gitpod-io/openvscode-server).
# Usage: ./scripts/sync-upstream.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUBMODULE_DIR="$REPO_ROOT/openvscode-server"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

log() { echo "[sync-upstream] $*"; }
err() { echo "[sync-upstream] ERROR: $*" >&2; }

if [[ ! -d "$SUBMODULE_DIR/.git" ]]; then
    err "Submodule not initialized. Run: git submodule update --init"
    exit 1
fi

cd "$SUBMODULE_DIR"

# Ensure upstream remote exists.
if ! git remote get-url upstream &>/dev/null; then
    log "Adding upstream remote..."
    git remote add upstream https://github.com/gitpod-io/openvscode-server.git
fi

log "Fetching upstream..."
git fetch upstream

LOCAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
log "Current branch: $LOCAL_BRANCH"

UPSTREAM_REF="upstream/main"
LOCAL_HEAD="$(git rev-parse HEAD)"
UPSTREAM_HEAD="$(git rev-parse "$UPSTREAM_REF" 2>/dev/null || echo "")"

if [[ -z "$UPSTREAM_HEAD" ]]; then
    err "Could not resolve $UPSTREAM_REF. Check upstream remote."
    exit 1
fi

if [[ "$LOCAL_HEAD" == "$UPSTREAM_HEAD" ]]; then
    log "Already up to date with upstream."
    exit 0
fi

BEHIND="$(git rev-list --count HEAD.."$UPSTREAM_REF")"
AHEAD="$(git rev-list --count "$UPSTREAM_REF"..HEAD)"
log "Status: $BEHIND commits behind, $AHEAD commits ahead of upstream."

if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] Would merge $UPSTREAM_REF into $LOCAL_BRANCH."
    log "[dry-run] New commits from upstream:"
    git log --oneline HEAD.."$UPSTREAM_REF" | head -20
    exit 0
fi

log "Merging $UPSTREAM_REF into $LOCAL_BRANCH..."
if git merge "$UPSTREAM_REF" --no-edit; then
    log "Merge successful."
    log "Don't forget to:"
    log "  1. cd $REPO_ROOT"
    log "  2. git add openvscode-server"
    log "  3. git commit -m 'chore: sync openvscode-server with upstream'"
else
    err "Merge conflicts detected. Resolve them in $SUBMODULE_DIR, then:"
    err "  1. git add <resolved files>"
    err "  2. git commit"
    err "  3. cd $REPO_ROOT && git add openvscode-server && git commit"
    exit 1
fi
