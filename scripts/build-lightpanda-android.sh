#!/usr/bin/env bash
# Build Lightpanda for Android/Termux (aarch64-linux-android, bionic, PIE).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
ensure_zig
ensure_ndk
gen_libc_file

export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android${ANDROID_API}-clang"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$NDK_BIN/llvm-ar"

SRC="$SRC_DIR/lightpanda"
if [ ! -d "$SRC/.git" ]; then
  log "Cloning lightpanda"
  git clone --depth 1 "$LIGHTPANDA_REPO" "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin main 2>/dev/null || true
git -C "$SRC" checkout -q FETCH_HEAD 2>/dev/null || git -C "$SRC" checkout -q main
LIGHTPANDA_COMMIT=$(git -C "$SRC" rev-parse --short HEAD)
log "Lightpanda @ $LIGHTPANDA_COMMIT"

# Apply the android build.zig patch (idempotent)
if ! grep -q 'exe.linkage = .dynamic' "$SRC/build.zig"; then
  git -C "$SRC" apply "$SCRIPT_DIR/../patches/lightpanda/build.zig-android.patch"
fi

# --- Build V8 for android (cached) ----------------------------------------
"$SCRIPT_DIR/build-lightpanda-v8-android.sh"
V8_ARCHIVE="$CACHE_DIR/libc_v8_${LIGHTPANDA_V8_VERSION}_android_aarch64.a"

# Place the archive where lightpanda's build.zig discovers it:
#   .lp-cache/prebuilt-v8/<zig-v8-tag>/libc_v8_<v8>_android_aarch64.a
PREBUILT_DIR="$SRC/.lp-cache/prebuilt-v8/$ZIG_V8_TAG"
mkdir -p "$PREBUILT_DIR"
cp "$V8_ARCHIVE" "$PREBUILT_DIR/libc_v8_${LIGHTPANDA_V8_VERSION}_android_aarch64.a"

# --- Zig build ---------------------------------------------------------------
# Embed the architecture-correct snapshot (generated with qemu-user) for fast
# startup; if unavailable lightpanda creates its snapshot at startup instead.
SNAP_OPT=""
if [ ! -s "$CACHE_DIR/lightpanda-snapshot.bin" ]; then
  log "No lightpanda snapshot — generating it with qemu-user..."
  "$SCRIPT_DIR/make-snapshots-qemu.sh" "$SRC_DIR/obscura" 1 "$SRC" || true
fi
if [ -s "$CACHE_DIR/lightpanda-snapshot.bin" ]; then
  cp "$CACHE_DIR/lightpanda-snapshot.bin" "$SRC/snapshot.bin"
  SNAP_OPT="-Dsnapshot_path=snapshot.bin"
  log "Embedding lightpanda snapshot"
fi

log "zig build lightpanda (android, ReleaseFast)..."
cd "$SRC"
ZIG_LOCAL_CACHE_DIR="$CACHE_DIR/lightpanda-zig-cache" \
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast $SNAP_OPT \
  --libc "$ANDROID_LIBC_FILE" \
  --cache-dir "$SRC/.zig-cache" \
  --global-cache-dir "$CACHE_DIR/zig-global" \
  --prefix "$DIST_DIR/lightpanda-${LIGHTPANDA_COMMIT}" 2>&1 | tail -40

BIN="$DIST_DIR/lightpanda-${LIGHTPANDA_COMMIT}/bin/lightpanda"
[ -f "$BIN" ] || die "lightpanda binary not produced"

log "ELF fixes..."
elf_fix "$BIN"

cp "$BIN" "$DIST_DIR/lightpanda"
echo "$LIGHTPANDA_COMMIT" > "$DIST_DIR/lightpanda-commit.txt"
log "Lightpanda android binary: $DIST_DIR/lightpanda ($(du -h "$DIST_DIR/lightpanda" | cut -f1))"
file "$BIN"
readelf -h "$BIN" | grep -E 'Type|Machine'
readelf -d "$BIN" | grep NEEDED || true