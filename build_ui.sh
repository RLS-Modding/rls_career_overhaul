#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status
set -o pipefail  # Pipeline fails if any command fails

# Set paths relative to the script location
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_UI="$ROOT_DIR/baseUI"
VUE_SRC="$ROOT_DIR/ui-vue-src"
BUILD_DIR="$ROOT_DIR/ui-build-temp"
DIST_TARGET="$ROOT_DIR/ui/ui-vue/dist"

echo ""
echo "========================================"
echo "  BeamNG UI Build Script (Linux)"
echo "========================================"
echo ""

# Check for Node.js
if ! command -v node &> /dev/null; then
    echo "Error: Node.js is not installed or not in PATH."
    exit 1
fi

# Check for npm
if ! command -v npm &> /dev/null; then
    echo "Error: npm is not installed or not in PATH."
    exit 1
fi

# 1. Create and prepare build directory
echo "[1/4] Preparing build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Copy baseUI to temp build directory
cp -r "$BASE_UI"/* "$BUILD_DIR/"

# 2. Overwrite with custom source
echo "[2/4] Merging ui-vue-src into build directory..."
cp -r "$VUE_SRC"/* "$BUILD_DIR/src/"

# 3. Build
echo "[3/4] Building UI..."
cd "$BUILD_DIR" || exit 1

# Symlink existing node_modules from baseUI to speed up if they exist
if [ -d "$BASE_UI/node_modules" ] && [ ! -d "node_modules" ]; then
    echo "  Linking existing node_modules from baseUI..."
    if ! ln -s "$BASE_UI/node_modules" node_modules 2>/dev/null; then
        echo "  Symlink failed, falling back to copy..."
        cp -r "$BASE_UI/node_modules" .
    fi
fi

# Check if npm install is needed
if [ ! -d "node_modules" ]; then
    echo "  node_modules not found, running npm install..."
    if ! npm install; then
        echo "Error: npm install failed."
        exit 1
    fi
else
    echo "  node_modules already present, skipping npm install..."
fi

echo "  Running npm run build..."
if ! npm run build; then
    echo "Error: npm build failed."
    exit 1
fi

cd "$ROOT_DIR" || exit 1

# 4. Copy to final location
echo "[4/4] Copying build results to $DIST_TARGET..."
mkdir -p "$DIST_TARGET"
# Clean target first to avoid stale files
rm -rf "${DIST_TARGET:?}"/*
cp -r "$BUILD_DIR/dist"/* "$DIST_TARGET/"

echo ""
echo "========================================"
echo "  Build Successful!"
echo "========================================"
echo ""

# Cleanup temporary build directory (set KEEP_UI_BUILD_TEMP=1 to preserve)
if [ "${KEEP_UI_BUILD_TEMP:-0}" != "1" ]; then
    rm -rf "${BUILD_DIR:?}"
fi
