#!/usr/bin/env bash
# Snapshot the lightpanda V8 build state for continuation on a fresh runner.
# Uploads tarballs to a GitHub release (draft) so a follow-up session can
# resume the build without re-downloading the ~6 GB V8 source tree.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

REPO="${REPO:-Mala980/tester}"
TAG="${TAG:-android-continuation}"
STATE_DIR="${1:-/tmp/opencode/zig-v8-fork}"
OUT_DIR="${2:-$WORK_DIR/state}"
mkdir -p "$OUT_DIR"

log "Compressing V8 sources (excluding .git)..."
tar -C "$STATE_DIR/.lp-cache" -cJf "$OUT_DIR/v8-src.tar.xz" \
  --exclude='*/_gclient_*' --exclude='v8-14.9.207.35/.git' \
  --exclude='v8-14.9.207.35/out' \
  v8-14.9.207.35 2>/dev/null &
TAR_PID=$!

log "Compressing V8 build output..."
tar -C "$STATE_DIR/.lp-cache/v8-14.9.207.35" -cJf "$OUT_DIR/v8-out.tar.xz" out 2>/dev/null

wait $TAR_PID
log "State tarballs:"
ls -lh "$OUT_DIR/"

log "Creating draft release + uploading..."
gh release create "$TAG" "$OUT_DIR"/*.tar.xz --repo "$REPO" --draft \
  --title "Lightpanda build continuation state" \
  --notes "Intermediate V8 android build state for resume (scripts/resume-lightpanda.sh)" || true
gh release upload "$TAG" "$OUT_DIR"/*.tar.xz --repo "$REPO" --clobber || true
log "Done."