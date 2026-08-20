#!/usr/bin/env bash
# Resume the lightpanda Android build from a state tarball produced by
# scripts/upload-state.sh (run in a fresh session on a fresh runner).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

REPO="${REPO:-Mala980/tester}"
TAG="${TAG:-android-continuation}"
RESUME_DIR="${RESUME_DIR:-$WORK_DIR/resume}"
mkdir -p "$RESUME_DIR"

log "Downloading state release assets..."
gh release download "$TAG" --repo "$REPO" --dir "$RESUME_DIR"
ls -lh "$RESUME_DIR/"

ensure_zig
ensure_ndk

V8_DIR="$CACHE_DIR/zig-v8-fork"
V8_SRC="$V8_DIR/.lp-cache/v8-14.9.207.35"
mkdir -p "$V8_SRC"
log "Restoring V8 sources..."
tar -xJf "$RESUME_DIR/v8-src.tar.xz" -C "$V8_DIR/.lp-cache"
log "Restoring V8 build output..."
tar -xJf "$RESUME_DIR/v8-out.tar.xz" -C "$V8_SRC"

# Recreate the depot_tools path the build expects (scripted by zig build)
if [ ! -d "$V8_DIR/.lp-cache/depot_tools-14.9.207.35" ]; then
  log "Re-bootstrapping depot_tools (needed for gn/autoninja)..."
  zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast prepare-v8 \
    --cache-dir "$CACHE_DIR/zig-cache" --global-cache-dir "$CACHE_DIR/zig-global"
fi

# NDK + android deps + patches
NDK_TARGET="$V8_SRC/third_party/android_toolchain"
mkdir -p "$NDK_TARGET"
ln -sfn "$ANDROID_NDK_HOME" "$NDK_TARGET/ndk"
if ! grep -q 'target_os="android"' "$V8_DIR/build.zig"; then
  git -C "$V8_DIR" apply "$SCRIPT_DIR/../patches/zig-v8-fork/android.patch" 2>/dev/null || true
fi

log "Resuming lightpanda V8 build (incremental)..."
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast build-v8 \
  --cache-dir "$CACHE_DIR/zig-cache" --global-cache-dir "$CACHE_DIR/zig-global" 2>&1 | tail -20

ARCHIVE=$(find "$V8_SRC/out" -name 'libc_v8.a' | head -1)
[ -n "$ARCHIVE" ] || die "libc_v8.a not found after resume"
cp "$ARCHIVE" "$CACHE_DIR/libc_v8_14.9.207.35_android_aarch64.a"

log "Building lightpanda..."
./scripts/build-lightpanda-android.sh

log "Packaging..."
./scripts/package.sh
log "Lightpanda resume complete."