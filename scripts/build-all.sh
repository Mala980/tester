#!/bin/bash
set -euo pipefail

# Main build script for Obscura and Lightpanda on Android/Termux aarch64
# Reference: https://github.com/Haris131/opencode-termux

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# Parse command line arguments
BUILD_V8=false
BUILD_OBSCURA=false
BUILD_LIGHTPANDA=false
BUILD_ALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --v8)
            BUILD_V8=true
            shift
            ;;
        --obscura)
            BUILD_OBSCURA=true
            shift
            ;;
        --lightpanda)
            BUILD_LIGHTPANDA=true
            shift
            ;;
        --all)
            BUILD_ALL=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --v8           Build V8 only"
            echo "  --obscura      Build Obscura only"
            echo "  --lightpanda   Build Lightpanda only"
            echo "  --all          Build V8 and both projects"
            echo "  --help         Show this help message"
            echo ""
            echo "Environment variables (defaults from env.sh):"
            echo "  WORK_DIR       Working directory (default: $WORK_DIR)"
            echo "  ANDROID_API    Android API level (default: $ANDROID_API)"
            echo "  ANDROID_NDK_HOME  Android NDK path (default: $ANDROID_NDK_HOME)"
            echo "  ZIG_VERSION    Zig version (default: $ZIG_VERSION)"
            echo "  LIGHTPANDA_V8_VERSION  V8 version for lightpanda (default: $LIGHTPANDA_V8_VERSION)"
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# If no options specified, build all
if [ "$BUILD_V8" = false ] && [ "$BUILD_OBSCURA" = false ] && [ "$BUILD_LIGHTPANDA" = false ] && [ "$BUILD_ALL" = false ]; then
    BUILD_ALL=true
fi

# Ensure Android NDK is available
ensure_ndk

# Create work directory
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Build V8 (required by both projects)
if [ "$BUILD_V8" = true ] || [ "$BUILD_ALL" = true ]; then
    log "Building V8 for Android aarch64..."
    chmod +x "$SCRIPT_DIR/build-v8-android.sh"
    "$SCRIPT_DIR/build-v8-android.sh"
    log "V8 build completed!"
fi

# Build Obscura
if [ "$BUILD_OBSCURA" = true ] || [ "$BUILD_ALL" = true ]; then
    log "Building Obscura..."
    chmod +x "$SCRIPT_DIR/build-obscura-android.sh"
    "$SCRIPT_DIR/build-obscura-android.sh"
    log "Obscura build completed!"
fi

# Build Lightpanda
if [ "$BUILD_LIGHTPANDA" = true ] || [ "$BUILD_ALL" = true ]; then
    log "Building Lightpanda..."
    chmod +x "$SCRIPT_DIR/build-lightpanda-android.sh"
    "$SCRIPT_DIR/build-lightpanda-android.sh"
    log "Lightpanda build completed!"
fi

# List built artifacts
log "Build completed! Artifacts:"
for d in "$DIST_DIR"/*; do
  [ -d "$d" ] && echo "  $d" && file "$d"/* 2>/dev/null | head -3
done

log "Done!"