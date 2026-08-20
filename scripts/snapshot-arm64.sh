#!/usr/bin/env bash
# Runs on a native ARM64 runner (ubuntu-24.04-arm) to produce the
# architecture-correct V8 snapshots for the Android build:
#   - obscura snapshot  : built by obscura-js build.rs for aarch64-linux-gnu
#                         using the v8 crate's PREBUILT arm64 linux lib
#   - lightpanda snapshot: built by lightpanda's snapshot_creator (native)
# Uses native arch so no qemu/bionic runtime is needed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

export WORK_DIR="${WORK_DIR:-/tmp/android-build-arm}"
mkdir -p "$WORK_DIR"
export DIST_DIR="$WORK_DIR/dist"
export SRC_DIR="$WORK_DIR/src"
export CACHE_DIR="$WORK_DIR/cache"
mkdir -p "$DIST_DIR" "$SRC_DIR" "$CACHE_DIR"

# ---- Obscura snapshot ------------------------------------------------------
if [ "${BUILD_OBSCURA:-1}" = "1" ]; then
  SRC="$SRC_DIR/obscura"
  if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 "$OBSCURA_REPO" "$SRC"
  fi
  git -C "$SRC" checkout -q main 2>/dev/null || true
  if ! grep -q 'OBSCURA_SNAPSHOT_OUT' "$SRC/crates/obscura-js/build.rs"; then
    git -C "$SRC" apply "$SCRIPT_DIR/../patches/obscura/build-rs-snapshot.patch"
  fi
  log "Building obscura-js natively on arm64 to produce the snapshot..."
  # Prebuilt aarch64-unknown-linux-gnu V8 is downloaded by the v8 crate.
  CARGO_TARGET_DIR="$CACHE_DIR/obscura-target-arm" \
    OBSCURA_SNAPSHOT_OUT="$DIST_DIR/obscura-snapshot.bin" \
    cargo build --release --target aarch64-unknown-linux-gnu \
    --manifest-path "$SRC/Cargo.toml" -p obscura-js --features render 2>&1 | tail -5
  [ -s "$DIST_DIR/obscura-snapshot.bin" ] || die "obscura snapshot not produced"
  log "obscura snapshot: $DIST_DIR/obscura-snapshot.bin ($(du -h "$DIST_DIR/obscura-snapshot.bin" | cut -f1))"
fi

# ---- Lightpanda snapshot ----------------------------------------------------
if [ "${BUILD_LIGHTPANDA:-1}" = "1" ]; then
  if [ ! -x "$ZIG_HOME/zig" ]; then
    log "Installing Zig $ZIG_VERSION (aarch64)"
    curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-linux-$ZIG_VERSION.tar.xz" -o /tmp/zig-arm.tar.xz
    tar -xf /tmp/zig-arm.tar.xz -C /tmp
    sudo mkdir -p /opt
    sudo rm -rf "$ZIG_HOME"
    sudo mv "/tmp/zig-aarch64-linux-$ZIG_VERSION" "$ZIG_HOME"
  fi
  export PATH="$ZIG_HOME:$PATH"

  SRC="$SRC_DIR/lightpanda"
  if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 "$LIGHTPANDA_REPO" "$SRC"
  fi
  git -C "$SRC" checkout -q main 2>/dev/null || true
  if ! grep -q 'exe.linkage = .dynamic' "$SRC/build.zig"; then
    git -C "$SRC" apply "$SCRIPT_DIR/../patches/lightpanda/build.zig-android.patch"
  fi

  log "Downloading prebuilt V8 (linux aarch64) and building snapshot_creator..."
  # fetch the prebuilt libc_v8 archive for linux-aarch64 via the Makefile
  cd "$SRC"
  ZIG_LOCAL_CACHE_DIR="$CACHE_DIR/zig-cache-arm" make download-v8 2>&1 | tail -3 || true
  ZIG_LOCAL_CACHE_DIR="$CACHE_DIR/zig-cache-arm" \
    zig build -Doptimize=ReleaseFast snapshot_creator -- src/snapshot.bin 2>&1 | tail -5
  [ -s src/snapshot.bin ] || die "lightpanda snapshot not produced"
  cp src/snapshot.bin "$DIST_DIR/lightpanda-snapshot.bin"
  log "lightpanda snapshot: $DIST_DIR/lightpanda-snapshot.bin ($(du -h "$DIST_DIR/lightpanda-snapshot.bin" | cut -f1))"
fi

log "Snapshots ready in $DIST_DIR"