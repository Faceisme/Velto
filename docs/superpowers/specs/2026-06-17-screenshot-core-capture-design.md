# 截图功能 · 核心捕获设计文档

**日期：** 2026-06-17
**状态：** 已批准，待实现
**阶段：** Phase 1 / 3（核心捕获）

---

## 1. 背景与目标

给 Velto 加入截图功能，对标 [Xnip](https://zh.xnipapp.com/)。整套截图能力拆为三个相对独立的子系统，各自一份 spec → plan → 实现：

1. **核心捕获(本文档)** — 全局快捷键唤起 → 冻结快照 → 区域框选 / 窗口自动识别 → 截后浮动工具栏与快捷键(空格存剪贴板、⌘S 存目录、Esc 取消)。
2. **标注编辑器(下一份 spec)** — 截完进入标注层,画箭头/矩形/文字/马赛克/高亮/序号/裁剪。
3. **滚动长截图(更后)** — 自动滚动目标窗口 + 逐帧图像拼接。

本期目标:把**地基**做扎实并跑通屏幕录制权限,交付一个"框选/选窗 → 复制或存盘"的可用闭环。标注与滚动不在本期范围,但状态机、工具栏、键位要为它们**预留接口**。

### 平台前提

- 仅支持 macOS 26+,`Package.swift` 已是 `.macOS(.v26)`。**不写任何老版本兼容分支**(`if #available`、弃用 API 回退等一律省掉),直接用最新 API。

---

## 2. 已确认的关键决策

| 决策点 | 选择 |
|---|---|
| 捕获 API | **ScreenCaptureKit**(`SCScreenshotManager.captureImage`),最新、非弃用 |
| 框选模型 | **冻结快照** —— 唤起瞬间截全屏冻结,在静态图上框选 |
| 窗口识别 | **窗口级**(`CGWindowListCopyWindowInfo` 找光标下窗口边界),不做 AX 子元素 |
| ⌘S 保存 | **静默存预设目录**,自动命名,PNG;默认目录桌面 |
| 全局触发键 | **默认留空**,首次在设置里录;强制含真修饰键 |
| 会话内按键 | 空格/⌘S/S/Esc,**全部可自定义** |
| 取色放大镜 | **带上,默认开**,设置可关 |

---

## 3. 架构

### 新增文件

```
Sources/Velto/Screenshot/
├── ScreenshotController.swift        # 单例,全局触发键接入 + 会话编排(参考 SwitcherController)
├── ScreenshotShortcutController.swift# 挂 EventTapManager 的全局触发键匹配(参考 WindowShortcutController)
├── ScreenshotSession.swift           # 一次截图的状态机:冻结→框选→决策→输出
├── ScreenshotOverlayWindow.swift     # 每屏一个无边框覆盖窗口
├── ScreenshotOverlayView.swift       # 框选交互绘制:暗罩/选区/八手柄/尺寸读数/放大镜
├── WindowFrameDetector.swift         # CGWindowList 找光标下最上层窗口边界(纯逻辑,可单测)
├── ScreenshotCapturer.swift          # SCK 抓全屏快照 + 按区域裁剪
├── ScreenshotImageWriter.swift       # 存剪贴板 / 写 PNG(自动命名)
├── ScreenshotGeometry.swift          # 选区矩形归一化、手柄命中、跨屏 clamp、坐标换算(纯逻辑,可单测)
├── ScreenshotPreferences.swift       # 配置(Codable,嵌进 AppPreferences)
├── ScreenshotPage.swift              # SwiftUI 设置页
└── ScreenshotDebugLog.swift          # 独立调试开关日志(参考各模块 DebugLog)
```

### 改动现有文件

| 文件 | 改动 |
|---|---|
| `SettingsRootView.swift` | `MGPage` 加 `.screenshot`,补 `label`/`icon`(如 `camera.viewfinder`) |
| `SidebarView.swift` | 「功能」组加一项 `.screenshot` |
| `SettingsRootView.swift`(Host) | `SettingsPageHostController.cachedController` 加 `.screenshot` 分支 |
| `Models.swift`(AppPreferences) | 嵌入 `screenshot: ScreenshotPreferences`,`init` + 解码用 `decodeIfPresent` 回退默认(兼容旧配置) |
| `EventTapManager.swift` | keyDown 分发处接入 `ScreenshotShortcutController.handleKeyDown`(与窗口快捷键并列) |
| `AppDelegate.swift` | `applicationDidFinishLaunching` 启动 `ScreenshotController.shared`(注入触发键快照、预热 SCShareableContent) |
| 配置导入导出 | 把 `screenshot` 纳入(项目已有导入导出覆盖逻辑,按同模式扩展) |

---

## 4. 状态机与交互

```
Idle ──(全局触发键)──> Capturing ──(快照就绪)──> Selecting
                                                   │
                          ┌── 单击命中窗口 ────────┤
                          │                        │
                          └── 拖拽画框 ────────────┘
                                                   ▼
                                                Selected(待决策)
                                       ┌───────────┼───────────┬──────────┐
                                    空格=复制   ⌘S=存盘    Esc=取消   S=滚动(占位)
                                       └───────────┴───────────┘
                                                   ▼
                                                Output ──> Idle
```

1. **Idle** — 等全局触发键。
2. **Capturing** — `ScreenshotController` 立刻用 SCK 抓**所有屏幕**的全屏快照冻结。为每块 `NSScreen` 建一个无边框覆盖窗口(层级高于一切普通窗口,盖满整屏),画上对应快照 + 半透明暗罩。
3. **Selecting**
   - **悬停不拖** → `WindowFrameDetector` 高亮光标下最上层窗口边界(描边 + 该窗区域不加暗);**单击 = 采纳该窗口为选区**。
   - **拖拽** → 画矩形选区,实时显示尺寸 `W×H`;选区内亮、外暗;八个手柄可改大小;选区内可整体拖移。
   - **放大镜** → 光标旁浮动取色放大镜:放大附近像素 + 十字准星 + 像素坐标(x, y)+ 颜色 HEX/RGB。默认开,可关。
4. **Selected(待决策)** — 选区旁浮出小工具栏:尺寸读数 +「复制 / 保存 / 取消」按钮。**phase 2 标注工具就 dock 在这条工具栏**。键盘:
   - **空格 = 复制到剪贴板 → 结束**
   - **⌘S = 静默存预设目录 → 结束**(可选轻提示)
   - **Esc = 取消 → 结束**
   - **Enter = 默认动作(= 复制)**
   - **S = 滚动长截图** —— **phase 3**,本期占位:键位与工具栏槽位预留,触发时灰显或提示「即将支持」,不实现拼接逻辑。
5. **Output** — `ScreenshotImageWriter` 从冻结快照按选区裁剪 → `CGImage`/`NSImage` → 写 `NSPasteboard` 或写 PNG 文件,销毁所有覆盖窗口,回到 Idle。

### 多屏处理

- 每块 `NSScreen` 一个覆盖窗口,各抓各屏的快照。
- 选区**限制在起点所在屏**(简单稳妥),跨屏选区留后续。
- 坐标换算复用项目已有的 `DisplayCoordinateConverter`(屏幕坐标 / 全局坐标 / 快照像素三者互转,含 Retina backing scale)。

---

## 5. 捕获管线(ScreenCaptureKit)

- 唤起时:`SCShareableContent.current` 拿 displays;对每个 display 用 `SCScreenshotManager.captureImage(contentFilter:configuration:)` 抓全屏 `CGImage`。
  - `SCContentFilter(display:excludingWindows:)` 排除自身覆盖窗口(虽然此刻覆盖窗口还没建,顺序上**先抓图再建窗**)。
  - `SCStreamConfiguration` 的宽高用 display 的**像素尺寸**(`width × backingScaleFactor`),保证 Retina 清晰。
- 性能:`SCShareableContent` 首次查询有延迟 → App 启动后**预热**一次缓存;触发时若缓存可用直接走快路径。
- 裁剪:选区是点坐标,乘以 backing scale 换成快照像素矩形,`CGImage.cropping(to:)`。

---

## 6. 窗口边界识别(WindowFrameDetector)

- `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` 拿当前屏上窗口列表(按前后顺序)。
- 给定光标全局坐标,返回**命中的最上层窗口**的 `kCGWindowBounds`,排除:自身覆盖窗口、`kCGWindowLayer != 0` 的系统层(菜单栏、Dock 等按需过滤)。
- 纯逻辑(输入窗口数组 + 光标点 → 输出边界),**可单测**(注入 mock 窗口数组)。

---

## 7. 快捷键与权限

### 全局触发键
- `Shortcut` 结构(keyCode + modifierFlags),经 `EventTapManager` 在 tap 线程分发到 `ScreenshotShortcutController.handleKeyDown`(模式同 `WindowShortcutController`)。
- 强制 `hasRealModifier`(避免裸键全局吞普通输入)。
- **默认留空**;设置页用项目现有的快捷键录制控件(参考其他模块的 Recorder)录入。系统已占 ⌘⇧3/4/5,留空可避免默认冲突。

### 会话内按键
- 覆盖窗口是 key window;用 `NSEvent` local key monitor / `keyDown` 处理。裸键(空格/S/Esc)只在会话期间生效,安全。
- 全部可自定义,存在 `ScreenshotPreferences`。

### 权限
- 复用 `PermissionManager.isScreenRecordingTrusted`(切换器缩略图已在用)。
- 触发前 preflight;未授权 → 走现有 `requestScreenRecordingPrompt` + `openPrivacySettings` 引导,提示授权后需重启,**不进会话**。

---

## 8. 配置(ScreenshotPreferences)

嵌进 `AppPreferences`,复用现有 JSON 持久化与导入导出。字段:

```swift
struct ScreenshotPreferences: Codable, Equatable {
  var enabled: Bool                 // 默认 true
  var triggerShortcut: Shortcut?    // 默认 nil(留空)
  var copyKey: UInt16               // 默认 空格 (49)
  var saveShortcut: Shortcut        // 默认 ⌘S
  var cancelKey: UInt16             // 默认 Esc (53)
  var scrollKey: UInt16             // 默认 S —— phase 3 占位
  var saveDirectory: String         // 默认 ~/Desktop
  var saveAlsoCopiesToClipboard: Bool // 默认 false
  var imageFormat: ImageFormat      // 先固定 .png,留枚举
  var showMagnifier: Bool           // 默认 true
}
```

- 文件名生成:`Velto-YYYY-MM-DD-HHmmss.png`(纯逻辑,可单测)。
- 解码用 `decodeIfPresent` 给默认,兼容旧配置(无此字段时整体回退默认)。

---

## 9. 设置页(ScreenshotPage)

延续项目 Liquid Glass 视觉与各 Page 结构:
- 顶部:功能总开关 + 状态/权限提示(未授权时显式引导)。
- 全局触发键录制行。
- 会话内按键(复制/保存/取消)录制行;滚动键行**灰显**标「即将支持」。
- 保存目录选择器(默认桌面)+「保存同时复制到剪贴板」开关。
- 取色放大镜开关。

---

## 10. 错误处理

| 情况 | 处理 |
|---|---|
| 无屏幕录制权限 | 引导面板,不进会话 |
| SCK 抓图失败 | `ScreenshotDebugLog` 记录 + 轻提示,安全退出会话,不崩 |
| 保存目录不存在/不可写 | 回退桌面 + 提示 |
| 空选区(点了没拖也没命中窗口) | 忽略,留在 Selecting |
| 会话中再次按触发键 / 切前台 | 取消当前会话,清理覆盖窗口 |

---

## 11. 测试

遵守项目「Tests 不入库」约定([no-committing-test-files]):测试**照写照跑,只是不 `git add`**。

**纯逻辑单测(`Tests/VeltoTests/`):**
- `WindowFrameDetector`:窗口数组 + 光标点 → 命中最上层窗口边界;层级/自身窗口过滤。
- 文件名生成:时间戳 → `Velto-YYYY-MM-DD-HHmmss.png`。
- `ScreenshotGeometry`:选区矩形归一化(任意方向起止点 → 正矩形)、八手柄命中测试、跨屏 clamp、坐标↔像素换算(含 backing scale)。
- 状态机转移:Selecting→Selected→Output/Cancel 的合法路径。

**实机验证(不可单测部分):** UI / SCK / 权限走 `./scripts/build-app.sh --run`([velto-rebuild-deploy-flow]),覆盖:框选、选窗、复制、存盘、放大镜、权限引导、多屏。

---

## 12. 不在本期范围(未来阶段)

- **标注编辑器**(Phase 2):箭头/矩形/椭圆/文字/画笔/马赛克/高亮/序号/裁剪。本期工具栏与状态机为其预留 dock 槽位与 Selected→标注 的转移点。
- **滚动长截图**(Phase 3):自动滚动 + 逐帧拼接。本期 `S` 键与工具栏槽位占位,不实现。
- AX 子元素级识别(工具栏/按钮)。
- 跨屏选区。
- 自定义文件名模板、非 PNG 格式。

---

## 13. 待办 / 风险

- ScreenCaptureKit 首帧延迟 → 启动预热缓存缓解;若仍偶发慢,后续可评估常驻 `SCStream`。
- 覆盖窗口层级要高于菜单栏/Dock 又不挡系统授权弹窗 —— 实现时实测层级常量。
- 多屏 backing scale 不一致时的坐标换算正确性 —— 重点单测 + 多屏实机验证。
