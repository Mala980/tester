#!/usr/bin/env bash
# Snapshot the lightpanda V8 BUILD OUTPUT for continuation on a fresh runner.
# The V8 sources re-clone in ~15-25 min (gclient), but the compiled .o files
# would take hours — so we only ship the out/ dir (~0.5-1 GB), uploaded to a
# draft GitHub release; scripts/resume-lightpanda.sh restores and resumes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

REPO="${REPO:-Mala980/tester}"
TAG="${TAG:-android-continuation}"
STATE_DIR="${1:-/tmp/opencode/zig-v8-fork/.lp-cache/v8-14.9.207.35}"
OUT_DIR="${2:-$WORK_DIR/state}"
mkdir -p "$OUT_DIR"

log "Compressing V8 build output ($STATE_DIR/out)..."
tar -C "$STATE_DIR" -I 'zstd -T2 -9' -cf "$OUT_DIR/v8-out.tar.zst" out

ls -lh "$OUT_DIR/"

log "Creating draft release + uploading..."
gh release create "$TAG" "$OUT_DIR"/*.tar.zst --repo "$REPO" --draft \
  --title "Lightpanda build continuation state" \
  --notes "Intermediate V8 android build output for resume (scripts/resume-lightpanda.sh)" || true
gh release upload "$TAG" "$OUT_DIR"/*.tar.zst --repo "$REPO" --clobber || true
log "Done."