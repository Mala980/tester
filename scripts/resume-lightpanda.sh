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
V8_SRC="$V8_DIR/.lp-cache/v8-${LIGHTPANDA_V8_VERSION}"
mkdir -p "$V8_DIR/.lp-cache"

# Prepare the V8 source tree (re-clones ~15-25 min) with the android patches
if [ ! -d "$V8_SRC/DEPS" ]; then
  log "Cloning zig-v8-fork @ $ZIG_V8_FORK_COMMIT"
  git clone --filter=blob:none "$ZIG_V8_FORK_REPO" "$V8_DIR"
  git -C "$V8_DIR" fetch --depth 1 origin "$ZIG_V8_FORK_COMMIT"
  git -C "$V8_DIR" checkout -q "$ZIG_V8_FORK_COMMIT"
  if ! grep -q 'target_os="android"' "$V8_DIR/build.zig"; then
    git -C "$V8_DIR" apply "$SCRIPT_DIR/../patches/zig-v8-fork/android.patch"
  fi
  log "Preparing V8 sources (gclient sync + clang)..."
  zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast prepare-v8 \
    --cache-dir "$CACHE_DIR/zig-cache" --global-cache-dir "$CACHE_DIR/zig-global"
  # android-gated deps (cpu_features etc.)
  cat > "$V8_SRC/.gclient" <<EOF
solutions = [
  {
    "name": ".",
    "url": "https://chromium.googlesource.com/v8/v8.git@${LIGHTPANDA_V8_VERSION}",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {},
    "custom_vars": { "checkout_android": True },
  },
]
EOF
  (cd "$V8_SRC" && PATH="$V8_DIR/.lp-cache/depot_tools-${LIGHTPANDA_V8_VERSION}:$PATH" gclient sync --nohooks) | tail -5
fi

# Restore the compiled build output and NDK link
log "Restoring V8 build output..."
tar -I 'zstd -T2' -xf "$RESUME_DIR/v8-out.tar.zst" -C "$V8_SRC"
NDK_TARGET="$V8_SRC/third_party/android_toolchain"
mkdir -p "$NDK_TARGET"
ln -sfn "$ANDROID_NDK_HOME" "$NDK_TARGET/ndk"

log "Resuming lightpanda V8 build (incremental)..."
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast build-v8 \
  --cache-dir "$CACHE_DIR/zig-cache" --global-cache-dir "$CACHE_DIR/zig-global" 2>&1 | tail -20

ARCHIVE=$(find "$V8_SRC/out" -name 'libc_v8.a' | head -1)
[ -n "$ARCHIVE" ] || die "libc_v8.a not found after resume"
cp "$ARCHIVE" "$CACHE_DIR/libc_v8_${LIGHTPANDA_V8_VERSION}_android_aarch64.a"

log "Building lightpanda..."
./scripts/build-lightpanda-android.sh

log "Packaging..."
./scripts/package.sh
log "Lightpanda resume complete."