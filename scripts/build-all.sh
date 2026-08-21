#!/bin/bash
set -euo pipefail

# Main build script for Obscura and Lightpanda on Android/Termux aarch64
# Reference: https://github.com/Haris131/opencode-termux

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/android-build}"
ANDROID_API="${ANDROID_API:-24}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-/opt/android-ndk}"
ZIG_VERSION="${ZIG_VERSION:-0.15.2}"
V8_VERSION="${V8_VERSION:-12.0.267}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[BUILD]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

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
            echo "Environment variables:"
            echo "  WORK_DIR       Working directory (default: /tmp/android-build)"
            echo "  ANDROID_API    Android API level (default: 24)"
            echo "  ANDROID_NDK_HOME  Android NDK path (default: /opt/android-ndk)"
            echo "  ZIG_VERSION    Zig version (default: 0.15.2)"
            echo "  V8_VERSION     V8 version (default: 12.0.267)"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# If no options specified, build all
if [ "$BUILD_V8" = false ] && [ "$BUILD_OBSCURA" = false ] && [ "$BUILD_LIGHTPANDA" = false ] && [ "$BUILD_ALL" = false ]; then
    BUILD_ALL=true
fi

# Check if Android NDK is installed
if [ ! -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64" ]; then
    error "Android NDK not found at $ANDROID_NDK_HOME. Please install it first."
fi

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
find "$WORK_DIR" -name "*.tar.gz" -o -name "*.tar.xz" | while read -r file; do
    info "  $file ($(du -h "$file" | cut -f1))"
done

log "Done!"