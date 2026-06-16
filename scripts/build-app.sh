#!/usr/bin/env bash
set -euo pipefail

# 构建 Velto.app 并部署到 /Applications/。
#
# 为什么默认会同步到 /Applications/:
#   macOS Tahoe (26) 的 TCC 对位于 Dropbox / CloudStorage 路径下的 ad-hoc 签名
#   app 表现不可靠 —— 哪怕在系统设置里勾上权限,SCK 仍然报 -3801 "用户拒绝
#   TCC"。把 app 放到稳定路径(/Applications/)就一切正常。
#
# 同时这个脚本还顺手:
#   - `xattr -cr` 清掉 Dropbox 留下的扩展属性,否则 codesign 拒签
#   - `pkill` 干掉旧实例,免得 cp 时把还在跑的 binary 替换出问题
#   - 重新签名 /Applications/ 副本(签名对内容敏感,不重签会 SIGKILL)
#
# 用法:
#   ./scripts/build-app.sh              # 构建 + 部署 + 同步 /Applications/
#   SKIP_INSTALL=1 ./scripts/build-app.sh   # 只构建,不动 /Applications/
#   ./scripts/build-app.sh --run        # 构建完直接启动

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"

# 使用固定的 Apple Development 证书,而不是 ad-hoc 签名。
# 这样 TCC 授权会绑定到开发者身份,重编后授权就不会被吊销。
# ad-hoc 签名每次都产生不同的 cdhash,导致授权失效;
# 用固定证书签名,授权绑定到证书身份,持久化。
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Apple Development: jmug.nev@gmail.com (Z3YWMJ8JR8)}"

APP_DIR="$ROOT_DIR/build/Velto.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLUGINS_DIR="$CONTENTS_DIR/PlugIns"
FINDER_EXT_DIR="$PLUGINS_DIR/BetterFinderExtension.appex"
FINDER_EXT_CONTENTS_DIR="$FINDER_EXT_DIR/Contents"
FINDER_EXT_MACOS_DIR="$FINDER_EXT_CONTENTS_DIR/MacOS"
FINDER_EXT_RESOURCES_DIR="$FINDER_EXT_CONTENTS_DIR/Resources"
INSTALLED_APP="/Applications/Velto.app"
INSTALLED_FINDER_EXT="$INSTALLED_APP/Contents/PlugIns/BetterFinderExtension.appex"
LEGACY_INSTALLED_APP="/Applications/VibeGestures.app"
BUILD_HOME="$ROOT_DIR/.build/home"
APP_ENTITLEMENTS="$ROOT_DIR/Resources/Velto.entitlements"
FINDER_EXT_ENTITLEMENTS="$ROOT_DIR/Resources/BetterFinderExtension/BetterFinderExtension.entitlements"
FINDER_EXT_BUNDLE_ID="com.face.myapp.betterfinder.FinderExtension"

# 简单的命令行参数支持 —— 现在只有 --run
DO_RUN=0
for arg in "$@"; do
    case "$arg" in
        --run) DO_RUN=1 ;;
        *) echo "未知参数: $arg"; exit 1 ;;
    esac
done

cd "$ROOT_DIR"
install -d "$BUILD_HOME" "$ROOT_DIR/.build/clang-module-cache" "$ROOT_DIR/.build/swiftpm-cache"

export HOME="$BUILD_HOME"
export XDG_CACHE_HOME="$ROOT_DIR/.build/swiftpm-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"

# ============ 1. 编译 ============
swift build -c "$CONFIGURATION" --arch arm64 --scratch-path "$ROOT_DIR/.build" --product Velto
swift build -c "$CONFIGURATION" --arch arm64 --scratch-path "$ROOT_DIR/.build" --product BetterFinderExtension
BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --scratch-path "$ROOT_DIR/.build" --show-bin-path)"

# ============ 2. 组装 .app bundle ============
rm -rf "$APP_DIR"
install -d "$MACOS_DIR" "$RESOURCES_DIR" "$FINDER_EXT_MACOS_DIR" "$FINDER_EXT_RESOURCES_DIR"
cp "$BIN_DIR/Velto" "$MACOS_DIR/Velto"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if [ -f "$ROOT_DIR/Resources/Velto.icns" ]; then
    cp "$ROOT_DIR/Resources/Velto.icns" "$RESOURCES_DIR/Velto.icns"
fi
chmod +x "$MACOS_DIR/Velto"

# Finder Sync 扩展:SwiftPM 负责编译 executable,脚本负责组装 .appex bundle。
cp "$BIN_DIR/BetterFinderExtension" "$FINDER_EXT_MACOS_DIR/BetterFinderExtension"
cp "$ROOT_DIR/Resources/BetterFinderExtension/Info.plist" "$FINDER_EXT_CONTENTS_DIR/Info.plist"
chmod +x "$FINDER_EXT_MACOS_DIR/BetterFinderExtension"

# ============ 3. 清 xattr + 签名 build/ 副本 ============
# Dropbox 同步会在文件上挂 com.dropbox.attrs 之类的扩展属性,
# codesign 看到非空 xattr 会拒签:"resource fork ... not allowed"。
# 必须在每次 codesign 之前清一次。
if command -v codesign >/dev/null 2>&1; then
    xattr -cr "$APP_DIR" 2>/dev/null || true
    codesign --force --sign "$CODE_SIGN_IDENTITY" --entitlements "$FINDER_EXT_ENTITLEMENTS" "$FINDER_EXT_DIR" >/dev/null
    codesign --force --sign "$CODE_SIGN_IDENTITY" --entitlements "$APP_ENTITLEMENTS" "$APP_DIR" >/dev/null
fi

# ============ 4. 同步到 /Applications/(除非 SKIP_INSTALL=1)============
if [ "${SKIP_INSTALL:-0}" = "1" ]; then
    echo "$APP_DIR  (SKIP_INSTALL=1, /Applications/ 未同步)"
    exit 0
fi

# 干掉旧实例,免得 cp 时撞文件锁
pkill -f "$INSTALLED_APP/Contents/MacOS/Velto" 2>/dev/null || true
pkill -f "$LEGACY_INSTALLED_APP/Contents/MacOS/VibeGestures" 2>/dev/null || true
# 等一下让 OS 收尾
sleep 0.3

# 全删重拷,免得旧文件残留(改名 / 删文件这类变化用 cp 增量更新可能漏)
rm -rf "$INSTALLED_APP" "$LEGACY_INSTALLED_APP"
cp -R "$APP_DIR" "$INSTALLED_APP"

if command -v codesign >/dev/null 2>&1; then
    xattr -cr "$INSTALLED_APP" 2>/dev/null || true
    codesign --force --sign "$CODE_SIGN_IDENTITY" --entitlements "$FINDER_EXT_ENTITLEMENTS" "$INSTALLED_FINDER_EXT" >/dev/null
    codesign --force --sign "$CODE_SIGN_IDENTITY" --entitlements "$APP_ENTITLEMENTS" "$INSTALLED_APP" >/dev/null
fi

if [ "${SKIP_FINDER_EXTENSION_REGISTER:-0}" != "1" ] && command -v pluginkit >/dev/null 2>&1; then
    pluginkit -a "$INSTALLED_FINDER_EXT" >/dev/null 2>&1 || true
    pluginkit -e use -i "$FINDER_EXT_BUNDLE_ID" >/dev/null 2>&1 || true
    echo "已注册并启用 Finder 扩展: $FINDER_EXT_BUNDLE_ID"
fi

echo "$INSTALLED_APP  (also at $APP_DIR)"

# ============ 5. TCC 授权(辅助功能 / 录屏)============
# 使用固定的 Apple Development 证书签名后,TCC 授权绑定到开发者身份而不是 cdhash,
# 重编不会吊销授权。因此授权已自动持久化,无需重置。
# 如遇到授权问题,可设置 FORCE_TCC_RESET=1 手动重置。
if [ "${FORCE_TCC_RESET:-0}" = "1" ]; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$ROOT_DIR/Resources/Info.plist" 2>/dev/null || echo com.face.myapp)"
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset AppleEvents "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "已重置 TCC 授权(Accessibility / ScreenCapture / AppleEvents): $BUNDLE_ID"
fi

# ============ 6. --run:可选地直接启动 ============
if [ "$DO_RUN" = "1" ]; then
    echo "启动中..."
    open -a "$INSTALLED_APP"
    sleep 0.5
    echo "进程已启动 (pid: $(pgrep -f "$INSTALLED_APP/Contents/MacOS/Velto" | head -1))"
fi
