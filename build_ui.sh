#!/usr/bin/env bash
set -euo pipefail

# Cross-platform BeamNG UI Build Script (Linux/macOS)

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_UI="$ROOT_DIR/baseUI"
VUE_SRC="$ROOT_DIR/ui-vue-src"
BUILD_DIR="$ROOT_DIR/ui-build-temp"
DIST_TARGET="$ROOT_DIR/ui/ui-vue/dist"

echo ""
echo "========================================"
echo "  BeamNG UI Build Script (Unix)"
echo "========================================"
echo ""

# Check for Node.js
if ! command -v node &>/dev/null; then
    echo "Error: Node.js is not installed or not in PATH."
    exit 1
fi

# 1. Create and prepare build directory
echo "[1/4] Preparing build directory..."
mkdir -p "$BUILD_DIR"
rsync -a --delete "$BASE_UI/" "$BUILD_DIR/" --exclude node_modules

# 2. Overwrite with custom source
echo "[2/4] Merging ui-vue-src into build directory..."
rsync -a "$VUE_SRC/" "$BUILD_DIR/src/"

# 3. Build
echo "[3/4] Building UI..."
cd "$BUILD_DIR"

# Copy existing node_modules from baseUI if they exist
if [ -d "$BASE_UI/node_modules" ] && [ ! -d "$BUILD_DIR/node_modules" ]; then
    echo "  Copying existing node_modules from baseUI..."
    cp -a "$BASE_UI/node_modules" "$BUILD_DIR/node_modules"
fi

# Check if npm install is needed
if [ ! -d "node_modules" ]; then
    echo "  node_modules not found, running npm install..."
    npm install
else
    echo "  node_modules already present, skipping npm install..."
fi

echo "  Running npm run build..."
npm run build

# 4. Copy to final location
echo "[4/4] Copying build results to $DIST_TARGET..."
mkdir -p "$DIST_TARGET"
rm -rf "$DIST_TARGET"/*
cp -a "$BUILD_DIR/dist/"* "$DIST_TARGET/"

echo ""
echo "========================================"
echo "  Build Successful!"
echo "========================================"
echo ""
