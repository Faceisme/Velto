# VibeGestures

VibeGestures 是一个面向 Apple Silicon Mac 的轻量级鼠标手势和窗口控制工具。它的核心目标是用尽量少的交互完成高频操作：按住鼠标右键画手势执行快捷键，按住修饰键拖动窗口，或按住修饰键滚动鼠标滚轮缩放页面内容。

项目最初是为了替代没有 Apple Silicon 原生版本的鼠标手势工具。当前版本只保留个人高频使用的功能，界面使用 macOS 26 的原生 Liquid Glass 风格。

## 功能特性

- Apple Silicon 原生构建，最低支持 macOS 26。
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
- 支持按住自定义修饰键移动光标下窗口。
- 支持按住自定义修饰键缩放光标下窗口。
- 支持快捷键最大化光标下窗口。
- 支持按住自定义修饰键并滚动鼠标滚轮，对网页、图片等内容执行平滑缩放。
- 支持开机自动启动。
- 支持隐藏菜单栏图标，默认不显示 Dock 图标。
- 支持导入、导出完整 App 配置备份。
- Event Tap 运行在独立高优先级线程上，降低主线程繁忙带来的延迟。

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
系统设置 -> 隐私与安全性 -> 辅助功能
系统设置 -> 隐私与安全性 -> 输入监控
```

如果右键手势、窗口移动/缩放或快捷键发送没有反应，优先检查“辅助功能”权限。如果重新构建、改名或移动了 App 路径，macOS 可能会把它当成一个新的 App，需要重新授权。

## 构建

项目使用 Swift Package Manager 和一个简单的打包脚本：

```bash
scripts/build-app.sh
```

构建产物：

```text
build/VibeGestures.app
```

运行：

```bash
open build/VibeGestures.app
```

长期自用时，建议把构建好的 App 放到固定位置，例如：

```text
/Applications/VibeGestures.app
```

然后针对这个固定路径完成辅助功能授权和开机启动设置。

## 配置备份

设置窗口提供：

- `导入配置`
- `导出配置`

导出的 JSON 文件包含：

- 鼠标手势名称。
- 鼠标手势轨迹样本。
- 手势快捷键绑定。
- 手势识别参数。
- 手势作用目标。
- 窗口移动、缩放、最大化相关快捷键。
- 滚轮缩放修饰键。
- 菜单栏图标、轨迹显示等 App 内偏好。

备份文件不包含 macOS 系统权限授权，也不包含开机自动启动状态。这些属于当前机器的系统设置，重装系统后需要手动重新开启。

## 项目结构

```text
Package.swift
Resources/
  Info.plist
  VibeGestures.icns
Sources/MouseGesture/
  AppDelegate.swift
  EventTapManager.swift
  GestureRecognizer.swift
  GestureCaptureView.swift
  GestureOverlayController.swift
  GestureTargetController.swift
  LoginItemManager.swift
  Models.swift
  PermissionManager.swift
  SettingsWindowController.swift
  ShortcutRecorderView.swift
  ShortcutSynthesizer.swift
  WindowManagementPage.swift
  main.swift
scripts/
  build-app.sh
```

核心模块：

- `EventTapManager`：监听右键手势、窗口移动/缩放修饰键、滚轮缩放修饰键，并调度对应动作。
- `GestureRecognizer`：根据录入样本识别鼠标手势。
- `GestureTargetController`：定位鼠标下方窗口或活动窗口，并向目标应用发送快捷键。
- `ShortcutSynthesizer`：合成并发送快捷键事件。
- `GestureOverlayController`：绘制可选的手势轨迹反馈。
- `WindowManagementPage`：管理窗口移动、缩放、最大化和滚轮缩放设置。
- `SettingsWindowController`：管理设置窗口生命周期。

## 注意事项

- 这是一个个人使用优先的小工具，不追求完整替代大型商业鼠标手势软件。
- 当前只支持右键触发鼠标手势。
- 当前动作以快捷键和基础窗口控制为主，不内置复杂动作系统。
- App 默认使用本机 ad-hoc 签名即可自用；公开分发时需要按 Apple 的分发要求重新签名、公证。
- 默认 Bundle Identifier 是 `com.face.myapp`，如果你要分发自己的版本，建议改成自己的反向域名。

## 紧急停止

如果测试中需要立刻退出：

```bash
pkill -x VibeGestures
```

从旧版本升级时，如果旧进程还在运行，也可以执行：

```bash
pkill -x MyGestures
```

## License

当前仓库还没有选择开源许可证。正式公开前建议添加一个明确的 `LICENSE` 文件，例如 MIT、Apache-2.0 或 GPL 系列许可证。
