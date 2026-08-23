#!/bin/bash
set -euo pipefail

# Build V8 for Android/Termux aarch64
# Reference: https://v8.dev/docs/cross-compile-arm

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

DEPOT_TOOLS_DIR="${DEPOT_TOOLS_DIR:-$CACHE_DIR/depot_tools}"

# Create work directory
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Install depot_tools if not available
if [ ! -d "$DEPOT_TOOLS_DIR" ]; then
    log "Installing depot_tools..."
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_DIR"
fi

export PATH="$DEPOT_TOOLS_DIR:$PATH"

# Fetch V8 source if not exists
if [ ! -d "v8" ]; then
    log "Fetching V8 source..."
    fetch v8
    cd v8
    git checkout "tags/${LIGHTPANDA_V8_VERSION}" -b build || git checkout "main"
else
    cd v8
    git pull
fi

# Sync dependencies
log "Syncing dependencies..."
gclient sync

# Set up build directory
BUILD_DIR="out/android-arm64"
mkdir -p "$BUILD_DIR"

# Create args.gn for Android ARM64 build
log "Creating build configuration..."
cat > "$BUILD_DIR/args.gn" << EOF
# Target configuration
target_os = "android"
target_cpu = "arm64"
v8_target_cpu = "arm64"

# Build type
is_debug = false
is_component_build = false
is_official_build = true

# V8 configuration
v8_monolithic = true
v8_static_library = true
v8_use_external_startup_data = false
v8_enable_pointer_compression = false
v8_enable_webassembly = false
v8_enable_i18n_support = true
v8_enable_handle_zapping = false
v8_enable_test_features = false
v8_enable_temporal_support = false
v8_enable_builtins_optimization = true
v8_enable_sandbox = false

# Compiler settings
is_clang = true
clang_use_chrome_plugins = false
use_custom_libcxx = false
use_custom_libcxx_for_host = true
use_thin_lto = false
use_lld = true

# Android NDK configuration
android_ndk_root = "${ANDROID_NDK_HOME}"
android_ndk_version = "r28b"
android_ndk_api_level = ${ANDROID_API}

# Debug info
strip_debug_info = true
symbol_level = 0
v8_symbol_level = 0

# Other settings
dcheck_always_on = false
icu_use_data_file = false
use_libfuzzer = false
v8_android_log_stdout = true
chrome_pgo_phase = 0
enable_resource_allowlist_generation = false
use_blink = false
EOF

# Generate build files
log "Generating build files..."
gn gen "$BUILD_DIR"

# Build V8
log "Building V8 (this may take 30-60 minutes)..."
ninja -C "$BUILD_DIR" v8_monolith

# Check if build succeeded
if [ -f "$BUILD_DIR/obj/libv8_monolith.a" ]; then
    log "V8 build successful!"
    
    # Create output directory
    mkdir -p "$WORK_DIR/output"
    
    # Copy library
    cp "$BUILD_DIR/obj/libv8_monolith.a" "$WORK_DIR/output/"
    
    # Copy headers if they exist
    if [ -d "include" ]; then
        cp -r include "$WORK_DIR/output/"
    fi
    
    log "V8 library created: $WORK_DIR/output/libv8_monolith.a"
    ls -lh "$WORK_DIR/output/libv8_monolith.a"
else
    die "V8 build failed - libv8_monolith.a not found"
fi