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

# 构建缓存(.build:scratch / clang+swiftpm module cache / 隔离 HOME / codesign.err)
# 全部放到 Dropbox 外面。否则 Dropbox 会同步这些在构建过程中频繁增删的临时缓存,
# 把每个中途版本都留在云端 —— CompilationCache.noindex 单独就能在云端堆到 13G
# (本地却只有几十 KB)。改到 ~/dev 后,Dropbox 里彻底不再生成 .build。
BUILD_ROOT="${BUILD_ROOT:-$HOME/dev/build/Velto}"

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
BUILD_HOME="$BUILD_ROOT/home"
APP_ENTITLEMENTS="$ROOT_DIR/Resources/Velto.entitlements"
FINDER_EXT_ENTITLEMENTS="$ROOT_DIR/Resources/BetterFinderExtension/BetterFinderExtension.entitlements"
FINDER_EXT_BUNDLE_ID="com.face.myapp.betterfinder.FinderExtension"
# 版本号计数文件:存"年.月.当月第几次"。刻意不放 .build/ —— 冷打包会删 .build,
# 放那里计数会丢;放 scripts/ 下并 gitignore,既不进版本库也能跨冷打包存活。
VERSION_STATE_FILE="$ROOT_DIR/scripts/.build-version"

# 简单的命令行参数支持 —— 现在只有 --run
DO_RUN=0
for arg in "$@"; do
    case "$arg" in
        --run) DO_RUN=1 ;;
        *) echo "未知参数: $arg"; exit 1 ;;
    esac
done

cd "$ROOT_DIR"

# ============ Dropbox 忽略护栏 ============
# 本脚本的缓存已全部重定向到 $BUILD_ROOT(Dropbox 外),正常不会在仓库里生成 .build。
# 但裸 `swift build`(不带 --scratch-path)默认仍写仓库根的 .build,而仓库在 Dropbox 里,
# Dropbox 会把这个频繁增删的缓存的每个中间版本都留在云端(本地几百 MB → 云端十几 GB)。
# .gitignore 拦不住 Dropbox。这里:
#   - 预建 .build / build 并打 `com.dropbox.ignored` 标记(标记是 inode 级,删了重建会丢,
#     所以每次打包都重新打,堵住裸 swift build 重建 .build 的窗口);
#   - 配合仓库根的 .dropboxignore(基于模式,更持久)。
for _ignore_dir in .build build; do
    mkdir -p "$ROOT_DIR/$_ignore_dir"
    xattr -w com.dropbox.ignored 1 "$ROOT_DIR/$_ignore_dir" 2>/dev/null || true
done

install -d "$BUILD_HOME" "$BUILD_ROOT/clang-module-cache" "$BUILD_ROOT/swiftpm-cache"

# 下面会把 HOME 改到 .build/home 做缓存隔离,但 codesign 要从这里取登录钥匙串
# 里的签名证书 —— HOME 一改,钥匙串搜索列表就没有 login.keychain,
# codesign 找不到 "Apple Development:" 证书会静默退回 ad-hoc 签名,
# 导致指定要求(designated requirement)变成裸 cdhash,TCC 授权每次重编都失效。
# 所以先存下真实 HOME,签名时单独用它。
REAL_HOME="$HOME"

export HOME="$BUILD_HOME"
export XDG_CACHE_HOME="$BUILD_ROOT/swiftpm-cache"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-module-cache"

# 用固定证书签名:必须用真实 HOME 才能访问登录钥匙串里的私钥。
# 签完顺手校验签名身份不是 ad-hoc,签错了立刻报错中止,绝不带病部署。
sign_with_cert() {
    local target="$1" entitlements="$2"
    # Dropbox 的 file provider 会在清掉扩展属性后的瞬间重新挂上(com.apple.FinderInfo /
    # com.dropbox.attrs),与 codesign 形成竞态。因此贴身在每次签名前清一次,并对
    # "resource fork ... not allowed" 这类 detritus 错误重试几次,关掉竞态窗口。
    local attempt
    for attempt in 1 2 3 4 5; do
        xattr -cr "$target" 2>/dev/null || true
        if HOME="$REAL_HOME" codesign --force --sign "$CODE_SIGN_IDENTITY" \
            --entitlements "$entitlements" "$target" 2>"$BUILD_ROOT/codesign.err"; then
            break
        fi
        if [ "$attempt" -lt 5 ] && grep -qiE "resource fork|detritus|not allowed" "$BUILD_ROOT/codesign.err"; then
            sleep 0.3
            continue
        fi
        cat "$BUILD_ROOT/codesign.err" >&2
        exit 1
    done
    if codesign -dv --verbose=2 "$target" 2>&1 | grep -q "Signature=adhoc"; then
        echo "错误:$target 签名退回了 ad-hoc(证书 '$CODE_SIGN_IDENTITY' 不可用)。" >&2
        echo "      检查 \`security find-identity -v -p codesigning\` 是否能看到该证书。" >&2
        exit 1
    fi
}

# ============ 0. 工具链护栏 ============
# macOS 26+ SDK 把 SwiftUI 的 @State/@Binding 变成宏(SwiftUIMacros 插件)。裸 Command Line
# Tools 不带这个插件,会在第一个 @State 上直接编译失败、根本走不到业务代码。这里确保生效的
# 工具链是一个完整 Xcode;若不是,就自动探测 /Applications 下的 Xcode(-beta) 临时顶上,
# 都没有再给出明确指引后中止 —— 免得又对着 "SwiftUIMacros not found" 的报错排查半天。
ensure_full_xcode_toolchain() {
    local plugin_rel="Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
    if [ -f "$(xcode-select -p 2>/dev/null)/$plugin_rel" ]; then
        return 0
    fi
    local candidate
    for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -f "$candidate/Contents/Developer/$plugin_rel" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            echo "提示:当前 xcode-select 工具链缺少 SwiftUIMacros 插件,已临时改用 $candidate 编译(仅本次)。" >&2
            echo "      永久修复:sudo xcode-select -s \"$candidate/Contents/Developer\"" >&2
            return 0
        fi
    done
    echo "错误:找不到完整的 Xcode 工具链。裸 Command Line Tools 缺少 SwiftUIMacros 宏插件,无法编译 SwiftUI 的 @State。" >&2
    echo "      请安装 Xcode 后执行:sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
}
ensure_full_xcode_toolchain

# ============ 1. 编译 ============
swift build -c "$CONFIGURATION" --arch arm64 --scratch-path "$BUILD_ROOT" --product Velto
swift build -c "$CONFIGURATION" --arch arm64 --scratch-path "$BUILD_ROOT" --product BetterFinderExtension
BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --scratch-path "$BUILD_ROOT" --show-bin-path)"

# ============ 1.5 计算版本号(年.月.当月第几次打包)============
# CFBundleShortVersionString = 年.月.第几次。同一自然月内每打包一次第三段 +1,跨月归 1。
# 放在编译之后:编译失败会被上面的 set -e 拦下,不会白白消耗一个版本号。
YEAR="$(date +%Y)"
MONTH="$(( 10#$(date +%m) ))"   # 10# 强制十进制,免得 08/09 被当八进制
CUR_YM="$YEAR.$MONTH"
PREV_VERSION=""
[ -f "$VERSION_STATE_FILE" ] && PREV_VERSION="$(cat "$VERSION_STATE_FILE")"
PREV_YM="${PREV_VERSION%.*}"     # 年.月
PREV_N="${PREV_VERSION##*.}"     # 第几次
case "$PREV_N" in
    ''|*[!0-9]*) BUILD_SEQ=1 ;;                                   # 空/损坏 → 从 1 起
    *) if [ "$PREV_YM" = "$CUR_YM" ]; then BUILD_SEQ="$(( PREV_N + 1 ))"; else BUILD_SEQ=1; fi ;;
esac
APP_VERSION="$CUR_YM.$BUILD_SEQ"
echo "$APP_VERSION" > "$VERSION_STATE_FILE"
echo "版本号: $APP_VERSION"

# ============ 2. 组装 .app bundle ============
rm -rf "$APP_DIR"
install -d "$MACOS_DIR" "$RESOURCES_DIR" "$FINDER_EXT_MACOS_DIR" "$FINDER_EXT_RESOURCES_DIR"
cp "$BIN_DIR/Velto" "$MACOS_DIR/Velto"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
# 只把版本号盖进 bundle 内的副本,源 Resources/Info.plist 保持不变 —— 否则每次打包都把
# 它改脏,污染 git 工作区。
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$CONTENTS_DIR/Info.plist"
# Liquid Glass 图标:把 Resources/Velto.icon(Icon Composer 文档)用 actool 编成
# Assets.car(+ 兜底 Velto.icns)放进 bundle 的 Resources。Info.plist 里 CFBundleIconName=Velto
# 让系统在 macOS 26 上据此渲染自适应玻璃图标;旧的静态 Velto.icns 已被这一步取代。
if [ -d "$ROOT_DIR/Resources/Velto.icon" ]; then
    # actool 怪癖:不给 --output-partial-info-plist 就空跑不产出。这个 plist 用完即删,不进
    # bundle;放 RESOURCES_DIR(编译输出目录,确定可写)。错误信息走 stdout,失败时打印再中止。
    if ! xcrun actool "$ROOT_DIR/Resources/Velto.icon" \
        --compile "$RESOURCES_DIR" \
        --app-icon "Velto" \
        --output-partial-info-plist "$RESOURCES_DIR/.icon-partial.plist" \
        --platform macosx \
        --minimum-deployment-target 26.0 \
        --errors --warnings >"$BUILD_ROOT/actool.log" 2>&1; then
        echo "错误:actool 编译 Velto.icon 失败:" >&2
        cat "$BUILD_ROOT/actool.log" >&2
        exit 1
    fi
    rm -f "$RESOURCES_DIR/.icon-partial.plist"
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
    sign_with_cert "$FINDER_EXT_DIR" "$FINDER_EXT_ENTITLEMENTS"
    sign_with_cert "$APP_DIR" "$APP_ENTITLEMENTS"
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
    sign_with_cert "$INSTALLED_FINDER_EXT" "$FINDER_EXT_ENTITLEMENTS"
    sign_with_cert "$INSTALLED_APP" "$APP_ENTITLEMENTS"
fi

if [ "${SKIP_FINDER_EXTENSION_REGISTER:-0}" != "1" ] && command -v pluginkit >/dev/null 2>&1; then
    pluginkit -a "$INSTALLED_FINDER_EXT" >/dev/null 2>&1 || true
    pluginkit -e use -i "$FINDER_EXT_BUNDLE_ID" >/dev/null 2>&1 || true
    echo "已注册并启用 Finder 扩展: $FINDER_EXT_BUNDLE_ID"
fi

echo "$INSTALLED_APP  (also at $APP_DIR)  [v$APP_VERSION]"

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
