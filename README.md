# Velto

Velto 是一个面向 Apple Silicon Mac 的轻量级桌面操作增强工具。最初只做鼠标手势，现在还包含窗口拖动 / 缩放 / 最大化、内容缩放，以及一个仿 Win11 风格、带实时缩略图的窗口切换器。整体目标是用最少的交互完成高频操作：按住鼠标右键画手势执行快捷键，按住修饰键拖动或缩放窗口，按 `⌘+Tab` 在面板里挑窗口。

项目最初是为了替代没有 Apple Silicon 原生版本的鼠标手势工具，后续按个人使用习惯持续扩展。界面使用 macOS 26 的原生 Liquid Glass 风格，功能模块化、可单独开关。

## 功能特性

### 通用

- Apple Silicon 原生构建，最低支持 macOS 26 (Tahoe)。
- 设置面板使用 Liquid Glass 玻璃质感，与系统 Dock / 切换器视觉一致。
- 支持开机自动启动，默认不显示 Dock 图标，菜单栏图标可隐藏。
- 支持导入、导出完整 App 配置备份（JSON）。
- 关键 Event Tap 运行在独立高优先级线程上，降低主线程繁忙带来的延迟。
- 各功能模块互相独立，可在设置里单独启用或停用。

### 鼠标手势

- 打开 App 后默认开始监听手势。
- 只使用鼠标右键作为手势触发键。
- 普通右键单击会正常弹出系统右键菜单。
- 右键拖动进入手势模式，不触发右键菜单。
- 支持自定义手势名称、轨迹样本和快捷键。
- 支持任意曲线式手势识别，同一手势可录入多个样本以提升容错。
- 支持手势超时作废，避免误画或长时间按住右键后误执行。
- 支持可选手势轨迹视觉反馈。
- 支持选择手势作用目标：
  - 鼠标指针下方的应用程序和窗口。
  - 当前活动的应用程序和窗口。

### 窗口控制

- 支持按住自定义修饰键移动光标下窗口。
- 支持按住自定义修饰键缩放光标下窗口。
- 支持快捷键最大化光标下窗口。
- 支持按住自定义修饰键并滚动鼠标滚轮，对网页、图片等内容执行平滑缩放。

### 鼠标控制

参考 Mos 的功能形态增加独立入口，当前覆盖平滑滚动、轴向独立、滚动功能键、按应用配置和基础按钮绑定。

- 支持全局启用 / 停用鼠标控制。
- 支持配置最短步长、速度增益、持续时间，以及模拟触控板模式。
- 支持垂直 / 水平滚动分别设置平滑和反向。
- 支持为滚动加速、方向转换、临时禁用平滑录制键盘或鼠标触发键。
- 支持为指定 App 覆盖滚动、滚动功能键和按钮绑定。
- 支持录制键盘或鼠标按钮，并绑定到系统动作、快捷键、打开 App、打开文件或运行脚本。

### 窗口切换器

类似 Windows 11 风格的 `⌘+Tab` 替代：按下触发键弹出居中浮动面板，实时显示每个窗口的缩略图，松开切换。

- 默认触发键 `⌘+Tab`，可改成任意快捷键。按住组合键不放循环选择，松开切换。
- 实时缩略图（macOS 26 ScreenCaptureKit），预热抓取，弹出无感延迟。
- 面板使用真正的 Liquid Glass 容器，与系统切换器同一渲染管线。
- 鼠标 hover / 点击与键盘选择共享同一选中态，可自由混用。
- 三种外观：缩略图网格 / 仅图标（macOS 原生 ⌘+Tab 风格）/ 单列标题。
- 两种分组：按窗口（每个窗口或标签一个条目）或按应用（每个应用只保留一个 MRU 代表，终端、Chrome 标签多时更清爽）。
- 多档筛选：按应用范围、桌面、屏幕，以及是否最小化 / 隐藏 / 全屏等独立控制「显示 / 显示在末尾 / 隐藏」。
- 多种排序：最近聚焦、最近创建、字母顺序、按桌面分组。
- 多屏支持：面板可固定在鼠标所在屏幕、活跃屏幕或主屏。
- 关闭切换器开关后 `⌘+Tab` 会还给 macOS 原生切换器。
- 针对微信 / Dropbox / 1Password 等会留下 AX 空壳窗口的应用做了过滤。
- 调试通道：遇到「莫名其妙的窗口」出现在列表里，可用 `VELTO_SWITCHER_DEBUG=1` 启动以收集日志（详见下方「调试」一节）。

## 默认手势

| 手势 | 默认快捷键 | 用途 |
| --- | --- | --- |
| 向左 | `⌘[` | 后退 |
| 向右 | `⌘]` | 前进 |
| 向上 | `⌘T` | 新建标签页 |
| 向下 | `⌘W` | 关闭标签页 |

默认配置只是起点。你可以在设置窗口里删除、修改或重新录制这些手势。

## 权限

首次运行需要在 macOS 系统设置里授权：

```text
系统设置 -> 隐私与安全性 -> 辅助功能       (鼠标手势、窗口控制、切换器都需要)
系统设置 -> 隐私与安全性 -> 输入监控       (Event Tap 截键所必需)
系统设置 -> 隐私与安全性 -> 屏幕录制       (切换器缩略图所必需)
```

- 没有「辅助功能」权限：右键手势、窗口移动 / 缩放、快捷键发送、切换器都不工作。
- 没有「屏幕录制」权限：切换器仍能用，但只显示 App 图标，没有窗口缩略图。授权后需要重启 App 才生效。
- 如果重新构建、改名或移动了 App 路径，macOS 可能会把它当成一个新的 App，需要重新授权。

## 构建

项目使用 Swift Package Manager 和一个打包脚本：

```bash
scripts/build-app.sh
```

脚本默认行为：

- 构建 `build/Velto.app`（本地输出）。
- 干掉旧的 Velto 进程，免得替换正在运行的 binary 出问题。
- 清理 Dropbox 留下的扩展属性，重签名，把 App 同步到 `/Applications/Velto.app`。

为什么默认安装到 `/Applications/`：macOS 26 的 TCC 对位于 Dropbox / CloudStorage 路径下的 ad-hoc 签名 App 表现不可靠 —— 即便在系统设置里勾上权限，ScreenCaptureKit 仍会报 `-3801`。放到 `/Applications/` 就一切正常，且这个路径稳定，授权一次永久有效。

只构建不安装：

```bash
SKIP_INSTALL=1 scripts/build-app.sh
```

构建完直接启动：

```bash
scripts/build-app.sh --run
```

## 配置备份

设置窗口提供：

- `导入配置`
- `导出配置`

导出的 JSON 文件包含：

- 鼠标手势名称、轨迹样本、快捷键绑定。
- 手势识别参数与作用目标。
- 窗口移动、缩放、最大化相关快捷键和修饰键。
- 滚轮缩放修饰键。
- 切换器的触发快捷键和全部偏好（分组、排序、筛选、外观、屏幕选择等）。
- 菜单栏图标、轨迹显示等 App 内偏好。

备份文件不包含 macOS 系统权限授权，也不包含开机自动启动状态 —— 这些属于当前机器的系统设置，重装系统后需要手动重新开启。

## 项目结构

```text
Package.swift
Resources/
  Info.plist
  Velto.icns
Sources/Velto/
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
  # 通用设置与共享 UI
  SettingsRootView.swift
  SidebarView.swift
  GeneralSettingsPage.swift
  DesignSystem.swift
  Components.swift
  RecorderViews.swift
  MouseControl/
    MouseControlModels.swift
    MouseControlController.swift
    MouseControlPage.swift
    MouseInputRecorderField.swift
  Gestures/
    GesturesPage.swift
    GestureEngine.swift
    GestureRecognizer.swift
    GestureOverlayController.swift
    GestureCaptureView.swift
    GestureTrailView.swift
  WindowManagement/
    WindowManagementPage.swift
    WindowDragController.swift
    WindowShortcutController.swift
    ContentZoomController.swift
  Switcher/
    SwitcherSettingsPage.swift
    SwitcherController.swift
    SwitcherPanel.swift
    SwitcherTilesView.swift
    SwitcherTileView.swift
    SwitcherImageLayer.swift
    SwitcherWindowList.swift
    SwitcherWindow.swift
    SwitcherApp.swift
    SwitcherSession.swift
    SwitcherFocus.swift
    SwitcherKeyTap.swift
    SwitcherThumbnails.swift
    SwitcherSpaces.swift
    SwitcherWindowDiscriminator.swift
    SwitcherDebugLog.swift
    AXCallQueue.swift
    SkyLightPrivate.swift
scripts/
  build-app.sh
```

核心模块：

- `EventTapManager`：监听右键手势、窗口移动 / 缩放修饰键、滚轮缩放修饰键，并调度对应动作。
- `MouseControl/MouseControlController`：处理鼠标滚轮平滑、滚动功能键和按钮绑定。
- `MouseControl/MouseControlPage`：侧边栏「鼠标控制」设置页，包含全局、按应用和按钮绑定配置。
- `Gestures/GestureEngine` + `GestureRecognizer`：手势状态机和样本匹配。
- `GestureTargetController` + `ShortcutSynthesizer`：定位目标窗口并合成快捷键事件。
- `Gestures/GestureOverlayController` + `GestureTrailView`：可选的手势轨迹反馈。
- `WindowManagement/WindowDragController` / `WindowShortcutController` / `ContentZoomController`：分别负责按修饰键拖动窗口、最大化快捷键、滚轮缩放。
- `Switcher/SwitcherController`：切换器总指挥，把 KeyTap、WindowList、Session、Panel、Focus 粘起来。
- `Switcher/SwitcherWindowList`：基于 AX + CGS 维护跨进程窗口清单，处理过滤、排序、合成窗判定。
- `Switcher/SwitcherPanel` + `SwitcherTilesView` + `SwitcherTileView`：浮动面板（NSGlassEffectView）和缩略图网格渲染。
- `Switcher/SwitcherThumbnails`：基于 ScreenCaptureKit 的缩略图抓取与缓存。
- `Switcher/SwitcherKeyTap`：截获 `⌘+Tab` 并替系统响应，关闭功能时透传给 macOS。
- `Switcher/SkyLightPrivate`：链接 `/System/Library/PrivateFrameworks/SkyLight.framework`，提供 CGS / SLPS / `_AXUIElementGetWindow` 等私有符号。
- 设置窗口：`SettingsRootView` + `SidebarView` + 各 `*Page`，共享 `DesignSystem.swift` 里的设计 token 和 `Components.swift`、`RecorderViews.swift` 里的通用控件。

## 调试

如果切换器列表里出现莫名其妙的窗口（过去遇到过微信 4.x 的空壳、Dropbox / 1Password 的小组件式窗口），可以用环境变量打开切换器调试日志：

```bash
pkill -x Velto
VELTO_SWITCHER_DEBUG=1 /Applications/Velto.app/Contents/MacOS/Velto
```

触发场景后日志会同时打到 stderr 和：

```text
~/Library/Logs/Velto/switcher-debug.log
```

只对 `AppQuirks.hidesSyntheticSwitcherWindows` 名单里的 App 打日志（目前是微信、Dropbox、1Password），其他应用静默，避免噪音。

## 注意事项

- 这是一个个人使用优先的小工具，不追求完整替代大型商业软件。
- 当前只支持右键触发鼠标手势。
- 当前手势动作以快捷键和基础窗口控制为主，不内置复杂动作系统。
- App 默认使用本机 ad-hoc 签名即可自用；公开分发时需要按 Apple 的分发要求重新签名、公证。
- 默认 Bundle Identifier 是 `com.face.myapp`，如果你要分发自己的版本，建议改成自己的反向域名。
- 切换器使用了 SkyLight 私有框架（`_AXUIElementGetWindow` 等），用于跨 Space 枚举窗口和判定可见性 —— 这是 Mac 窗口管理类工具的通用做法，但意味着这部分代码无法上架 Mac App Store。

## 紧急停止

如果测试中需要立刻退出，或从旧版本升级前旧进程还在运行：

```bash
pkill -x Velto
```

## License

当前仓库还没有选择开源许可证。正式公开前建议添加一个明确的 `LICENSE` 文件，例如 MIT、Apache-2.0 或 GPL 系列许可证。

新增「鼠标控制」入口参考了 [Caldis/Mos](https://github.com/Caldis/Mos) 的功能设计和滚动处理思路。Mos 使用 CC BY-NC 4.0 授权；如果后续公开或商业分发 Velto，需要重新确认这部分的授权兼容性。
