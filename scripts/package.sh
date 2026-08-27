#!/usr/bin/env bash
# Package the android binaries into tarballs for the GitHub release.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

OUT_DIR="${1:-$DIST_DIR}"
PKG_DIR="$WORK_DIR/packages"
mkdir -p "$PKG_DIR"

LIGHTPANDA_BIN="$OUT_DIR/lightpanda"
if [ -f "$LIGHTPANDA_BIN" ]; then
  tar -cJf "$PKG_DIR/lightpanda-aarch64-android.tar.xz" -C "$OUT_DIR" lightpanda
  log "lightpanda-aarch64-android.tar.xz ($(du -h "$PKG_DIR/lightpanda-aarch64-android.tar.xz" | cut -f1))"
fi

for variant in default no-render stealth no-render-stealth full; do
  d="$OUT_DIR/obscura-$variant"
  if [ -f "$d/obscura" ]; then
    tar -cJf "$PKG_DIR/obscura-aarch64-android${variant#default}.tar.xz" -C "$d" obscura obscura-worker
    log "obscura-aarch64-android${variant#default}.tar.xz ($(du -h "$PKG_DIR/obscura-aarch64-android${variant#default}.tar.xz" | cut -f1))"
  fi
done

ls -lh "$PKG_DIR/"