#!/usr/bin/env bash
# Build Obscura for Android/Termux (aarch64-linux-android, bionic, PIE).
# Variants: render (default), no-render, render+stealth
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
ensure_ndk

export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android${ANDROID_API}-clang"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$NDK_BIN/llvm-ar"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export ANDROID_NDK_HOME="$ANDROID_NDK_HOME"
# cc-rs (ring) needs the unversioned tool names on PATH
ln -sf "aarch64-linux-android${ANDROID_API}-clang" "$NDK_BIN/aarch64-linux-android-clang"
ln -sf "aarch64-linux-android${ANDROID_API}-clang++" "$NDK_BIN/aarch64-linux-android-clang++"
export PATH="$NDK_BIN:$PATH"
export CC_aarch64-linux-android="$NDK_BIN/aarch64-linux-android${ANDROID_API}-clang"
export AR_aarch64-linux-android="$NDK_BIN/llvm-ar"
export LIBCLANG_PATH="${LIBCLANG_PATH:-$(dirname "$(find /usr/lib/llvm-*/lib -name 'libclang.so*' 2>/dev/null | head -1)")}"

SRC="$SRC_DIR/obscura"
if [ ! -d "$SRC/.git" ]; then
  log "Cloning obscura"
  git clone --depth 1 "$OBSCURA_REPO" "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin main 2>/dev/null || true
git -C "$SRC" checkout -q FETCH_HEAD 2>/dev/null || git -C "$SRC" checkout -q main
OBSCURA_COMMIT=$(git -C "$SRC" rev-parse --short HEAD)
log "Obscura @ $OBSCURA_COMMIT"

# Apply the snapshot-injection patch (idempotent)
if ! grep -q 'OBSCURA_SNAPSHOT_FILE' "$SRC/crates/obscura-js/build.rs"; then
  git -C "$SRC" apply "$SCRIPT_DIR/../patches/obscura/build-rs-snapshot.patch"
fi

# --- Architecture-correct V8 snapshot ---------------------------------------
# Generated with qemu-user (scripts/make-snapshots-qemu.sh) using the v8 crate's
# prebuilt aarch64-linux-gnu library; see also scripts/snapshot-arm64.sh for the
# native-ARM-runner alternative.
SNAPSHOT_FILE="${OBSCURA_SNAPSHOT_FILE:-$CACHE_DIR/obscura-snapshot.bin}"
if [ -f "$SNAPSHOT_FILE" ] && [ -s "$SNAPSHOT_FILE" ]; then
  log "Using ARM64 snapshot: $SNAPSHOT_FILE ($(du -h "$SNAPSHOT_FILE" | cut -f1))"
else
  log "No snapshot present — generating it with qemu-user..."
  "$SCRIPT_DIR/make-snapshots-qemu.sh" "$SRC_DIR/obscura" 0 || true
  SNAPSHOT_FILE="$CACHE_DIR/obscura-snapshot.bin"
  if [ ! -s "$SNAPSHOT_FILE" ]; then
    die "Failed to generate the ARM64 V8 snapshot (required by obscura)"
  fi
fi
export OBSCURA_SNAPSHOT_FILE="$SNAPSHOT_FILE"

# --- Build the v8 crate from source for android (once, cached) --------------
# deno's v8 crate 137.3.0 supports `V8_FROM_SOURCE=1 cargo build --target
# aarch64-linux-android`. It downloads an NDK itself unless we pre-seed
# third_party/android_ndk; V8's sources are vendored inside the crate.
v8_crate_dir=$(ls -d "$HOME/.cargo/registry/src/"*/v8-${OBSCURA_V8_CRATE_VERSION} 2>/dev/null | head -1)
if [ -n "$v8_crate_dir" ] && [ ! -e "$v8_crate_dir/third_party/android_ndk" ]; then
  ln -sfn "$ANDROID_NDK_HOME" "$v8_crate_dir/third_party/android_ndk"
fi

# Pre-built librusty_v8.a cache: skip the full V8 re-compile if cached
V8_LIB_CACHE="$CACHE_DIR/librusty_v8_release_aarch64-linux-android.a"
CARGO_TARGET_DIR="$CACHE_DIR/obscura-target"

# The crates.io tarball of the v8 crate omits several build/android and pylib
# files; gn gen fails without them. Restore from Chromium's build repo.
# Also patch its bindgen clang args so android parsing uses the NDK sysroot
# and target (host libclang + glibc headers cannot parse NDK libc++).
repair_v8_crate() {
  local b="$v8_crate_dir/build"
  local d="$b/android/pylib/results/presentation"
  mkdir -p "$d/javascript" "$d/template"
  for f in __init__.py standard_gtest_merge.py test_results_presentation.py test_results_presentation.pydeps; do
    curl -fsSL "https://chromium.googlesource.com/chromium/src/build/+/main/android/pylib/results/presentation/$f?format=TEXT" | base64 -d > "$d/$f"
  done
  for sub in javascript template; do
    for f in $(curl -fsSL "https://chromium.googlesource.com/chromium/src/build/+/main/android/pylib/results/presentation/$sub/?format=JSON" 2>/dev/null | tail -n +2 | python3 -c "import json,sys; print(' '.join(e['name'] for e in json.load(sys.stdin)['entries']))"); do
      curl -fsSL "https://chromium.googlesource.com/chromium/src/build/+/main/android/pylib/results/presentation/$sub/$f?format=TEXT" | base64 -d > "$d/$sub/$f"
    done
  done
  for f in protoc_java android/apk_operations android/devil_chromium android/resource_sizes android/test_runner; do
    [ -f "$b/$f.pydeps" ] || curl -fsSL "https://chromium.googlesource.com/chromium/src/build/+/main/${f}.pydeps?format=TEXT" | base64 -d > "$b/$f.pydeps" || true
  done
  # bindgen needs the NDK sysroot + target for android (registry patch)
  local br="$v8_crate_dir/build.rs"
  if ! grep -q 'isystem{sysroot}/usr/include/c++/v1' "$br"; then
    python3 - "$br" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    .clang_args(["-x", "c++", "-std=c++20", "-Iv8/include", "-I."])'
new = '''    .clang_args(["-x", "c++", "-std=c++20", "-Iv8/include", "-I."])
    .clang_args(
        std::env::var("ANDROID_NDK_HOME")
            .map(|ndk| {
                let sysroot = format!(
                    "{ndk}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
                );
                vec![
                    "--target=aarch64-linux-android24".to_string(),
                    format!("--sysroot={sysroot}"),
                    format!("-isystem{sysroot}/usr/include"),
                    format!("-isystem{sysroot}/usr/include/c++/v1"),
                ]
            })
            .unwrap_or_default(),
    )'''
assert old in s, "bindgen clang_args not found"
open(p, "w").write(s.replace(old, new))
print("patched bindgen clang args")
PY2
  fi
  export LIBCLANG_PATH="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib"
}
[ -n "$v8_crate_dir" ] && repair_v8_crate

log "Building obscura (render) for $RUST_TARGET — V8 from source, this is the long step..."
V8_FROM_SOURCE=1 NUM_JOBS="$JOBS" CARGO_BUILD_JOBS="$JOBS" \
  CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
  cargo build --release --target "$RUST_TARGET" \
  --manifest-path "$SRC/Cargo.toml" -p obscura-cli --bins --features render

# Cache the v8 static lib for subsequent runs
V8_LIB=$(find "$CARGO_TARGET_DIR" -name 'librusty_v8.a' -path '*release*' | head -1)
[ -n "$V8_LIB" ] && cp "$V8_LIB" "$V8_LIB_CACHE" && log "v8 lib cached: $V8_LIB_CACHE"

stage_bins() {
  local name="$1"; shift
  local out="$DIST_DIR/obscura-$name"
  mkdir -p "$out"
  cp "$CARGO_TARGET_DIR/$RUST_TARGET/release/obscura" "$out/obscura"
  cp "$CARGO_TARGET_DIR/$RUST_TARGET/release/obscura-worker" "$out/obscura-worker"
  elf_fix "$out/obscura" "$out/obscura-worker"
  # bionic needs libc++_shared.so for the v8 crate's c++_shared link; bundle it
  cp "$NDK_SYSROOT/usr/lib/aarch64-linux-android/libc++_shared.so" "$out/" 2>/dev/null || true
  log "staged: $out"
}

stage_bins "default"   # render

if [ "${BUILD_NO_RENDER:-1}" = "1" ]; then
  log "Building obscura (no-render)..."
  V8_FROM_SOURCE=1 NUM_JOBS="$JOBS" CARGO_BUILD_JOBS="$JOBS" \
    CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
    cargo build --release --target "$RUST_TARGET" \
    --manifest-path "$SRC/Cargo.toml" -p obscura-cli --bins --no-default-features
  stage_bins "no-render"
fi

if [ "${BUILD_STEALTH:-1}" = "1" ]; then
  log "Building obscura (render+stealth — BoringSSL via btls-sys)..."
  V8_FROM_SOURCE=1 NUM_JOBS="$JOBS" CARGO_BUILD_JOBS="$JOBS" \
    CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
    cargo build --release --target "$RUST_TARGET" \
    --manifest-path "$SRC/Cargo.toml" -p obscura-cli --bins --features render,stealth
  stage_bins "stealth"
fi

echo "$OBSCURA_COMMIT" > "$DIST_DIR/obscura-commit.txt"
log "Obscura android binaries staged in $DIST_DIR"
for d in "$DIST_DIR"/obscura-*; do
  [ -d "$d" ] && echo "  $d" && file "$d/obscura" | cut -d: -f2 && readelf -d "$d/obscura" | grep -E 'NEEDED' | head -5
done