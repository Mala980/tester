#!/usr/bin/env bash
# Build V8 14.9.207.35 for aarch64-linux-android via lightpanda's zig-v8-fork.
# Produces: $CACHE_DIR/libc_v8_${V8_VERSION}_android_aarch64.a
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
ensure_zig
ensure_ndk

V8_DIR="$CACHE_DIR/zig-v8-fork"
OUT_ARCHIVE="$CACHE_DIR/libc_v8_${LIGHTPANDA_V8_VERSION}_android_aarch64.a"

if [ -f "$OUT_ARCHIVE" ]; then
  log "V8 android archive already cached: $OUT_ARCHIVE"
  exit 0
fi

log "Cloning zig-v8-fork @ $ZIG_V8_FORK_COMMIT"
if [ ! -d "$V8_DIR/.git" ]; then
  git clone --filter=blob:none "$ZIG_V8_FORK_REPO" "$V8_DIR"
fi
git -C "$V8_DIR" fetch --depth 1 origin "$ZIG_V8_FORK_COMMIT" || true
git -C "$V8_DIR" checkout -q "$ZIG_V8_FORK_COMMIT"

# Apply the Android gn-args patch (idempotent)
if ! grep -q 'target_os="android"' "$V8_DIR/build.zig"; then
  git -C "$V8_DIR" apply "$SCRIPT_DIR/../patches/zig-v8-fork/android.patch"
fi

log "Preparing V8 sources (gclient sync + clang)..."
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast prepare-v8 \
  --cache-dir "$CACHE_DIR/zig-cache" --global-cache-dir "$CACHE_DIR/zig-global"

# Re-run gclient with checkout_android so the android-gated deps
# (cpu_features, catapult, colorama, android_platform, ...) are fetched at
# their pinned commits. V8's DEPS gates these on `checkout_android`.
V8_SRC="$V8_DIR/.lp-cache/v8-${LIGHTPANDA_V8_VERSION}"
cat > "$V8_SRC/.gclient" <<EOF
solutions = [
  {
    "name": ".",
    "url": "https://chromium.googlesource.com/v8/v8.git@${LIGHTPANDA_V8_VERSION}",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {
      "checkout_android": True,
    },
  },
]
EOF
(cd "$V8_SRC" && PATH="$V8_DIR/.lp-cache/depot_tools-${LIGHTPANDA_V8_VERSION}:$PATH" gclient sync --nohooks) \
  | tail -5

# Point Chromium's build config at our NDK: V8's DEPS does not fetch the
# Android NDK itself; it is expected at third_party/android_toolchain/ndk.
NDK_TARGET="$V8_SRC/third_party/android_toolchain"
mkdir -p "$NDK_TARGET"
ln -sfn "$ANDROID_NDK_HOME" "$NDK_TARGET/ndk"

log "Building V8 for android (ReleaseFast, JOBS=$JOBS)..."
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast build-v8 \
  --cache-dir "$CACHE_DIR/zig-cache" --global-cache-dir "$CACHE_DIR/zig-global" 2>&1 \
  | tee "$CACHE_DIR/build-v8.log"

# Locate the archive: .lp-cache/v8-*/out/android_release_<hash>/obj/zig/libc_v8.a
ARCHIVE=$(find "$V8_DIR/.lp-cache/v8-${LIGHTPANDA_V8_VERSION}/out" -name 'libc_v8.a' | head -1)
[ -n "$ARCHIVE" ] || die "libc_v8.a not found after build"
cp "$ARCHIVE" "$OUT_ARCHIVE"
log "V8 android archive: $OUT_ARCHIVE ($(du -h "$OUT_ARCHIVE" | cut -f1))"

# Cache the v8 source tree too, keyed, so re-runs skip the gclient sync.
rm -rf "$CACHE_DIR/v8-src"
cp -r "$V8_DIR/.lp-cache/v8-${LIGHTPANDA_V8_VERSION}" "$CACHE_DIR/v8-src" 2>/dev/null || true