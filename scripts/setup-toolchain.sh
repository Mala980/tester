#!/usr/bin/env bash
# Install the cross-compilation toolchain on an Ubuntu x86_64 CI runner.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

log "Installing system packages..."
sudo apt-get update -y || true
sudo apt-get install -y --no-install-recommends \
  wget curl git unzip xz-utils zip rsync \
  python3 ninja-build build-essential pkg-config \
  cmake clang libclang-dev llvm-dev \
  golang-go ruby perl || true

# --- Zig -----------------------------------------------------------------
if [ ! -x "$ZIG_HOME/zig" ]; then
  log "Installing Zig $ZIG_VERSION"
  curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz" -o /tmp/zig.tar.xz
  tar -xf /tmp/zig.tar.xz -C /tmp
  sudo mkdir -p /opt
  sudo rm -rf "$ZIG_HOME"
  sudo mv "/tmp/zig-x86_64-linux-$ZIG_VERSION" "$ZIG_HOME"
fi
export PATH="$ZIG_HOME:$PATH"
log "Zig: $(zig version)"

# --- Android NDK r28b ------------------------------------------------------
if [ ! -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64" ]; then
  log "Downloading Android NDK r27d..."
  curl -fsSL "https://dl.google.com/android/repository/android-ndk-r27d-linux.zip" -o /tmp/ndk.zip
  sudo unzip -q /tmp/ndk.zip -d /opt/
  sudo mv "/opt/android-ndk-r27d" "$ANDROID_NDK_HOME"
  rm -f /tmp/ndk.zip
fi
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
log "NDK: $(cat "$ANDROID_NDK_HOME/source.properties" | grep Pkg.Revision || true)"

# --- Rust + android target -------------------------------------------------
if ! rustup target list --installed | grep -q "$RUST_TARGET"; then
  rustup target add "$RUST_TARGET"
fi

# Linker env for cargo cross builds
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android${ANDROID_API}-clang"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$NDK_BIN/llvm-ar"

# cc-rs (e.g. the `ring` crate) looks up the unversioned tool name on PATH.
ln -sf "aarch64-linux-android${ANDROID_API}-clang" "$NDK_BIN/aarch64-linux-android-clang"
ln -sf "aarch64-linux-android${ANDROID_API}-clang++" "$NDK_BIN/aarch64-linux-android-clang++"

# --- qemu-user + aarch64 sysroot (for snapshot generation under qemu) --------
if ! command -v qemu-aarch64-static >/dev/null 2>&1; then
  log "Installing qemu-user-static..."
  sudo apt-get install -y --no-install-recommends qemu-user-static
fi
if [ ! -d /usr/aarch64-linux-gnu/lib ]; then
  log "Installing aarch64-linux-gnu sysroot (gcc-aarch64-linux-gnu)..."
  sudo apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu
fi

log "Generating Zig libc file..."
gen_libc_file

log "Toolchain ready."
cat <<EOF
  Zig:            $ZIG_HOME ($(zig version))
  NDK:            $ANDROID_NDK_HOME (API $ANDROID_API)
  Rust target:    $RUST_TARGET
  Zig libc file:  $ANDROID_LIBC_FILE
EOF