# Velto

Velto 是一个面向 Apple Silicon Mac 的桌面操作增强工具。它把鼠标手势、鼠标滚轮手感、窗口管理、触控板标题栏手势、窗口切换、输入法自动切换和 Finder 增强集中到一个常驻菜单栏 App 里，目标是减少高频操作里的重复按键、窗口切换和路径处理成本。

当前项目使用 Swift Package Manager 构建，最低支持 macOS 26。App 默认以辅助应用运行，不显示 Dock 图标，通过菜单栏图标进入设置和重启监听。增强 Finder 功能由主 App 加 Finder Sync 扩展共同提供。

## 当前功能

设置窗口目前包含八个模块：

- 鼠标手势：按住右键画手势，匹配后向目标窗口发送快捷键。
- 鼠标控制：平滑滚动、滚动方向处理、滚动功能键、鼠标按钮绑定和按应用覆盖。
- 窗口管理：按住修饰键移动/缩放窗口，快捷键最大化窗口，滚轮缩放内容。
- 触控板手势：光标停在窗口标题栏附近时，用双指滑动最大化、最小化或关闭窗口。
- 窗口切换：替代 `⌘+Tab` 的窗口级切换器，支持缩略图、筛选、排序和多屏显示。
- 输入法切换：按当前 App、浏览器网站或浏览器地址栏自动切换输入法。
- 增强Finder：在 Finder 工具栏、右键菜单和全局快捷键里打开终端、编辑器或拷贝路径。
- 通用设置：开机启动、菜单栏图标、手势识别参数、配置导入导出和日志入口。

## 鼠标手势

鼠标手势是 Velto 最基础的能力。Event Tap 常驻监听右键事件，普通右键单击会透传给系统菜单，右键拖动画出轨迹后才进入手势识别。

支持能力：

- 右键拖动绘制手势，匹配成功后发送对应快捷键。
- 支持新建、删除、重命名手势。
- 每个手势可以录入多个轨迹样本，提高容错。
- 保存前会检测形状过于相近的手势，避免互相冲突。
- 支持给手势绑定任意快捷键。
- 支持显示或关闭手势轨迹。
- 支持手势超时丢弃。
- 支持“乱划取消手势”，手势中途来回乱划可直接取消。
- 支持选择动作目标：鼠标指针下方窗口，或当前活动窗口。
- 支持手势调试日志，记录轨迹和匹配诊断。

默认手势：

| 手势 | 默认快捷键 | 用途 |
| --- | --- | --- |
| 向左 | `⌘[` | 后退 |
| 向右 | `⌘]` | 前进 |
| 向上 | `⌘T` | 新建标签页 |
| 向下 | `⌘W` | 关闭标签页 |

## 鼠标控制

鼠标控制模块主要处理物理鼠标滚轮和鼠标按钮，不接管触控板本身的系统手势。

滚动能力：

- 全局启用/停用鼠标控制。
- 平滑滚动总开关。
- 垂直轴和水平轴可分别启用平滑。
- 全局反向滚动。
- 垂直轴和水平轴可分别反向。
- 可调最短步长、速度增益、尾迹长度。
- 模拟触控板模式：给合成滚动补充连续滚动标记，让部分 App 更像接收到触控板连续滚动。

滚动功能键：

- 加速滚动：默认 `⌥`，按住时提高滚动速度。
- 方向转换：默认 `⇧`，按住时把垂直滚动转成水平滚动。
- 禁用平滑：默认 `⌘`，按住时临时透传普通滚轮事件。

按钮绑定：

- 可以录制键盘或鼠标触发键。
- 可以绑定系统动作：调度中心、应用窗口、显示桌面、截图。
- 可以绑定快捷键。
- 可以打开 App。
- 可以打开文件。
- 可以运行脚本。

按应用配置：

- 可以为指定 App 添加覆盖规则。
- 每个 App 可选择是否继承全局滚动设置。
- 每个 App 可选择是否继承全局滚动功能键。
- 每个 App 可选择是否继承全局按钮绑定。

特殊处理：

- iPhone 镜像场景下对滚轮方向做了单独处理，避免和 iOS 自带惯性滚动互相打架。
- 鼠标控制调试日志默认关闭，只在排查滚动手感时打开。

## 窗口管理

窗口管理模块只控制窗口移动、窗口缩放、滚轮缩放和窗口快捷键。关闭模块总开关后，这些能力全部停用，但不影响鼠标手势、鼠标控制和窗口切换。

支持能力：

- 移动窗口：按住指定修饰键并移动鼠标，拖动光标下窗口。
- 缩放窗口：按住指定修饰键并移动鼠标，按光标所在边角缩放窗口。
- 滚轮缩放修饰键：按住指定修饰键并滚动滚轮，对网页、图片等内容执行缩放。
- 最大化快捷键：按下指定快捷键，最大化光标下窗口。

这些功能都依赖辅助功能权限和全局事件监听。

## 触控板手势

触控板手势模块用于标题栏附近的窗口控制，不接管普通页面滚动。它默认关闭，需要用户主动启用。

触发条件：

- 光标需要位于窗口顶部标题栏附近。
- 使用双指滑动。
- 非标题栏区域的滚动会照常交给系统和目标 App。

当前动作：

| 手势 | 动作 |
| --- | --- |
| 双指上滑 | 最大化窗口 |
| 双指下滑 | 最小化窗口 |
| 双指左滑 | 关闭窗口 |

调试能力：

- 可在触控板手势页打开调试日志。
- 日志写入 `~/Library/Logs/Velto/trackpad-gesture-debug.log`。
- 日志会记录命中区、位移方向和最终动作判定，便于调整触发范围。

## 窗口切换

窗口切换器是 Velto 对 `⌘+Tab` 的增强。它不是只按 App 切换，而是可以按窗口切换，并可显示实时缩略图。

核心能力：

- 默认触发键为 `⌘+Tab`。
- 可以改成其它包含真实修饰键的快捷键。
- 按住触发键不放时循环选择，松开后切换。
- 关闭窗口切换器后，`⌘+Tab` 会还给 macOS 原生切换器。
- 支持缩略图、仅图标、仅标题三种外观。
- 支持按窗口或按应用分组。
- 支持按最近聚焦、最近创建、字母顺序、桌面分组排序。
- 支持按应用范围、桌面范围、屏幕范围过滤。
- 支持分别控制最小化窗口、隐藏窗口、全屏窗口、无窗口 App 的显示策略。
- 支持选择切换器显示在鼠标所在屏幕、活跃屏幕或主屏幕。
- 使用 ScreenCaptureKit 抓取窗口缩略图。
- 对微信、Dropbox、1Password 等容易留下空壳窗口的应用做了过滤和调试支持。

注意：

- 窗口切换器使用 SkyLight 私有框架和 AX 信息枚举窗口。
- 没有屏幕录制权限时，切换器仍可工作，但无法显示实时窗口缩略图。

## 输入法切换

输入法切换是当前新加入的核心模块。它根据当前前台 App、浏览器当前网站、浏览器地址栏焦点自动选择输入法。

总开关默认关闭。因为自动切输入法属于比较强的系统行为，需要用户主动开启。

### 通用规则

通用页支持：

- 启用输入法切换。
- 设置全局默认输入法：无规则命中时切到它。
- 设置“切回 App / 网站时”的策略：
  - 使用默认输入法。
  - 恢复上次使用的输入法。
- 设置浏览器地址栏默认输入法：地址栏聚焦时强制切到指定输入法，常用于切英文。
- 开启输入法调试日志。
- 打开日志文件夹。

决策优先级：

1. 浏览器地址栏默认输入法。
2. 如果选择“恢复上次使用的输入法”，优先使用当前上下文的会话缓存。
3. 浏览器 URL 规则。
4. App 规则。
5. 全局默认输入法。
6. 都没有命中时保持当前输入法。

“恢复上次使用的输入法”只保存在当前运行会话里，不写入持久配置。用户在某个 App 或网站里手动切换输入法后，Velto 会记住这次选择；如果用户切回默认输入法，对应缓存会被清除。

### 应用规则

应用规则按 `bundleIdentifier` 匹配 App。

支持能力：

- 从本机 `.app` 选择应用。
- 自动显示应用图标、应用名和 bundle id。
- 每条规则可单独启用或停用。
- 每条规则可选择目标输入法。
- 支持删除规则。

### 浏览器规则

浏览器规则需要先在“启用的浏览器”里打开对应浏览器，然后 Velto 才会读取当前 Tab 的 URL。

当前支持的浏览器：

- Safari、Safari Technology Preview。
- Google Chrome、Chromium、Arc、Dia。
- Microsoft Edge、Brave、Brave Beta、Brave Nightly。
- Vivaldi、Opera、Thorium。
- Firefox、Firefox Developer Edition、Firefox Nightly、Zen。

URL 规则支持三种匹配方式：

- 域名后缀：例如 `github.com` 可以匹配 `github.com` 和 `docs.github.com`。
- 精确域名：只匹配完整 host。
- URL 正则：按完整 URL 做正则匹配。

浏览器上下文读取方式：

- 通过 AX 树读取当前网页 `AXURL`。
- 通过焦点元素判断地址栏是否聚焦。
- 浏览器前台且启用检测时，会使用 AX 事件加 0.8 秒兜底轮询更新上下文。
- 如果取不到 URL，会退化为普通 App 处理，不强行切换。

### CJKV 故障排除

部分中日韩越输入法会出现“菜单栏图标已经变了，但实际输入仍是英文”的半切换问题。Velto 提供 CJKV 修复开关。

修复方式：

- 模拟“选择上一个输入法”快捷键：默认推荐，不主动抢焦点。
- 临时输入窗口：短暂创建透明输入窗口，让系统确认输入法状态，但可能短暂激活 Velto。

如果选择“模拟上一个输入法”方式，需要系统里启用“选择上一个输入法”快捷键。缺失时设置页会提示并提供打开键盘设置的按钮。

## 增强Finder

增强Finder 用来把 Finder 里的当前位置或选中项目快速交给终端、编辑器或剪贴板。它由主 App、`betterfinder` 核心包和 Finder Sync 扩展组成。

集成能力：

- 启用或停用增强Finder。
- 注册并启用 Finder Sync 扩展。
- 打开系统扩展设置。
- 重启 Finder，让新扩展立即生效。

Finder 菜单：

- Finder 工具栏菜单默认包含：
  - 默认终端。
  - 默认编辑器。
  - 拷贝路径。
- Finder 右键菜单可使用默认菜单或自定义菜单。
- 可隐藏 Finder 右键菜单项。
- 菜单图标支持三种样式：无、简单、原始。
- “原始”图标会使用应用真实图标，内部已做图标缓存，降低工具栏弹框延迟。
- 拷贝路径支持路径转义，便于直接粘贴到 Shell。

默认应用：

- 默认终端用于 Finder 工具栏第一项和“打开默认终端”快捷键。
- 默认编辑器用于 Finder 工具栏第二项和“打开默认编辑器”快捷键。
- 支持自动识别已安装的终端和编辑器。
- 支持从 Finder 选择自定义 `.app`。
- 支持手动输入应用名称，名称会传给系统 `open -a`。

当前内置支持的应用包括 Terminal、iTerm、Alacritty、kitty、WezTerm、Tabby、Warp、Ghostty、GitHub Desktop、Fork、TextEdit、Xcode、Visual Studio Code、VSCodium、VS Code Insiders、Cursor、Sublime Text、BBEdit、CotEditor、MacVim、Typora、Nova、JetBrains 系列和 Android Studio。

全局快捷键：

| 动作 | 默认快捷键 |
| --- | --- |
| 打开默认终端 | 未设置 |
| 打开默认编辑器 | `⇧⌘S` |
| 拷贝路径到剪贴板 | `⇧⌘C` |

执行目标：

- 如果 Finder 有选中项目，使用选中项目。
- 如果没有选中项目，使用当前 Finder 目标目录。
- 如果 Finder 目标目录也取不到，会回退到桌面目录。

调试能力：

- 可在增强Finder页打开调试日志。
- 日志写入 Finder 扩展容器下的 `betterfinder-debug.log`。
- 日志会记录菜单构建、菜单点击、URL 回调、执行动作和菜单构建耗时。

## 通用设置

通用页包含：

- 启用手势监听。
- 开机自动启动。
- 显示菜单栏图标。
- 绘制时显示轨迹。
- 乱划取消手势。
- 手势超时时长。
- 手势作用目标。
- 导入配置。
- 导出配置。
- 打开权限设置。
- 打开日志文件夹。

配置导入导出使用 JSON 文件。导出内容包含手势、通用偏好、鼠标控制、窗口管理、窗口切换和输入法切换配置。
当前备份格式也包含触控板手势开关、触控板调试开关和增强Finder设置。旧版备份没有增强Finder字段时，导入不会覆盖当前增强Finder设置。

不包含：

- macOS 辅助功能、输入监控、屏幕录制授权。
- Finder Sync 扩展的系统启用状态。
- 系统登录项里的开机启动状态。
- 输入法切换的会话缓存。

## 权限

首次运行需要在系统设置里授权：

```text
系统设置 -> 隐私与安全性 -> 辅助功能
系统设置 -> 隐私与安全性 -> 输入监控
系统设置 -> 隐私与安全性 -> 屏幕录制
系统设置 -> 隐私与安全性 -> 自动化
系统设置 -> 通用 -> 登录项与扩展 -> 扩展 -> Finder
```

权限影响：

- 辅助功能：鼠标手势、快捷键发送、窗口移动/缩放、窗口枚举、输入法浏览器上下文读取都依赖它。
- 输入监控：全局按键、鼠标事件、切换器触发键需要它。
- 屏幕录制：窗口切换器实时缩略图需要它。
- 自动化：增强Finder在需要读取 Finder 当前目标时可能触发 Finder 自动化授权。
- Finder 扩展：增强Finder的工具栏菜单和右键菜单依赖 Finder Sync 扩展启用。

如果重新构建、移动 App 路径、改 bundle id 或重签名，macOS 可能会把它当成新 App，需要重新授权。

## 构建和安装

项目使用 Swift Package Manager，目标平台为 macOS 26：

```bash
swift build -c release --arch arm64 --scratch-path .build --product Velto
```

更常用的是项目脚本：

```bash
scripts/build-app.sh
```

脚本会：

- 构建 `Velto` 主程序和 `BetterFinderExtension` Finder Sync 扩展。
- 生成 `build/Velto.app`。
- 把 `BetterFinderExtension.appex` 放入 `Velto.app/Contents/PlugIns/`。
- 清理 Dropbox / CloudStorage 路径可能带来的扩展属性。
- ad-hoc 签名主 App 和扩展。
- kill 旧 Velto 进程。
- 覆盖安装到 `/Applications/Velto.app`。
- 注册并启用增强Finder的 Finder Sync 扩展。
- 默认重置辅助功能和屏幕录制授权记录。

只构建不安装：

```bash
SKIP_INSTALL=1 scripts/build-app.sh
```

构建并启动：

```bash
scripts/build-app.sh --run
```

构建并启动但不重置 TCC 授权：

```bash
SKIP_TCC_RESET=1 scripts/build-app.sh --run
```

为什么默认安装到 `/Applications/`：macOS 26 对 Dropbox / CloudStorage 路径下的 ad-hoc 签名 App 授权不稳定，ScreenCaptureKit 可能会报 `-3801`。放在 `/Applications/` 后路径稳定，TCC 表现更可靠。

## 日志

主 App 日志目录：

```text
~/Library/Logs/Velto/
```

增强Finder的 Finder 扩展日志在扩展容器内，设置页会显示完整路径并提供“打开文件夹”按钮。

当前日志文件：

| 文件 | 来源 | 开启方式 |
| --- | --- | --- |
| `velto-debug.jsonl` | 鼠标手势和通用调试事件 | 通用/手势页调试开关 |
| `mouse-scroll-debug.log` | 鼠标滚轮、平滑队列、合成滚动 | 鼠标控制页调试日志 |
| `trackpad-gesture-debug.log` | 触控板标题栏手势命中区、方向和动作判定 | 触控板手势页调试日志 |
| `switcher-debug.log` | 窗口切换器过滤和异常窗口诊断 | 窗口切换页调试日志或 `VELTO_SWITCHER_DEBUG=1` |
| `input-source-switch.log` | 输入法上下文、规则命中、CJKV 修复 | 输入法切换页调试日志或 `VELTO_INPUT_SOURCE_DEBUG=1` |
| `betterfinder-debug.log` | Finder 扩展菜单构建、菜单点击、URL 回调和动作执行 | 增强Finder页调试日志 |

开发期可以直接从命令行打开调试：

```bash
pkill -x Velto
VELTO_SWITCHER_DEBUG=1 /Applications/Velto.app/Contents/MacOS/Velto
```

```bash
pkill -x Velto
VELTO_INPUT_SOURCE_DEBUG=1 /Applications/Velto.app/Contents/MacOS/Velto
```

## 项目结构

```text
Package.swift
Resources/
  Info.plist
  Velto.icns
  Velto.entitlements
  BetterFinderExtension/
Sources/
  Velto/
    main.swift
    AppDelegate.swift
    EventTapManager.swift
    Models.swift
    PermissionManager.swift
    LoginItemManager.swift
    ShortcutSynthesizer.swift
    ModifierFormatter.swift
    DisplayCoordinateConverter.swift
    GestureTargetController.swift
    AppQuirks.swift
    DebugLog.swift
    SettingsRootView.swift
    SidebarView.swift
    GeneralSettingsPage.swift
    DesignSystem.swift
    Components.swift
    RecorderViews.swift
    Gestures/
    MouseControl/
    WindowManagement/
    TrackpadGesture/
    Switcher/
    InputSourceSwitch/
    betterfinder/
  betterfinder/
  BetterFinderExtension/
scripts/
  build-app.sh
docs/
  superpowers/
```

核心职责：

- `AppDelegate`：启动主菜单、菜单栏、Event Tap、窗口切换器和输入法切换控制器。
- `EventTapManager`：全局鼠标/键盘事件入口，分发到手势、鼠标控制、窗口管理和滚轮缩放。
- `Gestures/`：手势录制、识别、冲突检测、轨迹显示和快捷键触发。
- `MouseControl/`：平滑滚动、滚动功能键、按钮绑定、按应用覆盖和滚轮日志。
- `WindowManagement/`：窗口拖动、窗口缩放、窗口最大化、内容缩放。
- `TrackpadGesture/`：标题栏附近双指滑动控制窗口，以及触控板手势诊断日志。
- `Switcher/`：窗口枚举、缩略图、Key Tap、切换面板、筛选排序和调试日志。
- `InputSourceSwitch/`：前台上下文监听、浏览器 URL 读取、规则决策、TIS 输入法切换和 CJKV 修复。
- `Sources/betterfinder/`：增强Finder核心模型、菜单构建、应用目录、路径转义、URL 回调和动作执行。
- `Sources/BetterFinderExtension/`：Finder Sync 扩展，负责 Finder 工具栏菜单和右键菜单。
- `Sources/Velto/betterfinder/`：增强Finder设置页和全局快捷键控制器。
- `DesignSystem.swift` / `Components.swift`：设置窗口共享 UI 组件和视觉 token。

## 注意事项

- 当前仅面向 Apple Silicon 和 macOS 26。
- 当前只支持右键触发鼠标手势。
- 鼠标控制主要面向物理鼠标滚轮；触控板窗口手势由独立的“触控板手势”模块处理。
- 触控板手势只在窗口标题栏附近生效，避免干扰普通内容滚动。
- 输入法自动切换默认关闭，需要用户主动开启。
- 窗口切换器使用 SkyLight 私有框架，不适合直接上架 Mac App Store。
- 增强Finder依赖 Finder Sync 扩展，需要在系统扩展设置里启用。
- 默认 Bundle Identifier 是 `com.face.myapp`，公开分发前建议改成自己的反向域名。
- 当前仓库没有声明开源许可证，正式公开前需要添加 `LICENSE`。

新增鼠标控制模块参考了 [Caldis/Mos](https://github.com/Caldis/Mos) 的功能形态和滚动处理思路。Mos 使用 CC BY-NC 4.0 授权；如果后续公开或商业分发 Velto，需要重新确认授权兼容性。

## 紧急停止

如果测试中需要立刻退出，或旧进程还在运行：

```bash
pkill -x Velto
```
