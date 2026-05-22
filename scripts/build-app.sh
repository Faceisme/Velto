#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
APP_DIR="$ROOT_DIR/build/VibeGestures.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_HOME="$ROOT_DIR/.build/home"

cd "$ROOT_DIR"
install -d "$BUILD_HOME" "$ROOT_DIR/.build/clang-module-cache" "$ROOT_DIR/.build/swiftpm-cache"

export HOME="$BUILD_HOME"
export XDG_CACHE_HOME="$ROOT_DIR/.build/swiftpm-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"

swift build -c "$CONFIGURATION" --arch arm64 --scratch-path "$ROOT_DIR/.build" --product VibeGestures
BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --scratch-path "$ROOT_DIR/.build" --show-bin-path)"

install -d "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/VibeGestures" "$MACOS_DIR/VibeGestures"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if [ -f "$ROOT_DIR/Resources/VibeGestures.icns" ]; then
    cp "$ROOT_DIR/Resources/VibeGestures.icns" "$RESOURCES_DIR/VibeGestures.icns"
fi
chmod +x "$MACOS_DIR/VibeGestures"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign "$CODE_SIGN_IDENTITY" "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
