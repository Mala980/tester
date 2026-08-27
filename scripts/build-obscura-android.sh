#!/usr/bin/env bash
# Build Obscura for Android/Termux (aarch64-linux-android, bionic, PIE).
# Variants: render (default), no-render, render+stealth
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
ensure_ndk

# Obscura's V8 libc++ needs bionic symbols introduced in API 26 (strtof_l,
# strtod_l), so the obscura binary links against the API 26 stubs (the device
# runtime provides them on any Android 8.0+ device).
export OBSCURA_API="${OBSCURA_API:-26}"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android${OBSCURA_API}-clang"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$NDK_BIN/llvm-ar"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
# cc-rs (ring) needs the unversioned tool names on PATH
sudo ln -sf "aarch64-linux-android${OBSCURA_API}-clang" "$NDK_BIN/aarch64-linux-android-clang"
sudo ln -sf "aarch64-linux-android${OBSCURA_API}-clang++" "$NDK_BIN/aarch64-linux-android-clang++"
export PATH="$NDK_BIN:$PATH"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android${OBSCURA_API}-clang"
export CXX_aarch64_linux_android="$NDK_BIN/aarch64-linux-android${OBSCURA_API}-clang++"
export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"
# v8 crate build.rs honours CXXSTDLIB and btls-sys honours
# BORING_BSSL_RUST_CPPLIB to pick the C++ runtime. Static-link libc++
# (libc++_static.a from the NDK, includes libc++abi) so binaries carry ALL
# C++ symbols internally — including __ndk1 internals that the SYSTEM
# /system/lib64/libc++.so does NOT export (e.g. std::__ndk1::__sort).
# Result: zero bundled .so files, runs anywhere without LD_PRELOAD.
export CXXSTDLIB="c++_static"
export BORING_BSSL_RUST_CPPLIB="c++_static"
# __clear_cache comes from the NDK compiler-rt; rustc's -nodefaultlibs link
# doesn't pull it, so inject the archive at the final link.
CLANG_VER=$(ls "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/" 2>/dev/null | sort -n | tail -1)
export OBSCURA_RT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/$CLANG_VER/lib/linux/libclang_rt.builtins-aarch64-android.a"
if [ ! -f "$OBSCURA_RT" ]; then
  OBSCURA_RT=$(find "$ANDROID_NDK_HOME" -name 'libclang_rt.builtins-aarch64-android.a' 2>/dev/null | head -1)
fi
if [ -z "$OBSCURA_RT" ] || [ ! -f "$OBSCURA_RT" ]; then
  die "libclang_rt.builtins-aarch64-android.a not found in NDK"
fi
log "OBSCURA_RT=$OBSCURA_RT"
export LIBCLANG_PATH="${LIBCLANG_PATH:-$(find /usr/lib/llvm-* /usr/lib/llvm-*/lib "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib" -maxdepth 2 -name 'libclang.so*' 2>/dev/null | head -1 | xargs -r dirname)}"

SRC="$SRC_DIR/obscura"
if [ ! -d "$SRC/.git" ]; then
  log "Cloning obscura ($OBSCURA_BRANCH)"
  git clone --depth 1 --branch "$OBSCURA_BRANCH" "$OBSCURA_REPO" "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$OBSCURA_BRANCH" 2>/dev/null || true
git -C "$SRC" checkout -q FETCH_HEAD 2>/dev/null || git -C "$SRC" checkout -q "$OBSCURA_BRANCH"
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

# Ensure the v8 crate is downloaded before repair (cargo fetch from obscura manifest)
log "Fetching v8 crate dependencies..."
V8_FROM_SOURCE=1 cargo fetch --manifest-path "$SRC/Cargo.toml" 2>/dev/null || true

v8_crate_dir=$(ls -d "$HOME/.cargo/registry/src/"*/v8-${OBSCURA_V8_CRATE_VERSION} 2>/dev/null | head -1)
if [ -z "$v8_crate_dir" ]; then
  # v8 crate might not be in registry yet; download it manually
  log "v8 crate not in registry, downloading..."
  cargo download v8==$OBSCURA_V8_CRATE_VERSION 2>/dev/null || \
    (mkdir -p /tmp/v8-fetch && cd /tmp/v8-fetch && cargo init --name v8-fetch && \
     echo '[dependencies]
v8 = "=137.3.0"' > Cargo.toml && V8_FROM_SOURCE=1 cargo fetch 2>/dev/null)
  v8_crate_dir=$(ls -d "$HOME/.cargo/registry/src/"*/v8-${OBSCURA_V8_CRATE_VERSION} 2>/dev/null | head -1)
fi
log "v8 crate dir: ${v8_crate_dir:-NOT FOUND}"

if [ -n "$v8_crate_dir" ] && [ ! -e "$v8_crate_dir/third_party/android_toolchain/ndk" ]; then
  mkdir -p "$v8_crate_dir/third_party/android_toolchain"
  ln -sfn "$ANDROID_NDK_HOME" "$v8_crate_dir/third_party/android_toolchain/ndk"
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
  # Link against the system libc++.so instead of libc++_shared.so so the
  # binary has NO bundled .so dependency (default/no-render variants already
  # work this way). System /system/lib64/libc++.so uses the __ndk1 namespace,
  # same as the NDK runtime, so symbols resolve on any Android 8+ device.
  if grep -q 'c++_shared' "$v8_crate_dir/build.rs" 2>/dev/null; then
    sed -i 's/c++_shared/c++/g' "$v8_crate_dir/build.rs"
    log "patched v8 crate: c++_shared -> c++ (system libc++)"
  fi
  local d="$b/android/pylib/results/presentation"
  mkdir -p "$d/javascript" "$d/template"
  for f in __init__.py standard_gtest_merge.py test_results_presentation.py test_results_presentation.pydeps; do
    curl -fsSL "https://chromium.googlesource.com/chromium/src/build/+/main/android/pylib/results/presentation/$f?format=TEXT" | base64 -d > "$d/$f" 2>/dev/null || true
  done
  for sub in javascript template; do
    for f in $(curl -fsSL "https://chromium.googlesource.com/chromium/src/build/+/main/android/pylib/results/presentation/$sub/?format=JSON" 2>/dev/null | tail -n +2 | python3 -c "import json,sys; print(' '.join(e['name'] for e in json.load(sys.stdin)['entries']))" 2>/dev/null); do
      curl -fsSL "https://chromium.googlesource.com/chromium/src/build/+/main/android/pylib/results/presentation/$sub/$f?format=TEXT" | base64 -d > "$d/$sub/$f" 2>/dev/null || true
    done
  done
  # All pydeps files referenced by build/android/BUILD.gn and v8/tools/BUILD.gn
  for f in protoc_java android/apk_operations android/devil_chromium android/resource_sizes android/test_runner android/test_wrapper/logdog_wrapper android/test_wrapper/setup; do
    mkdir -p "$(dirname "$b/$f.pydeps")"
    [ -f "$b/$f.pydeps" ] || curl -fsSL "https://chromium.googlesource.com/chromium/src/build/+/main/${f}.pydeps?format=TEXT" | base64 -d > "$b/$f.pydeps" 2>/dev/null || true
  done
  # Also ensure gyp files exist
  mkdir -p "$b/android/test_wrapper"
  [ -f "$b/android/test_wrapper/paths.py" ] || curl -fsSL "https://chromium.googlesource.com/chromium/src/build/+/main/android/test_wrapper/paths.py?format=TEXT" | base64 -d > "$b/android/test_wrapper/paths.py" 2>/dev/null || true
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
                    // libc++ headers MUST precede the C library headers
                    format!("-isystem{sysroot}/usr/include/c++/v1"),
                    format!("-isystem{sysroot}/usr/include"),
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

# Ensure LIBCLANG_PATH is always set for bindgen (not just inside repair_v8_crate)
export LIBCLANG_PATH="${LIBCLANG_PATH:-$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib}"
if [ ! -f "$LIBCLANG_PATH/libclang.so" ]; then
  # Fallback: search for libclang.so in NDK and system
  LIBCLANG_PATH=$(find "$ANDROID_NDK_HOME" /usr/lib/llvm-* -name 'libclang.so*' 2>/dev/null | head -1 | xargs -r dirname)
  export LIBCLANG_PATH
fi
log "LIBCLANG_PATH=$LIBCLANG_PATH"

# Final link needs the NDK compiler-rt (__clear_cache); rustc's -nodefaultlibs
# link omits it. Write config.toml to both workspace AND $CARGO_HOME so cargo
# definitely picks it up.
mkdir -p "$SRC/.cargo"
cat > "$SRC/.cargo/config.toml" <<EOF
[target.aarch64-linux-android]
rustflags = ["-C", "link-arg=$OBSCURA_RT"]
EOF
mkdir -p "$HOME/.cargo"
cat > "$HOME/.cargo/config.toml" <<EOF
[target.aarch64-linux-android]
rustflags = ["-C", "link-arg=$OBSCURA_RT"]
EOF
log "cargo config written: $SRC/.cargo/config.toml + $HOME/.cargo/config.toml"

# Force a fresh final link: cargo does NOT fingerprint env vars like
# CXXSTDLIB/BORING_BSSL_RUST_CPPLIB, so with a cached target dir the old
# binary (possibly linked against libc++_shared.so) would be reused as-is.
rm -f "$CARGO_TARGET_DIR/$RUST_TARGET/release/obscura" \
      "$CARGO_TARGET_DIR/$RUST_TARGET/release/obscura-worker"

# Name-and-shame any build script that still emits c++_shared link flags.
# Use -F (fixed string): BRE \+ is a quantifier, NOT an escaped plus.
grep -rlF 'rustc-link-lib=c++_shared' \
  "$CARGO_TARGET_DIR/$RUST_TARGET/release/build/"*/output 2>/dev/null | while read -r f; do
  log "WARNING: $(basename "$(dirname "$f")") emits c++_shared link flag"
done || true

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
  # If anything still linked against libc++_shared.so, rewrite the DT_NEEDED
  # entry to the system libc++.so (same __ndk1 ABI on Android 8+).
  if readelf -d "$out/obscura" | grep -q 'libc++_shared'; then
    log "$name: replacing NEEDED libc++_shared.so -> libc++.so"
    for b in obscura obscura-worker; do
      patchelf --replace-needed libc++_shared.so libc++.so "$out/$b"
    done
  fi
  # Hard gate: no binary may depend on a bundled libc++_shared.so.
  if readelf -d "$out/obscura" | grep -q 'libc++_shared'; then
    die "$name: obscura still NEEDs libc++_shared.so after replace-needed"
  fi
  log "staged: $out (no bundled .so — links system libc++.so)"
}

stage_bins "default"   # render

if [ "${BUILD_NO_RENDER:-1}" = "1" ]; then
  log "Building obscura (no-render)..."
  V8_FROM_SOURCE=1 NUM_JOBS="$JOBS" CARGO_BUILD_JOBS="$JOBS" \
    OBSCURA_SNAPSHOT_FILE="$SNAPSHOT_FILE" \
    CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
    cargo build --release --target "$RUST_TARGET" \
    --manifest-path "$SRC/Cargo.toml" -p obscura-cli --bins --no-default-features
  stage_bins "no-render"

  if [ "${BUILD_STEALTH:-1}" = "1" ]; then
    log "Building obscura (no-render-stealth)..."
    V8_FROM_SOURCE=1 NUM_JOBS="$JOBS" CARGO_BUILD_JOBS="$JOBS" \
      OBSCURA_SNAPSHOT_FILE="$SNAPSHOT_FILE" \
      CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
      cargo build --release --target "$RUST_TARGET" \
      --manifest-path "$SRC/Cargo.toml" -p obscura-cli --bins --no-default-features --features stealth
    stage_bins "no-render-stealth"
  fi
fi

if [ "${BUILD_STEALTH:-1}" = "1" ]; then
  log "Building obscura (render+stealth — BoringSSL via btls-sys)..."
  V8_FROM_SOURCE=1 NUM_JOBS="$JOBS" CARGO_BUILD_JOBS="$JOBS" \
    OBSCURA_SNAPSHOT_FILE="$SNAPSHOT_FILE" \
    CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
    cargo build --release --target "$RUST_TARGET" \
    --manifest-path "$SRC/Cargo.toml" -p obscura-cli --bins --features render,stealth
  stage_bins "stealth"

  log "Building obscura (full release — render+stealth+websocket+canvas2d)..."
  V8_FROM_SOURCE=1 NUM_JOBS="$JOBS" CARGO_BUILD_JOBS="$JOBS" \
    OBSCURA_SNAPSHOT_FILE="$SNAPSHOT_FILE" \
    CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
    cargo build --release --target "$RUST_TARGET" \
    --manifest-path "$SRC/Cargo.toml" -p obscura-cli --bins \
    --features render,stealth,websocket,canvas2d
  stage_bins "full"
fi

echo "$OBSCURA_COMMIT" > "$DIST_DIR/obscura-commit.txt"
log "Obscura android binaries staged in $DIST_DIR"
for d in "$DIST_DIR"/obscura-*; do
  [ -d "$d" ] && echo "  $d" && file "$d/obscura" | cut -d: -f2 && readelf -d "$d/obscura" | grep -E 'NEEDED' | head -5
done