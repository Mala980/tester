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
  log "Patching build.zig for Android..."
  git -C "$SRC" apply "$SCRIPT_DIR/../patches/lightpanda/build.zig-android.patch" 2>/dev/null || \
  python3 - "$SRC/build.zig" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()

# Patch 1: Add PIE + dynamic linkage for Android in addExe()
old1 = "    const exe_check = b.addLibrary(.{"
new1 = """    // Android requires position-independent executables; Zig 0.16 defaults to
    // static non-PIE for `aarch64-linux-android`, which bionic rejects.
    if (config.target.result.abi.isAndroid()) {
        exe.pie = true;
        exe.linkage = .dynamic;
    }

    const exe_check = b.addLibrary(.{"""
assert old1 in s, "addExe patch point not found"
s = s.replace(old1, new1, 1)

# Patch 2: Add is_android in linkRust()
old2 = "    const is_debug = mod.optimize.? == .Debug;\n\n    // One cargo workspace"
new2 = "    const is_debug = mod.optimize.? == .Debug;\n    const is_android = mod.resolved_target.?.result.abi.isAndroid();\n\n    // One cargo workspace"
assert old2 in s, "is_android patch point not found"
s = s.replace(old2, new2, 1)

# Patch 3: Add --target for android cargo build
old3 = '        "--manifest-path", "src/rust/ffi/Cargo.toml",\n    });\n\n    addDirInputs'
new3 = '''        "--manifest-path", "src/rust/ffi/Cargo.toml",
    });

    // Cross-compiling for Android: cargo must target the android triple
    if (is_android) {
        exec_cargo.addArgs(&.{ "--target", "aarch64-linux-android" });
    }

    addDirInputs'''
assert old3 in s, "cargo target patch point not found"
s = s.replace(old3, new3, 1)

# Patch 4: Fix the object path for android triple
old4 = '    const obj = out_dir.path(b, if (is_debug) "debug" else "release").path(b, "liblightpanda_ffi.a");'
new4 = """    const obj = if (is_android)
        out_dir.path(b, "aarch64-linux-android").path(b, if (is_debug) "debug" else "release").path(b, "liblightpanda_ffi.a")
    else
        out_dir.path(b, if (is_debug) "debug" else "release").path(b, "liblightpanda_ffi.a");"""
assert old4 in s, "obj path patch point not found"
s = s.replace(old4, new4, 1)

open(p, "w").write(s)
print("build.zig patched for Android")
PYEOF
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
  # Only build the lightpanda snapshot (skip obscura=0)
  "$SCRIPT_DIR/make-snapshots-qemu.sh" "" 0 "$SRC" || true
fi
if [ -s "$CACHE_DIR/lightpanda-snapshot.bin" ]; then
  cp "$CACHE_DIR/lightpanda-snapshot.bin" "$SRC/snapshot.bin"
  SNAP_OPT="-Dsnapshot_path=snapshot.bin"
  log "Embedding lightpanda snapshot"
fi

# --- Diagnostic: translate each C header individually -----------------------
# zig build swallows translate-c error details; running `zig translate-c`
# directly on each header surfaces the real errors early in the log.
log "Diagnostic: translating C headers for aarch64-linux-android..."
for hdr in \
  "$SRC"/zig-pkg/*/include/curl/curl.h \
  "$SRC"/zig-pkg/*/include/isocline.h; do
  [ -f "$hdr" ] || continue
  if zig translate-c "$hdr" -target aarch64-linux-android \
      --libc "$ANDROID_LIBC_FILE" -lc > /dev/null 2>"$hdr.err"; then
    log "translate-c OK: $hdr"
    rm -f "$hdr.err"
  else
    log "translate-c FAILED: $hdr"
    cat "$hdr.err" || true
  fi
done

log "zig build lightpanda (android, ReleaseFast)..."
cd "$SRC"
ZIG_LOCAL_CACHE_DIR="$CACHE_DIR/lightpanda-zig-cache" \
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast $SNAP_OPT \
  --libc "$ANDROID_LIBC_FILE" \
  --cache-dir "$SRC/.zig-cache" \
  --global-cache-dir "$CACHE_DIR/zig-global" \
  --prefix "$DIST_DIR/lightpanda-${LIGHTPANDA_COMMIT}" 2>&1 | tee "$CACHE_DIR/build-lightpanda.log" | tail -50

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