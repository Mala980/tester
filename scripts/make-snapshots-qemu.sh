#!/usr/bin/env bash
# Produce the architecture-correct V8 startup snapshots on the x86_64 runner
# using qemu-user + an aarch64-linux-gnu sysroot (no ARM hardware needed):
#
#   obscura snapshot : obscura-snapshot-helper built for aarch64-unknown-linux-gnu
#                      (v8 crate PREBUILT arm64 linux lib — no V8 compile),
#                      executed under qemu-aarch64, replicating obscura's build.rs
#   lightpanda snapshot: lightpanda snapshot_creator built for aarch64-linux-gnu
#                      (prebuilt linux-aarch64 libc_v8 from zig-v8-fork releases),
#                      executed under qemu-aarch64
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

export SNAPSHOT_DIR="${SNAPSHOT_DIR:-$WORK_DIR/cache}"
mkdir -p "$SNAPSHOT_DIR"

QEMU="${QEMU:-qemu-aarch64-static}"
QEMU_SYSROOT="${QEMU_SYSROOT:-/usr/aarch64-linux-gnu}"
QEMU_CMD="$QEMU -L $QEMU_SYSROOT"
command -v "$QEMU" >/dev/null 2>&1 || QEMU_CMD="/usr/bin/qemu-aarch64-static -L $QEMU_SYSROOT"

# ---------------------------------------------------------------------------
# Obscura snapshot
# ---------------------------------------------------------------------------
make_obscura_snapshot() {
  local obscura_src="${1:-$SRC_DIR/obscura}"
  local out="$SNAPSHOT_DIR/obscura-snapshot.bin"
  [ -s "$out" ] && log "obscura snapshot already exists: $out" && return 0

  log "Building obscura-snapshot-helper (aarch64-unknown-linux-gnu)..."
  local helper_dir="$SCRIPT_DIR/../tools/obscura-snapshot-helper"
  CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="$(which aarch64-linux-gnu-gcc)" \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-L /usr/aarch64-linux-gnu/lib" \
    CARGO_BUILD_JOBS="$JOBS" \
    cargo build --release --target aarch64-unknown-linux-gnu --manifest-path "$helper_dir/Cargo.toml"

  local helper="$helper_dir/target/aarch64-unknown-linux-gnu/release/obscura-snapshot-helper"
  log "Generating obscura snapshot under qemu..."
  $QEMU_CMD "$helper" "$obscura_src/crates/obscura-js/js/bootstrap.js" "$out"
  [ -s "$out" ] || die "obscura snapshot not produced"
  log "obscura snapshot: $out ($(du -h "$out" | cut -f1))"
}

# ---------------------------------------------------------------------------
# Lightpanda snapshot
# ---------------------------------------------------------------------------
make_lightpanda_snapshot() {
  local lp_src="${1:-$SRC_DIR/lightpanda}"
  local out="$SNAPSHOT_DIR/lightpanda-snapshot.bin"
  [ -s "$out" ] && log "lightpanda snapshot already exists: $out" && return 0
  ensure_zig

  local v8_archive="$CACHE_DIR/libc_v8_${LIGHTPANDA_V8_VERSION}_linux_aarch64.a"
  if [ ! -f "$v8_archive" ]; then
    log "Downloading prebuilt V8 linux-aarch64 archive..."
    curl -fL -o "$v8_archive" \
      "https://github.com/lightpanda-io/zig-v8-fork/releases/download/$ZIG_V8_TAG/libc_v8_${LIGHTPANDA_V8_VERSION}_linux_aarch64.a"
  fi

  if [ ! -d "$lp_src/.git" ]; then
    git clone --depth 1 "$LIGHTPANDA_REPO" "$lp_src"
  fi
  git -C "$lp_src" checkout -q main 2>/dev/null || true
  if ! grep -q 'exe.linkage = .dynamic' "$lp_src/build.zig"; then
    git -C "$lp_src" apply "$SCRIPT_DIR/../patches/lightpanda/build.zig-android.patch"
  fi

  # Place the prebuilt archive where build.zig discovers it
  local prebuilt="$lp_src/.lp-cache/prebuilt-v8/$ZIG_V8_TAG"
  mkdir -p "$prebuilt"
  cp "$v8_archive" "$prebuilt/libc_v8_${LIGHTPANDA_V8_VERSION}_linux_aarch64.a"

  log "Building lightpanda snapshot_creator (aarch64-linux-gnu)..."
  (cd "$lp_src" && zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseFast \
    --cache-dir "$CACHE_DIR/lightpanda-snap-zig-cache" \
    --global-cache-dir "$CACHE_DIR/zig-global" \
    snapshot_creator -- src/snapshot.bin) 2>&1 | tail -15

  [ -s "$lp_src/src/snapshot.bin" ] || die "lightpanda snapshot not produced"
  log "Generating lightpanda snapshot under qemu..."
  cp "$lp_src/src/snapshot.bin" "$out"
  log "lightpanda snapshot: $out ($(du -h "$out" | cut -f1))"
}

make_obscura_snapshot "${1:-$SRC_DIR/obscura}"
[ "${2:-1}" != "0" ] && make_lightpanda_snapshot "${3:-$SRC_DIR/lightpanda}"
log "Snapshots ready in $SNAPSHOT_DIR"