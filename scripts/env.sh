#!/usr/bin/env bash
# Environment pins and shared helpers for the Android/Termux (aarch64) builds.
# Reference: https://github.com/Haris131/opencode-termux (NDK r28b, API 24)
set -euo pipefail

# ---------------------------------------------------------------------------
# Pins
# ---------------------------------------------------------------------------
export ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
export ANDROID_API="${ANDROID_API:-24}"
export ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-27.3.13750724}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-/opt/android-ndk}"
export ZIG_HOME="${ZIG_HOME:-/opt/zig}"

export TARGET_TRIPLE="aarch64-linux-android"
export RUST_TARGET="aarch64-linux-android"

# V8 pins (must match lightpanda's .github/actions/install/action.yml and
# build.zig.zon / zig-v8-fork pins)
export LIGHTPANDA_V8_VERSION="${LIGHTPANDA_V8_VERSION:-14.9.207.35}"
export ZIG_V8_TAG="${ZIG_V8_TAG:-v0.5.3}"
export ZIG_V8_FORK_COMMIT="${ZIG_V8_FORK_COMMIT:-57747955a59f09147b4dc1142152f0d960b2c7e1}"

# The v8 crate used by obscura (deno_core 0.350.0)
export OBSCURA_V8_CRATE_VERSION="${OBSCURA_V8_CRATE_VERSION:-137.3.0}"

# depot_tools for V8 builds
export DEPOT_TOOLS_DIR="${DEPOT_TOOLS_DIR:-$CACHE_DIR/depot_tools}"

# Upstreams
export LIGHTPANDA_REPO="${LIGHTPANDA_REPO:-https://github.com/lightpanda-io/browser.git}"
export OBSCURA_REPO="${OBSCURA_REPO:-https://github.com/h4ckf0r0day/obscura.git}"
export ZIG_V8_FORK_REPO="${ZIG_V8_FORK_REPO:-https://github.com/lightpanda-io/zig-v8-fork.git}"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
export WORK_DIR="${WORK_DIR:-/tmp/android-build}"
export SRC_DIR="$WORK_DIR/src"
export DIST_DIR="$WORK_DIR/dist"
export CACHE_DIR="$WORK_DIR/cache"

export NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
export NDK_SYSROOT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr"
export ANDROID_LIBC_FILE="$WORK_DIR/libc-android.txt"

# Build parallelism: keep RAM under control (15 GB runner)
export JOBS="${JOBS:-4}"
export NUM_JOBS="$JOBS"

mkdir -p "$WORK_DIR" "$SRC_DIR" "$DIST_DIR" "$CACHE_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# Write the Zig libc file pointing at the NDK sysroot. Zig 0.16 does not ship
# bionic; this file tells Zig where bionic headers/crt/libs live.
gen_libc_file() {
  local libdir="$NDK_SYSROOT/lib/aarch64-linux-android/$ANDROID_API"
  cat > "$ANDROID_LIBC_FILE" <<EOF
include_dir=$NDK_SYSROOT/include
sys_include_dir=$NDK_SYSROOT/include/aarch64-linux-android
crt_dir=$libdir
lib_dir=$libdir
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF
  log "libc file: $ANDROID_LIBC_FILE"
}

# Ensure the NDK is present, at $ANDROID_NDK_HOME (symlink is fine).
ensure_ndk() {
  if [ ! -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64" ]; then
    local real
    for d in "/opt/android-ndk-r${ANDROID_NDK_VERSION%%.*}" "/opt/android-ndk-r${ANDROID_NDK_VERSION%.*}" "/opt/android-ndk" "/usr/local/lib/android/sdk/ndk/$ANDROID_NDK_VERSION"; do
      if [ -d "$d/toolchains/llvm/prebuilt/linux-x86_64" ]; then real="$d"; break; fi
    done
    if [ -z "${real:-}" ]; then
      die "NDK not found at $ANDROID_NDK_HOME — run scripts/setup-toolchain.sh first"
    fi
    ln -sfn "$real" "$ANDROID_NDK_HOME"
  fi
  export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
  export PATH="$NDK_BIN:$PATH"
}

# Ensure Zig is present.
ensure_zig() {
  if [ ! -x "$ZIG_HOME/zig" ]; then
    die "Zig not found at $ZIG_HOME — run scripts/setup-toolchain.sh first"
  fi
  export PATH="$ZIG_HOME:$PATH"
}

# Apply the Android ELF fixes (TLS p_align=64, RELRO align=16384) that bionic
# requires, the same thing `termux-elf-cleaner` does on device.
elf_fix() {
  python3 "$(dirname "$(readlink -f "$0")")/elf-fix.py" "$@"
}