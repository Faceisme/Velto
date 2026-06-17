# 截图功能 · 核心捕获 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 Velto 加「核心捕获」截图能力:全局快捷键唤起 → 冻结全屏快照 → 框选 / 单击选窗 → 浮动工具栏与快捷键(空格存剪贴板、⌘S 存预设目录、Esc 取消),含取色放大镜。

**Architecture:** 新建 `Sources/Velto/Screenshot/` 模块,延续项目「Controller + Session + Overlay + Preferences + Page + DebugLog」分工。捕获用 ScreenCaptureKit 抓全屏冻结快照,所有框选/裁剪在静态图上算;窗口边界用 `CGWindowListCopyWindowInfo` 只读识别。全局触发键经现有 `EventTapManager` 在 tap 线程分发到 `ScreenshotShortcutController`,匹配后切回主线程由 `ScreenshotController` 启动会话。配置嵌进 `AppPreferences`,复用现有 JSON 持久化与导入导出。

**Tech Stack:** Swift 6.2 / macOS 26、AppKit、SwiftUI(设置页)、ScreenCaptureKit、CoreGraphics、swift-testing(`import Testing`)。

## Global Constraints

> 每个任务都隐含遵守以下全局约束(值逐字摘自 spec 与项目约定):

- **仅 macOS 26+**:`Package.swift` 已是 `.macOS(.v26)`。不写任何老版本兼容分支(`if #available`、弃用 API 回退一律省掉),直接用最新 API。
- **缩进 2 空格**;代码注释与设置页文案用中文。
- **捕获用 ScreenCaptureKit**(`SCScreenshotManager.captureImage`);窗口识别用 `CGWindowListCopyWindowInfo`(非弃用)。
- **测试不入库**:`Tests/` 下文件照写照跑,**`git commit` 只 add `Sources/` 与 `docs/`,绝不 add `Tests/`**。
- **Velto 可执行目标无法被测试目标 import**:该目标代码的单测一律用**源码文本断言**(`import Testing`,经 `#filePath` 读 `.swift` 源文件字符串,`#expect(src.contains(...))`),真实行为靠实机验证。
- **实机验证命令**:`./scripts/build-app.sh --run`(固定证书签名 + 部署 `/Applications/`,TCC 授权才稳)。
- **全局触发键**:`Shortcut`,强制 `hasRealModifier`(避免裸键全局吞输入),**默认 nil**。
- **配置接入**:新增配置嵌进 `AppPreferences`,`init(from:)` 用 `decodeIfPresent ?? Self.defaults.x` 兼容旧配置。
- **坐标换算**:屏幕/全局/像素互转复用现有 `DisplayCoordinateConverter`。

---

## 文件结构

```
Sources/Velto/Screenshot/
├── ScreenshotPreferences.swift       # Codable 配置 + ImageFormat + .defaults
├── ScreenshotDebugLog.swift          # 独立调试开关日志(VELTO_SCREENSHOT_DEBUG)
├── ScreenshotGeometry.swift          # 纯逻辑:选区归一化/手柄命中/clamp/像素换算/文件名
├── WindowFrameDetector.swift         # 纯逻辑:CGWindowList 找光标下窗口边界
├── ScreenshotCapturer.swift          # SCK 抓全屏快照 + 按区域裁剪
├── ScreenshotImageWriter.swift       # 存剪贴板 / 写 PNG
├── ScreenshotOverlayWindow.swift     # 每屏一个无边框覆盖窗口
├── ScreenshotOverlayView.swift       # 暗罩/选区/手柄/尺寸读数/放大镜/键盘处理
├── ScreenshotSession.swift           # 单次会话状态机
├── ScreenshotController.swift        # 单例:触发入口 + 会话编排
├── ScreenshotShortcutController.swift# tap 线程全局触发键匹配
└── ScreenshotPage.swift              # SwiftUI 设置页
```

改动现有文件:`Models.swift`(嵌配置)、`EventTapManager.swift`(分发触发键 + 推快照)、`AppDelegate.swift`(启动 + 临时测试菜单项)、`SettingsRootView.swift`(MGPage + Host 分支)、`SidebarView.swift`(侧栏项)、导入导出路径(`screenshot` 随 `AppPreferences` 自动带上,无需额外改)。

---

## Task 1: 配置与调试日志地基

**Files:**
- Create: `Sources/Velto/Screenshot/ScreenshotPreferences.swift`
- Create: `Sources/Velto/Screenshot/ScreenshotDebugLog.swift`
- Modify: `Sources/Velto/Models.swift`(AppPreferences:加 `screenshot` 属性、memberwise init 形参、`init(from:)` 解码行、`defaults`)
- Test: `Tests/VeltoTests/ScreenshotPreferencesTests.swift`(源码文本断言,不入库)

**Interfaces:**
- Produces:
  - `enum ScreenshotImageFormat: String, Codable { case png }`
  - `struct ScreenshotPreferences: Codable, Equatable`,字段:`enabled: Bool`、`triggerShortcut: Shortcut?`、`copyKeyCode: UInt16`、`saveShortcut: Shortcut`、`cancelKeyCode: UInt16`、`scrollKeyCode: UInt16`、`saveDirectoryPath: String`、`saveAlsoCopiesToClipboard: Bool`、`imageFormat: ScreenshotImageFormat`、`showMagnifier: Bool`;静态 `static let defaults`
  - `enum ScreenshotDebugLog { static func log(_:); static func setEnabled(_:) }`
  - `AppPreferences.screenshot: ScreenshotPreferences`

- [ ] **Step 1: 写配置结构 ScreenshotPreferences.swift**

```swift
import AppKit
import Foundation

enum ScreenshotImageFormat: String, Codable, Equatable, CaseIterable {
  case png
}

/// 截图模块全部配置。嵌进 AppPreferences,与手势/切换器共享一份 JSON 持久化。
/// keyCode 默认值:空格 49、S 1、Esc 53;saveShortcut 默认 ⌘S(keyCode 1 + maskCommand)。
struct ScreenshotPreferences: Codable, Equatable {
  var enabled: Bool
  /// 全局触发键。默认 nil:首次让用户在设置里录,避免与系统 ⌘⇧3/4/5 冲突。
  var triggerShortcut: Shortcut?
  /// 会话内:复制到剪贴板(默认空格 49)
  var copyKeyCode: UInt16
  /// 会话内:存预设目录(默认 ⌘S)
  var saveShortcut: Shortcut
  /// 会话内:取消(默认 Esc 53)
  var cancelKeyCode: UInt16
  /// 会话内:滚动长截图(默认 S 1)—— Phase 3 占位,本期不实现拼接
  var scrollKeyCode: UInt16
  /// ⌘S 静默保存目录,默认桌面
  var saveDirectoryPath: String
  /// 保存时是否同时复制到剪贴板,默认关
  var saveAlsoCopiesToClipboard: Bool
  var imageFormat: ScreenshotImageFormat
  /// 取色放大镜,默认开
  var showMagnifier: Bool

  static let defaults = ScreenshotPreferences(
    enabled: true,
    triggerShortcut: nil,
    copyKeyCode: 49,
    saveShortcut: Shortcut(
      keyCode: 1,
      modifierFlags: UInt64(CGEventFlags.maskCommand.rawValue),
      displayName: "⌘S"
    ),
    cancelKeyCode: 53,
    scrollKeyCode: 1,
    saveDirectoryPath: (NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first
      ?? NSHomeDirectory() + "/Desktop"),
    saveAlsoCopiesToClipboard: false,
    imageFormat: .png,
    showMagnifier: true
  )

  init(
    enabled: Bool, triggerShortcut: Shortcut?, copyKeyCode: UInt16, saveShortcut: Shortcut,
    cancelKeyCode: UInt16, scrollKeyCode: UInt16, saveDirectoryPath: String,
    saveAlsoCopiesToClipboard: Bool, imageFormat: ScreenshotImageFormat, showMagnifier: Bool
  ) {
    self.enabled = enabled
    self.triggerShortcut = triggerShortcut
    self.copyKeyCode = copyKeyCode
    self.saveShortcut = saveShortcut
    self.cancelKeyCode = cancelKeyCode
    self.scrollKeyCode = scrollKeyCode
    self.saveDirectoryPath = saveDirectoryPath
    self.saveAlsoCopiesToClipboard = saveAlsoCopiesToClipboard
    self.imageFormat = imageFormat
    self.showMagnifier = showMagnifier
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self.defaults
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    triggerShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .triggerShortcut) ?? d.triggerShortcut
    copyKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .copyKeyCode) ?? d.copyKeyCode
    saveShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .saveShortcut) ?? d.saveShortcut
    cancelKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .cancelKeyCode) ?? d.cancelKeyCode
    scrollKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .scrollKeyCode) ?? d.scrollKeyCode
    saveDirectoryPath = try c.decodeIfPresent(String.self, forKey: .saveDirectoryPath) ?? d.saveDirectoryPath
    saveAlsoCopiesToClipboard = try c.decodeIfPresent(Bool.self, forKey: .saveAlsoCopiesToClipboard) ?? d.saveAlsoCopiesToClipboard
    imageFormat = try c.decodeIfPresent(ScreenshotImageFormat.self, forKey: .imageFormat) ?? d.imageFormat
    showMagnifier = try c.decodeIfPresent(Bool.self, forKey: .showMagnifier) ?? d.showMagnifier
  }
}
```

- [ ] **Step 2: 写 ScreenshotDebugLog.swift**

照搬 `Sources/Velto/TrackpadGesture/TrackpadGestureDebugLog.swift` 模式,改名/改 env/改文件名:

```swift
import Foundation

enum ScreenshotDebugLog {
  private static let stateQueue = DispatchQueue(label: "com.velto.screenshot.debuglog.state")
  private static let envForced = ProcessInfo.processInfo.environment["VELTO_SCREENSHOT_DEBUG"] == "1"
  private nonisolated(unsafe) static var _enabled = ProcessInfo.processInfo.environment["VELTO_SCREENSHOT_DEBUG"] == "1"
  private nonisolated(unsafe) static var _handle: FileHandle?
  private nonisolated(unsafe) static var _handleOpened = false

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
  }()

  static var isEnabled: Bool { stateQueue.sync { _enabled } }
  static func setEnabled(_ enabled: Bool) { stateQueue.sync { _enabled = enabled || envForced } }

  static func log(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    let line = "[\(dateFormatter.string(from: Date()))] \(message())\n"
    FileHandle.standardError.write(Data(line.utf8))
    if let handle = fileHandle() { try? handle.write(contentsOf: Data(line.utf8)) }
  }

  private static func fileHandle() -> FileHandle? {
    stateQueue.sync {
      if !_handleOpened { _handleOpened = true; _handle = openLogFile() }
      return _handle
    }
  }

  private static func openLogFile() -> FileHandle? {
    let fm = FileManager.default
    guard let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Logs", isDirectory: true)
      .appendingPathComponent("Velto", isDirectory: true) else { return nil }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("screenshot-debug.log")
    if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
    let handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
    return handle
  }
}
```

- [ ] **Step 3: 把 screenshot 接进 AppPreferences(Models.swift)**

四处改动,逐字对齐现有 `switcher` / `inputSourceSwitch` 的写法:
1. 在 `var inputSourceSwitch: InputSourceSwitchPreferences`(`Models.swift:86`)后加:
   ```swift
   /// 截图模块配置 —— 子结构在 Screenshot/ScreenshotPreferences.swift。
   var screenshot: ScreenshotPreferences
   ```
2. memberwise `init` 形参表末尾(`inputSourceSwitch: InputSourceSwitchPreferences` 后,`Models.swift:103`)加 `, screenshot: ScreenshotPreferences`,函数体末尾(`self.inputSourceSwitch = inputSourceSwitch` 后)加 `self.screenshot = screenshot`。
3. `init(from:)` 末尾(`Models.swift:141` 后)加:
   ```swift
   screenshot = try container.decodeIfPresent(ScreenshotPreferences.self, forKey: .screenshot) ?? Self.defaults.screenshot
   ```
4. `static let defaults`(`Models.swift:159` `inputSourceSwitch: .defaults` 后)加 `, screenshot: .defaults`。

- [ ] **Step 4: 写源码文本断言测试(不入库)**

```swift
// Tests/VeltoTests/ScreenshotPreferencesTests.swift
import Foundation
import Testing

private func screenshotSource(_ rel: String) throws -> String {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}

@Test func screenshotPreferencesHasAllFields() throws {
  let src = try screenshotSource("Sources/Velto/Screenshot/ScreenshotPreferences.swift")
  for token in ["var enabled", "var triggerShortcut", "var copyKeyCode", "var saveShortcut",
                "var cancelKeyCode", "var scrollKeyCode", "var saveDirectoryPath",
                "var saveAlsoCopiesToClipboard", "var imageFormat", "var showMagnifier",
                "static let defaults"] {
    #expect(src.contains(token))
  }
  // 默认键位
  #expect(src.contains("copyKeyCode: 49"))   // 空格
  #expect(src.contains("cancelKeyCode: 53"))  // Esc
}

@Test func appPreferencesWiresScreenshotWithDecodeIfPresent() throws {
  let src = try screenshotSource("Sources/Velto/Models.swift")
  #expect(src.contains("var screenshot: ScreenshotPreferences"))
  #expect(src.contains("forKey: .screenshot) ?? Self.defaults.screenshot"))
  #expect(src.contains("screenshot: .defaults"))
}
```

- [ ] **Step 5: 跑测试(应通过)+ 构建**

Run: `swift test --filter ScreenshotPreferences` → 期望 PASS
Run: `swift build` → 期望编译通过(0 error)

- [ ] **Step 6: 提交(只 add Sources)**

```bash
git add Sources/Velto/Screenshot/ScreenshotPreferences.swift \
        Sources/Velto/Screenshot/ScreenshotDebugLog.swift \
        Sources/Velto/Models.swift
git commit -m "截图:配置结构与调试日志地基,接入 AppPreferences"
```

---

## Task 2: ScreenshotGeometry(纯逻辑:选区/手柄/clamp/像素/文件名)

**Files:**
- Create: `Sources/Velto/Screenshot/ScreenshotGeometry.swift`
- Test: `Tests/VeltoTests/ScreenshotGeometryTests.swift`(源码文本断言,不入库)

**Interfaces:**
- Produces:
  - `enum ScreenshotHandle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }`
  - `enum ScreenshotGeometry`:
    - `static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect`(任意方向起止点 → 正矩形)
    - `static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect`
    - `static func handleRects(for selection: CGRect, handleSize: CGFloat) -> [ScreenshotHandle: CGRect]`
    - `static func handle(at point: CGPoint, selection: CGRect, handleSize: CGFloat) -> ScreenshotHandle?`
    - `static func resized(_ selection: CGRect, handle: ScreenshotHandle, to point: CGPoint) -> CGRect`
    - `static func pixelRect(forPointRect rect: CGRect, originInPoints origin: CGPoint, scale: CGFloat) -> CGRect`(选区点坐标 → 快照像素矩形)
    - `static func suggestedFileName(date: Date, format: ScreenshotImageFormat) -> String` → `Velto-yyyy-MM-dd-HHmmss.png`

- [ ] **Step 1: 写 ScreenshotGeometry.swift**

```swift
import CoreGraphics
import Foundation

enum ScreenshotHandle: CaseIterable {
  case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

enum ScreenshotGeometry {
  /// 任意方向的两点 → 正矩形(始终非负宽高)。
  static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
  }

  /// 把选区夹进 bounds(超出部分截断)。
  static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
    rect.intersection(bounds)
  }

  /// 八个手柄各自的命中矩形(以手柄中心 ± handleSize/2)。
  static func handleRects(for s: CGRect, handleSize h: CGFloat) -> [ScreenshotHandle: CGRect] {
    let half = h / 2
    func r(_ cx: CGFloat, _ cy: CGFloat) -> CGRect { CGRect(x: cx - half, y: cy - half, width: h, height: h) }
    let midX = s.midX, midY = s.midY, minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
    return [
      .topLeft: r(minX, maxY), .top: r(midX, maxY), .topRight: r(maxX, maxY),
      .right: r(maxX, midY), .bottomRight: r(maxX, minY), .bottom: r(midX, minY),
      .bottomLeft: r(minX, minY), .left: r(minX, midY)
    ]
  }

  static func handle(at p: CGPoint, selection s: CGRect, handleSize h: CGFloat) -> ScreenshotHandle? {
    for (handle, rect) in handleRects(for: s, handleSize: h) where rect.contains(p) { return handle }
    return nil
  }

  /// 拖某个手柄到新点后的选区(对边固定,被拖的边/角跟随)。返回未归一化前先归一化。
  static func resized(_ s: CGRect, handle: ScreenshotHandle, to p: CGPoint) -> CGRect {
    var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
    switch handle {
    case .topLeft:     minX = p.x; maxY = p.y
    case .top:         maxY = p.y
    case .topRight:    maxX = p.x; maxY = p.y
    case .right:       maxX = p.x
    case .bottomRight: maxX = p.x; minY = p.y
    case .bottom:      minY = p.y
    case .bottomLeft:  minX = p.x; minY = p.y
    case .left:        minX = p.x
    }
    return normalizedRect(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: maxY))
  }

  /// 选区(覆盖窗口点坐标,原点在窗口左下)→ 快照像素矩形。
  /// originInPoints:窗口/屏幕原点;scale:backingScaleFactor。
  static func pixelRect(forPointRect rect: CGRect, originInPoints origin: CGPoint, scale: CGFloat) -> CGRect {
    CGRect(x: (rect.origin.x - origin.x) * scale, y: (rect.origin.y - origin.y) * scale,
           width: rect.width * scale, height: rect.height * scale)
  }

  static func suggestedFileName(date: Date = Date(), format: ScreenshotImageFormat = .png) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
    return "Velto-\(f.string(from: date)).\(format.rawValue)"
  }
}
```

- [ ] **Step 2: 写源码文本断言测试(不入库)**

```swift
// Tests/VeltoTests/ScreenshotGeometryTests.swift
import Foundation
import Testing

@Test func screenshotGeometryDefinesExpectedAPI() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let src = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScreenshotGeometry.swift"), encoding: .utf8)
  for token in ["enum ScreenshotHandle", "func normalizedRect", "func clamp",
                "func handleRects", "func handle(at", "func resized",
                "func pixelRect", "func suggestedFileName", "Velto-\\("] {
    #expect(src.contains(token))
  }
}
```

- [ ] **Step 3: 跑测试 + 构建**

Run: `swift test --filter ScreenshotGeometry` → PASS
Run: `swift build` → 0 error

> 注:几何/像素换算的**真实行为正确性**(归一化、手柄拖动、Retina 像素矩形)在 Task 6/7 覆盖窗口接好后,经 `./scripts/build-app.sh --run` 实机框选验证(选区尺寸读数、裁剪结果清晰度)。

- [ ] **Step 4: 提交**

```bash
git add Sources/Velto/Screenshot/ScreenshotGeometry.swift
git commit -m "截图:几何纯逻辑(选区归一化/手柄/clamp/像素换算/文件名)"
```

---

## Task 3: WindowFrameDetector(光标下窗口边界)

**Files:**
- Create: `Sources/Velto/Screenshot/WindowFrameDetector.swift`
- Test: `Tests/VeltoTests/WindowFrameDetectorTests.swift`(源码文本断言,不入库)

**Interfaces:**
- Consumes:无
- Produces:
  - `enum WindowFrameDetector`:
    - `static func windowFrame(atGlobalPoint p: CGPoint, excludingPID pid: pid_t) -> CGRect?`(从 `CGWindowListCopyWindowInfo` 实时取;返回**全局坐标系**矩形,坐标系与 CGWindowList 一致即左上原点)
    - `static func hitWindowBounds(in windows: [[String: Any]], atGlobalPoint p: CGPoint, excludingPID pid: pid_t) -> CGRect?`(纯函数版,接收已取好的窗口数组,便于推理/测试)

- [ ] **Step 1: 写 WindowFrameDetector.swift**

```swift
import AppKit
import CoreGraphics
import Foundation

enum WindowFrameDetector {
  /// 实时查询:返回光标下最上层窗口的边界(全局坐标,CGWindowList 语义=左上原点)。
  static func windowFrame(atGlobalPoint p: CGPoint, excludingPID pid: pid_t) -> CGRect? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    return hitWindowBounds(in: infos, atGlobalPoint: p, excludingPID: pid)
  }

  /// 纯逻辑:窗口数组按前后顺序(CGWindowList 已按 z 序,前在先),取第一个
  /// layer==0、非自身 PID、且 bounds 命中光标的窗口。
  static func hitWindowBounds(in windows: [[String: Any]], atGlobalPoint p: CGPoint, excludingPID pid: pid_t) -> CGRect? {
    for w in windows {
      if let layer = w[kCGWindowLayer as String] as? Int, layer != 0 { continue }
      if let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == pid { continue }
      guard let dict = w[kCGWindowBounds as String] as? [String: CGFloat],
            let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
      if rect.contains(p) { return rect }
    }
    return nil
  }
}
```

- [ ] **Step 2: 写源码文本断言测试(不入库)**

```swift
// Tests/VeltoTests/WindowFrameDetectorTests.swift
import Foundation
import Testing

@Test func windowFrameDetectorDefinesPureHitFunction() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let src = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/WindowFrameDetector.swift"), encoding: .utf8)
  #expect(src.contains("func windowFrame(atGlobalPoint"))
  #expect(src.contains("func hitWindowBounds(in"))
  #expect(src.contains("layer != 0"))              // 过滤系统层
  #expect(src.contains("owner == pid"))            // 过滤自身窗口
  #expect(src.contains("CGWindowListCopyWindowInfo"))
}
```

- [ ] **Step 3: 跑测试 + 构建**

Run: `swift test --filter WindowFrameDetector` → PASS
Run: `swift build` → 0 error

- [ ] **Step 4: 提交**

```bash
git add Sources/Velto/Screenshot/WindowFrameDetector.swift
git commit -m "截图:CGWindowList 识别光标下窗口边界"
```

---

## Task 4: ScreenshotCapturer(SCK 抓全屏快照 + 裁剪)

**Files:**
- Create: `Sources/Velto/Screenshot/ScreenshotCapturer.swift`
- Test: `Tests/VeltoTests/ScreenshotCapturerTests.swift`(源码文本断言,不入库)

**Interfaces:**
- Consumes:`ScreenshotGeometry.pixelRect`、`ScreenshotDebugLog`
- Produces:
  - `struct DisplaySnapshot { let displayID: CGDirectDisplayID; let image: CGImage; let frame: CGRect /* 全局点坐标 */; let scale: CGFloat }`
  - `enum ScreenshotCapturer`:
    - `static func prewarm()`(后台预取 `SCShareableContent`,降首帧延迟)
    - `static func captureAllDisplays() async throws -> [DisplaySnapshot]`
    - `static func crop(_ snapshot: DisplaySnapshot, toPointRect rect: CGRect) -> CGImage?`

- [ ] **Step 1: 写 ScreenshotCapturer.swift**

```swift
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct DisplaySnapshot {
  let displayID: CGDirectDisplayID
  let image: CGImage
  let frame: CGRect   // 全局点坐标(NSScreen.frame 语义,左下原点)
  let scale: CGFloat
}

enum ScreenshotCapturer {
  /// 启动后预热,SCShareableContent 首次查询有延迟。
  static func prewarm() {
    Task.detached(priority: .utility) { _ = try? await SCShareableContent.current }
  }

  static func captureAllDisplays() async throws -> [DisplaySnapshot] {
    let content = try await SCShareableContent.current
    var result: [DisplaySnapshot] = []
    for display in content.displays {
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let config = SCStreamConfiguration()
      config.width = Int(CGFloat(display.width) * displayScale(display.displayID))
      config.height = Int(CGFloat(display.height) * displayScale(display.displayID))
      config.showsCursor = false
      let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
      result.append(DisplaySnapshot(
        displayID: display.displayID, image: image,
        frame: nsScreenFrame(for: display.displayID) ?? display.frame.toCGRect,
        scale: displayScale(display.displayID)
      ))
      ScreenshotDebugLog.log("captured display \(display.displayID) \(image.width)x\(image.height)")
    }
    return result
  }

  /// 选区(全局点坐标)→ 在该快照上裁剪出像素图。
  static func crop(_ snapshot: DisplaySnapshot, toPointRect rect: CGRect) -> CGImage? {
    // 把全局点坐标换成「相对快照左上角」的像素坐标。NSScreen 左下原点 → 图像左上原点要翻转 Y。
    let relX = rect.origin.x - snapshot.frame.origin.x
    let relTopY = (snapshot.frame.maxY - rect.maxY)   // 翻转:距顶部
    let px = CGRect(x: relX * snapshot.scale, y: relTopY * snapshot.scale,
                    width: rect.width * snapshot.scale, height: rect.height * snapshot.scale)
    return snapshot.image.cropping(to: px.integral)
  }

  private static func displayScale(_ id: CGDirectDisplayID) -> CGFloat {
    nsScreen(for: id)?.backingScaleFactor ?? 2.0
  }
  private static func nsScreen(for id: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
    }
  }
  private static func nsScreenFrame(for id: CGDirectDisplayID) -> CGRect? { nsScreen(for: id)?.frame }
}

private extension CGRect {
  var toCGRect: CGRect { self }
}
```

> 注:`SCDisplay.frame` 已是 `CGRect`;`toCGRect` 仅为兜底占位,实现时若类型已对可删。坐标翻转逻辑(NSScreen 左下原点 vs CGImage 左上原点)是本任务核心,实机验证裁剪位置是否正确。

- [ ] **Step 2: 写源码文本断言测试(不入库)**

```swift
// Tests/VeltoTests/ScreenshotCapturerTests.swift
import Foundation
import Testing

@Test func screenshotCapturerUsesScreenCaptureKit() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let src = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScreenshotCapturer.swift"), encoding: .utf8)
  #expect(src.contains("import ScreenCaptureKit"))
  #expect(src.contains("SCScreenshotManager.captureImage"))
  #expect(src.contains("func captureAllDisplays() async throws"))
  #expect(src.contains("func crop("))
  #expect(src.contains("func prewarm()"))
  #expect(!src.contains("CGWindowListCreateImage"))   // 不用弃用 API
}
```

- [ ] **Step 3: 跑测试 + 构建**

Run: `swift test --filter ScreenshotCapturer` → PASS
Run: `swift build` → 0 error

- [ ] **Step 4: 提交**

```bash
git add Sources/Velto/Screenshot/ScreenshotCapturer.swift
git commit -m "截图:ScreenCaptureKit 抓全屏快照 + 区域裁剪"
```

---

## Task 5: ScreenshotImageWriter(剪贴板 / 写 PNG)

**Files:**
- Create: `Sources/Velto/Screenshot/ScreenshotImageWriter.swift`
- Test: `Tests/VeltoTests/ScreenshotImageWriterTests.swift`(源码文本断言,不入库)

**Interfaces:**
- Consumes:`ScreenshotGeometry.suggestedFileName`、`ScreenshotImageFormat`、`ScreenshotDebugLog`
- Produces:
  - `enum ScreenshotImageWriter`:
    - `static func copyToClipboard(_ image: CGImage)`
    - `@discardableResult static func save(_ image: CGImage, toDirectory dir: String, format: ScreenshotImageFormat, alsoCopy: Bool) -> URL?`(目录不可写则回退桌面;返回最终写入 URL)

- [ ] **Step 1: 写 ScreenshotImageWriter.swift**

```swift
import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum ScreenshotImageWriter {
  static func copyToClipboard(_ image: CGImage) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setData(data, forType: .png)
    ScreenshotDebugLog.log("copied \(image.width)x\(image.height) to clipboard")
  }

  @discardableResult
  static func save(_ image: CGImage, toDirectory dir: String,
                   format: ScreenshotImageFormat, alsoCopy: Bool) -> URL? {
    let fm = FileManager.default
    var targetDir = dir
    var isDir: ObjCBool = false
    let ok = fm.fileExists(atPath: targetDir, isDirectory: &isDir) && isDir.boolValue
      && fm.isWritableFile(atPath: targetDir)
    if !ok {
      targetDir = NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first
        ?? NSHomeDirectory() + "/Desktop"
      ScreenshotDebugLog.log("save dir not writable, fallback to \(targetDir)")
    }
    let name = ScreenshotGeometry.suggestedFileName(format: format)
    let url = URL(fileURLWithPath: targetDir).appendingPathComponent(name)
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
    do {
      try data.write(to: url)
      if alsoCopy { copyToClipboard(image) }
      ScreenshotDebugLog.log("saved to \(url.path)")
      return url
    } catch {
      ScreenshotDebugLog.log("save failed: \(error.localizedDescription)")
      return nil
    }
  }
}
```

- [ ] **Step 2: 源码文本断言测试(不入库)**

```swift
// Tests/VeltoTests/ScreenshotImageWriterTests.swift
import Foundation
import Testing

@Test func screenshotImageWriterDefinesClipboardAndSave() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let src = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScreenshotImageWriter.swift"), encoding: .utf8)
  #expect(src.contains("func copyToClipboard"))
  #expect(src.contains("func save("))
  #expect(src.contains("NSPasteboard.general"))
  #expect(src.contains("isWritableFile"))         // 不可写回退
  #expect(src.contains("suggestedFileName"))
}
```

- [ ] **Step 3: 跑测试 + 构建**

Run: `swift test --filter ScreenshotImageWriter` → PASS
Run: `swift build` → 0 error

- [ ] **Step 4: 提交**

```bash
git add Sources/Velto/Screenshot/ScreenshotImageWriter.swift
git commit -m "截图:输出层(剪贴板 + 写 PNG,目录不可写回退桌面)"
```

---

## Task 6: 覆盖窗口 + 快照显示 + 暗罩(可 run 验证)

**Files:**
- Create: `Sources/Velto/Screenshot/ScreenshotOverlayWindow.swift`
- Create: `Sources/Velto/Screenshot/ScreenshotOverlayView.swift`(本任务先只画快照 + 暗罩 + Esc 取消;选区交互留 Task 7)
- Modify: `Sources/Velto/AppDelegate.swift`(临时测试菜单项,验证用,Task 10 移除)
- Test: 实机验证(无源码断言)

**Interfaces:**
- Consumes:`DisplaySnapshot`(Task 4)
- Produces:
  - `protocol ScreenshotOverlayDelegate: AnyObject { func overlayDidCancel() }`(Task 7/8 扩展更多回调)
  - `final class ScreenshotOverlayView: NSView`,属性 `snapshotImage: CGImage?`、`dimAlpha: CGFloat`,弱引用 `delegate`
  - `final class ScreenshotOverlayWindow: NSWindow`,`init(screenSnapshot: DisplaySnapshot)`,把 view 铺满;`static func present(for snapshots: [DisplaySnapshot], delegate: ScreenshotOverlayDelegate) -> [ScreenshotOverlayWindow]`;实例 `func dismiss()`

- [ ] **Step 1: 写 ScreenshotOverlayWindow.swift**

```swift
import AppKit

protocol ScreenshotOverlayDelegate: AnyObject {
  func overlayDidCancel()
}

final class ScreenshotOverlayWindow: NSWindow {
  private let overlayView: ScreenshotOverlayView

  init(screenSnapshot snap: DisplaySnapshot, delegate: ScreenshotOverlayDelegate) {
    overlayView = ScreenshotOverlayView(frame: CGRect(origin: .zero, size: snap.frame.size))
    overlayView.snapshotImage = snap.image
    overlayView.delegate = delegate
    super.init(contentRect: snap.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    level = .screenSaver            // 高于普通窗口;实机确认不挡系统授权弹窗
    ignoresMouseEvents = false
    hasShadow = false
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    contentView = overlayView
    setFrame(snap.frame, display: false)
  }

  override var canBecomeKey: Bool { true }

  func dismiss() { orderOut(nil) }

  /// 为每块屏建一个覆盖窗口并显示;第一个设为 key 以接键盘。
  static func present(for snapshots: [DisplaySnapshot], delegate: ScreenshotOverlayDelegate) -> [ScreenshotOverlayWindow] {
    let windows = snapshots.map { ScreenshotOverlayWindow(screenSnapshot: $0, delegate: delegate) }
    for w in windows { w.orderFrontRegardless() }
    windows.first?.makeKey()
    return windows
  }
}
```

- [ ] **Step 2: 写 ScreenshotOverlayView.swift(本任务:快照 + 暗罩 + Esc)**

```swift
import AppKit

final class ScreenshotOverlayView: NSView {
  weak var delegate: ScreenshotOverlayDelegate?
  var snapshotImage: CGImage? { didSet { needsDisplay = true } }
  var dimAlpha: CGFloat = 0.35

  override var acceptsFirstResponder: Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    if let img = snapshotImage { ctx.draw(img, in: bounds) }
    ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
    ctx.fill(bounds)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { delegate?.overlayDidCancel(); return }  // Esc
    super.keyDown(with: event)
  }
}
```

- [ ] **Step 3: 加临时测试菜单项(AppDelegate.swift)验证**

在 `rebuildStatusMenu()` 的「重启监听」项后插入(Task 10 删除):

```swift
menu.addItem(NSMenuItem(title: "测试截图(临时)", action: #selector(debugTestScreenshot), keyEquivalent: ""))
```

并加一个临时方法,直接抓图弹覆盖窗口(本任务先验证显示+Esc):

```swift
private var debugOverlays: [ScreenshotOverlayWindow] = []
@objc private func debugTestScreenshot() {
  Task { @MainActor in
    guard PermissionManager.isScreenRecordingTrusted else { PermissionManager.requestScreenRecordingPrompt(); return }
    guard let snaps = try? await ScreenshotCapturer.captureAllDisplays() else { return }
    debugOverlays = ScreenshotOverlayWindow.present(for: snaps, delegate: self)
  }
}
```

让 `AppDelegate` 临时符合 `ScreenshotOverlayDelegate`:

```swift
extension AppDelegate: ScreenshotOverlayDelegate {
  func overlayDidCancel() { debugOverlays.forEach { $0.dismiss() }; debugOverlays = [] }
}
```

- [ ] **Step 4: 实机验证**

Run: `./scripts/build-app.sh --run`
操作:菜单栏点「测试截图(临时)」→ 期望整屏被**冻结快照 + 半透明暗罩**盖住(多屏每屏都盖),光标为十字;按 **Esc** → 覆盖层消失。首次会弹屏幕录制授权,授权后按脚本提示重启再试。

- [ ] **Step 5: 提交(只 add Sources)**

```bash
git add Sources/Velto/Screenshot/ScreenshotOverlayWindow.swift \
        Sources/Velto/Screenshot/ScreenshotOverlayView.swift \
        Sources/Velto/AppDelegate.swift
git commit -m "截图:覆盖窗口显示冻结快照+暗罩,Esc 取消(含临时测试菜单)"
```

---

## Task 7: 覆盖层选区交互(框选 / 手柄 / 尺寸读数 / 选窗高亮 / 放大镜)

**Files:**
- Modify: `Sources/Velto/Screenshot/ScreenshotOverlayWindow.swift`(协议加回调)
- Modify: `Sources/Velto/Screenshot/ScreenshotOverlayView.swift`(鼠标交互 + 绘制)
- Modify: `Sources/Velto/AppDelegate.swift`(Task 6 的临时 `ScreenshotOverlayDelegate` 扩展补 `overlayDidRequest` stub,否则协议变更后编译不过;Task 8 整体移除)
- Test: 实机验证

**Interfaces:**
- Consumes:`ScreenshotGeometry`、`WindowFrameDetector`、`ScreenshotPreferences.showMagnifier`
- Produces(扩展协议,Task 8 用):
  - `ScreenshotOverlayDelegate` 增 `func overlayDidRequest(_ action: ScreenshotSessionAction, globalRect: CGRect)`(选区确认与动作统一走这一个回调;`overlayDidCancel()` 保留)
  - `enum ScreenshotSessionAction { case copy, save, scroll }`(定义在本任务,Task 8 复用)
  - `ScreenshotOverlayView`:`var showMagnifier: Bool`、`var globalFrame: CGRect`(本窗口屏幕全局 frame,用于点↔全局换算)、`var currentSelectionGlobal: CGRect?`(只读给外部)

- [ ] **Step 1: 协议扩展(ScreenshotOverlayWindow.swift)**

```swift
enum ScreenshotSessionAction { case copy, save, scroll }

protocol ScreenshotOverlayDelegate: AnyObject {
  func overlayDidCancel()
  func overlayDidRequest(_ action: ScreenshotSessionAction, globalRect: CGRect)
}
```

在 `init` 里把窗口全局 frame 传给 view:`overlayView.globalFrame = snap.frame`、`overlayView.scale = snap.scale`,并开启 `acceptsMouseMovedEvents = true`(否则收不到 `mouseMoved`,选窗高亮失效)。

同时**更新 Task 6 在 AppDelegate 的临时扩展**,补上新协议方法的 stub,否则协议变更后 `AppDelegate` 不再满足 `ScreenshotOverlayDelegate`、编译报错(Task 8 会把整段临时扩展删掉):

```swift
extension AppDelegate: ScreenshotOverlayDelegate {
  func overlayDidCancel() { debugOverlays.forEach { $0.dismiss() }; debugOverlays = [] }
  func overlayDidRequest(_ action: ScreenshotSessionAction, globalRect: CGRect) {
    ScreenshotDebugLog.log("temp overlay request \(action) \(globalRect)")
    debugOverlays.forEach { $0.dismiss() }; debugOverlays = []   // 临时:验证回调通路,Task 8 接真实输出
  }
}
```

- [ ] **Step 2: 选区交互与绘制(ScreenshotOverlayView.swift)**

核心新增(view 局部点 ↔ 全局点:`global = local + globalFrame.origin`,本窗口内 y 同为左下原点):

```swift
var showMagnifier: Bool = true
var globalFrame: CGRect = .zero
var scale: CGFloat = 2.0

private enum Mode { case idle, dragging, dragHandle(ScreenshotHandle), moving }
private var mode: Mode = .idle
private var selection: CGRect?          // view 局部点坐标
private var dragOrigin: CGPoint = .zero
private var hoverWindowRectLocal: CGRect?  // 选窗高亮(局部坐标)
private let handleSize: CGFloat = 8

var currentSelectionGlobal: CGRect? {
  selection.map { CGRect(x: $0.minX + globalFrame.minX, y: $0.minY + globalFrame.minY,
                         width: $0.width, height: $0.height) }
}

override func mouseDown(with e: NSEvent) {
  let p = convert(e.locationInWindow, from: nil)
  if let s = selection, let h = ScreenshotGeometry.handle(at: p, selection: s, handleSize: handleSize * 2) {
    mode = .dragHandle(h)
  } else if let s = selection, s.contains(p) {
    mode = .moving; dragOrigin = p
  } else {
    dragOrigin = p; selection = CGRect(origin: p, size: .zero); mode = .dragging
  }
  needsDisplay = true
}

override func mouseDragged(with e: NSEvent) {
  let p = convert(e.locationInWindow, from: nil)
  switch mode {
  case .dragging:
    selection = ScreenshotGeometry.clamp(ScreenshotGeometry.normalizedRect(from: dragOrigin, to: p), to: bounds)
  case .dragHandle(let h):
    if let s = selection { selection = ScreenshotGeometry.clamp(ScreenshotGeometry.resized(s, handle: h, to: p), to: bounds) }
  case .moving:
    if var s = selection {
      s.origin.x += p.x - dragOrigin.x; s.origin.y += p.y - dragOrigin.y
      selection = ScreenshotGeometry.clamp(s, to: bounds); dragOrigin = p
    }
  case .idle: break
  }
  needsDisplay = true
}

override func mouseUp(with e: NSEvent) {
  // 单击未拖(尺寸≈0)且有悬停窗口 → 采纳整窗为选区。
  if case .dragging = mode, let s = selection, s.width < 3, s.height < 3, let w = hoverWindowRectLocal {
    selection = ScreenshotGeometry.clamp(w, to: bounds)
  }
  mode = .idle
  needsDisplay = true
}

override func mouseMoved(with e: NSEvent) {
  guard selection == nil else { hoverWindowRectLocal = nil; return }
  let local = convert(e.locationInWindow, from: nil)
  let global = CGPoint(x: local.x + globalFrame.minX, y: local.y + globalFrame.minY)
  if let g = WindowFrameDetector.windowFrame(atGlobalPoint: flipToTopLeft(global),
                                             excludingPID: ProcessInfo.processInfo.processIdentifier) {
    hoverWindowRectLocal = topLeftRectToLocal(g)
  } else { hoverWindowRectLocal = nil }
  needsDisplay = true
}
```

> 坐标系细节(本任务实现重点,实机校准):NSScreen/NSView 是**左下原点**,`CGWindowListCopyWindowInfo` 是**左上原点**。`flipToTopLeft` / `topLeftRectToLocal` 这两个 helper 负责换算,基于 `globalFrame` 与主屏高度;实现时用 `DisplayCoordinateConverter`(项目已有)对齐其约定,避免重复造轮子。需开启 `window.acceptsMouseMovedEvents = true` 才能收到 `mouseMoved`(在 `ScreenshotOverlayWindow.init` 里设)。

`draw(_:)` 增量:暗罩改为**只暗选区外**(选区/悬停窗口区域亮)、画选区边框 + 八手柄、画尺寸读数 `W×H`(选区上方小标签)、`showMagnifier` 时在光标旁画放大镜(从 `snapshotImage` 取光标附近像素放大 + 十字 + 坐标/HEX)。键盘:

```swift
override func keyDown(with e: NSEvent) {
  switch e.keyCode {
  case 53: delegate?.overlayDidCancel()                                   // Esc
  case 49: confirm(.copy)                                                  // 空格=复制
  case 36: confirm(.copy)                                                  // Enter=默认动作
  case 1 where e.modifierFlags.contains(.command): confirm(.save)         // ⌘S=保存
  case 1: confirm(.scroll)                                                 // S=滚动(Task 8 占位提示)
  default: super.keyDown(with: e)
  }
}
private func confirm(_ action: ScreenshotSessionAction) {
  guard let g = currentSelectionGlobal, g.width > 1, g.height > 1 else { return }
  delegate?.overlayDidRequest(action, globalRect: g)
}
```

> 工具栏:本任务先用键盘驱动 + 选区上方的尺寸标签即可跑通验证;可视化「复制/保存/取消」按钮工具栏可在本任务一并加(选区下方浮一条),为 Phase 2 标注工具预留 dock 位。

- [ ] **Step 3: 实机验证**

Run: `./scripts/build-app.sh --run`,点「测试截图(临时)」:
- 悬停某窗口 → 该窗口高亮;**单击** → 整窗成为选区。
- 拖拽 → 实时矩形 + 尺寸读数;**八手柄**可调;选区内拖动整体移动。
- 放大镜跟随光标显示像素 + 坐标/HEX。
- 控制台/日志能看到 `overlayDidRequest copy/save/scroll`(Task 8 才真正输出)。

- [ ] **Step 4: 提交**

```bash
git add Sources/Velto/Screenshot/ScreenshotOverlayWindow.swift \
        Sources/Velto/Screenshot/ScreenshotOverlayView.swift \
        Sources/Velto/AppDelegate.swift
git commit -m "截图:选区交互(框选/手柄/移动/选窗高亮/尺寸读数/放大镜)"
```

---

## Task 8: ScreenshotSession + ScreenshotController(状态机编排,跑通复制/存盘)

**Files:**
- Create: `Sources/Velto/Screenshot/ScreenshotSession.swift`
- Create: `Sources/Velto/Screenshot/ScreenshotController.swift`
- Modify: `Sources/Velto/AppDelegate.swift`(临时菜单项改为调 `ScreenshotController.shared.beginSession()`;移除 Task 6 的 debug 抓图代码)
- Test: 实机验证

**Interfaces:**
- Consumes:`ScreenshotCapturer`、`ScreenshotOverlayWindow`、`ScreenshotImageWriter`、`GestureStore.shared.preferences.screenshot`
- Produces:
  - `@MainActor final class ScreenshotController`,`static let shared`,`func beginSession()`(幂等:已有会话则忽略)、`func cancelSession()`
  - `@MainActor final class ScreenshotSession: ScreenshotOverlayDelegate`,`init(snapshots:preferences:onFinish:)`、`func start()`;实现三个 delegate 回调

- [ ] **Step 1: 写 ScreenshotSession.swift**

```swift
import AppKit

@MainActor
final class ScreenshotSession: ScreenshotOverlayDelegate {
  private let snapshots: [DisplaySnapshot]
  private let preferences: ScreenshotPreferences
  private let onFinish: () -> Void
  private var windows: [ScreenshotOverlayWindow] = []

  init(snapshots: [DisplaySnapshot], preferences: ScreenshotPreferences, onFinish: @escaping () -> Void) {
    self.snapshots = snapshots
    self.preferences = preferences
    self.onFinish = onFinish
  }

  func start() {
    windows = ScreenshotOverlayWindow.present(for: snapshots, delegate: self)
  }

  func overlayDidCancel() { teardown() }

  func overlayDidRequest(_ action: ScreenshotSessionAction, globalRect: CGRect) {
    switch action {
    case .scroll:
      // Phase 3 占位:本期不实现滚动拼接,轻提示后留在会话。
      ScreenshotDebugLog.log("scroll capture not implemented yet")
      NSSound.beep()
      return
    case .copy, .save:
      guard let snap = snapshots.first(where: { $0.frame.intersects(globalRect) }),
            let image = ScreenshotCapturer.crop(snap, toPointRect: globalRect) else { teardown(); return }
      if action == .copy {
        ScreenshotImageWriter.copyToClipboard(image)
      } else {
        ScreenshotImageWriter.save(image, toDirectory: preferences.saveDirectoryPath,
                                   format: preferences.imageFormat,
                                   alsoCopy: preferences.saveAlsoCopiesToClipboard)
      }
      teardown()
    }
  }

  private func teardown() {
    windows.forEach { $0.dismiss() }
    windows = []
    onFinish()
  }
}
```

- [ ] **Step 2: 写 ScreenshotController.swift**

```swift
import AppKit

@MainActor
final class ScreenshotController {
  static let shared = ScreenshotController()
  private var session: ScreenshotSession?
  private init() {}

  /// 全局触发键命中后切到主线程调用。已有会话或权限缺失则忽略/引导。
  func beginSession() {
    guard session == nil else { return }
    guard GestureStore.shared.preferences.screenshot.enabled else { return }
    guard PermissionManager.isScreenRecordingTrusted else {
      PermissionManager.requestScreenRecordingPrompt()
      return
    }
    let prefs = GestureStore.shared.preferences.screenshot
    Task { @MainActor in
      guard let snaps = try? await ScreenshotCapturer.captureAllDisplays(), !snaps.isEmpty else { return }
      let s = ScreenshotSession(snapshots: snaps, preferences: prefs) { [weak self] in self?.session = nil }
      self.session = s
      s.start()
    }
  }

  func cancelSession() { session = nil }
}
```

- [ ] **Step 3: 临时菜单项改接 controller(AppDelegate.swift)**

把 Task 6 的 `debugTestScreenshot` 体改为:

```swift
@objc private func debugTestScreenshot() { ScreenshotController.shared.beginSession() }
```

删除 Task 6 临时的 `debugOverlays` 属性、`captureAllDisplays` 调用、`ScreenshotOverlayDelegate` 扩展(改由 `ScreenshotSession` 实现)。临时菜单项标题保留到 Task 10。

- [ ] **Step 4: 实机验证(端到端闭环)**

Run: `./scripts/build-app.sh --run`,「测试截图(临时)」:
- 框选/选窗 → **空格** → 去任意输入框 ⌘V,粘出截图。
- 框选 → **⌘S** → 桌面出现 `Velto-YYYY-MM-DD-HHmmss.png`,打开清晰(Retina 正确)。
- **S** → 蜂鸣(滚动占位)。**Esc** → 取消无输出。
- 多屏:在副屏框选,裁剪位置/清晰度正确(验证坐标翻转与 scale)。

- [ ] **Step 5: 提交**

```bash
git add Sources/Velto/Screenshot/ScreenshotSession.swift \
        Sources/Velto/Screenshot/ScreenshotController.swift \
        Sources/Velto/AppDelegate.swift
git commit -m "截图:会话状态机 + 控制器,跑通框选→复制/存盘闭环"
```

---

## Task 9: 全局触发键(ScreenshotShortcutController + EventTapManager + AppDelegate)

**Files:**
- Create: `Sources/Velto/Screenshot/ScreenshotShortcutController.swift`
- Modify: `Sources/Velto/EventTapManager.swift`(持有 controller、`.keyDown` 分发、`applyPreferenceSnapshots` 推触发键)
- Modify: `Sources/Velto/AppDelegate.swift`(`applicationDidFinishLaunching` 预热 SCK)
- Test: `Tests/VeltoTests/ScreenshotShortcutTests.swift`(源码文本断言,不入库)+ 实机验证

**Interfaces:**
- Consumes:`Shortcut`、`ScreenshotController.shared.beginSession()`
- Produces:`final class ScreenshotShortcutController: @unchecked Sendable`,`func updateShortcut(_:)`、`func handleKeyDown(event:normalizedFlags:) -> Bool`(模式同 `WindowShortcutController`)

- [ ] **Step 1: 写 ScreenshotShortcutController.swift**

```swift
import CoreGraphics
import Foundation

/// tap 线程匹配截图全局触发键。匹配后切主线程启动会话,返回 true 吞掉事件。
final class ScreenshotShortcutController: @unchecked Sendable {
  private let lock = NSLock()
  private var triggerShortcut: Shortcut?

  func updateShortcut(_ shortcut: Shortcut?) {
    lock.lock(); triggerShortcut = shortcut; lock.unlock()
  }

  func handleKeyDown(event: CGEvent, normalizedFlags raw: UInt64) -> Bool {
    lock.lock(); let shortcut = triggerShortcut; lock.unlock()
    guard let shortcut else { return false }
    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    guard keyCode == shortcut.keyCode, raw == shortcut.modifierFlags else { return false }
    DispatchQueue.main.async { ScreenshotController.shared.beginSession() }
    return true
  }
}
```

- [ ] **Step 2: 接入 EventTapManager.swift**

1. 属性区(`windowShortcutController` 旁,`EventTapManager.swift:146`)加:
   ```swift
   private let screenshotShortcutController = ScreenshotShortcutController()
   ```
2. `.keyDown` 分发:在 `betterFinderShortcutController.handleKeyDown`(`:589`)那段**之后**、窗口管理总开关 `guard` 之前,插入(截图不受窗口管理开关门控):
   ```swift
   if screenshotShortcutController.handleKeyDown(event: event, normalizedFlags: raw) {
     return nil
   }
   ```
3. `applyPreferenceSnapshots`(`:750`)末尾加:
   ```swift
   screenshotShortcutController.updateShortcut(preferences.screenshot.triggerShortcut)
   ```

- [ ] **Step 3: AppDelegate 预热 SCK**

在 `applicationDidFinishLaunching`(InputSourceSwitchController 启动那行附近)加:

```swift
ScreenshotCapturer.prewarm()
```

- [ ] **Step 4: 源码文本断言测试(不入库)**

```swift
// Tests/VeltoTests/ScreenshotShortcutTests.swift
import Foundation
import Testing

@Test func screenshotShortcutWiredIntoEventTap() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let tap = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/EventTapManager.swift"), encoding: .utf8)
  #expect(tap.contains("screenshotShortcutController"))
  #expect(tap.contains("screenshotShortcutController.handleKeyDown"))
  #expect(tap.contains("updateShortcut(preferences.screenshot.triggerShortcut)"))
  let ctrl = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScreenshotShortcutController.swift"), encoding: .utf8)
  #expect(ctrl.contains("ScreenshotController.shared.beginSession()"))
}
```

- [ ] **Step 5: 测试 + 实机验证**

Run: `swift test --filter ScreenshotShortcut` → PASS
Run: `swift build` → 0 error
> 触发键默认 nil,实机要先临时硬编一个测试值验证:可在 `applyPreferenceSnapshots` 临时传 `Shortcut(keyCode: 0, modifierFlags: ⌘⌥, "⌘⌥A")` 跑一次确认按下能唤起会话,验证后还原(正式入口是 Task 10 的设置页录制)。或直接等 Task 10 设好快捷键再端到端验证。

- [ ] **Step 6: 提交**

```bash
git add Sources/Velto/Screenshot/ScreenshotShortcutController.swift \
        Sources/Velto/EventTapManager.swift Sources/Velto/AppDelegate.swift
git commit -m "截图:全局触发键接入 EventTapManager + 启动预热 SCK"
```

---

## Task 10: 设置页 + 侧栏接入 + 移除临时菜单项

**Files:**
- Create: `Sources/Velto/Screenshot/ScreenshotPage.swift`
- Modify: `Sources/Velto/SettingsRootView.swift`(`MGPage` 加 `.screenshot` + `label`/`icon` + Host `cachedController` 分支)
- Modify: `Sources/Velto/SidebarView.swift`(「功能」组加项)
- Modify: `Sources/Velto/AppDelegate.swift`(移除 Task 6/8 的临时测试菜单项与 `debugTestScreenshot`)
- Test: `Tests/VeltoTests/ScreenshotPageRoutingTests.swift`(源码文本断言,不入库)+ 实机验证

**Interfaces:**
- Consumes:`GestureStore.shared`(读写 `preferences.screenshot`)、项目现有快捷键录制控件、Liquid Glass 视觉组件
- Produces:`ScreenshotPage: View`(或 `NSViewController` 包装,与其他 Page 一致);`MGPage.screenshot`

- [ ] **Step 1: MGPage 接入(SettingsRootView.swift)**

```swift
// case 列表加 screenshot
case gestures, mouseControl, window, trackpadGesture, switcher, inputSourceSwitch, keyRemap, betterFinder, screenshot, general
// label:
case .screenshot: "截图"
// icon:
case .screenshot: "camera.viewfinder"
```

`SettingsPageHostController.cachedController(for:)` 加分支,返回包 `ScreenshotPage` 的 controller(照其他 page 的包装方式)。

- [ ] **Step 2: 侧栏加项(SidebarView.swift)**

在 `.betterFinder` 项后、`SidebarGroup("功能")` 内加:

```swift
SidebarItem(
  icon: MGPage.screenshot.icon, label: MGPage.screenshot.label,
  badge: nil, active: page == .screenshot
) { page = .screenshot }
```

- [ ] **Step 3: 写 ScreenshotPage.swift**

延续现有 Page 视觉(读 `GeneralSettingsPage` / `WindowManagementPage` 取一个最接近的当模板)。包含:
- 顶部:功能总开关 `enabled` + 屏幕录制权限状态行(未授权显式按钮引导 `PermissionManager.requestScreenRecordingPrompt` / `openPrivacySettings`)。
- 全局触发键:用项目现成的快捷键录制控件绑定 `screenshot.triggerShortcut`(校验 `hasRealModifier`,不满足给红字提示)。
- 会话内按键:复制 / 保存(⌘S)/ 取消 三行录制;**滚动键行灰显**并标「即将支持(Phase 3)」。
- 保存目录:`NSOpenPanel` 选目录写 `saveDirectoryPath`,旁显当前路径;开关 `saveAlsoCopiesToClipboard`。
- 开关 `showMagnifier`。

所有写入走 `GestureStore.shared.updatePreferences { $0.screenshot.xxx = ... }`(与其他 page 一致,触发 `.gestureStoreDidChange` → `EventTapManager` 重推触发键快照)。

> 该 Page 是纯 UI 装配,无需源码逐行列出;实现时对照一个现有 Page 的结构与 `GestureStore.updatePreferences` 用法照搬。

- [ ] **Step 4: 移除临时测试菜单项(AppDelegate.swift)**

删掉 `rebuildStatusMenu()` 里「测试截图(临时)」`NSMenuItem` 与 `@objc func debugTestScreenshot()`。正式入口为全局触发键。

- [ ] **Step 5: 源码文本断言测试(不入库)**

```swift
// Tests/VeltoTests/ScreenshotPageRoutingTests.swift
import Foundation
import Testing

@Test func screenshotPageRoutedAndTempMenuRemoved() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let routing = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/SettingsRootView.swift"), encoding: .utf8)
  #expect(routing.contains("case .screenshot"))
  #expect(routing.contains("\"截图\""))
  let sidebar = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/SidebarView.swift"), encoding: .utf8)
  #expect(sidebar.contains("MGPage.screenshot"))
  let appDelegate = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/AppDelegate.swift"), encoding: .utf8)
  #expect(!appDelegate.contains("测试截图(临时)"))     // 临时项已移除
  #expect(!appDelegate.contains("debugTestScreenshot"))
}
```

- [ ] **Step 6: 测试 + 实机端到端验证**

Run: `swift test --filter ScreenshotPageRouting` → PASS
Run: `./scripts/build-app.sh --run`
- 设置窗口侧栏出现「截图」页;录一个含 ⌘/⌥ 的触发键并保存。
- 全屏任意位置按该触发键 → 进入冻结快照框选;空格复制、⌘S 存盘、Esc 取消全部正常。
- 重开 app 确认配置持久化(触发键、保存目录还在)。

- [ ] **Step 7: 提交**

```bash
git add Sources/Velto/Screenshot/ScreenshotPage.swift \
        Sources/Velto/SettingsRootView.swift Sources/Velto/SidebarView.swift \
        Sources/Velto/AppDelegate.swift
git commit -m "截图:设置页 + 侧栏接入,移除临时测试菜单,核心捕获完成"
```

---

## 验收(整阶段)

核心捕获阶段完成的标志:
1. 设置页可配:总开关、全局触发键(强制真修饰键)、会话内复制/保存/取消键、保存目录、放大镜开关;滚动键灰显占位。
2. 全局触发键唤起 → 冻结全屏快照 → 框选 or 单击选窗(窗口高亮)→ 空格存剪贴板 / ⌘S 静默存预设目录(自动命名 PNG)/ Esc 取消;S 蜂鸣占位。
3. 取色放大镜默认开、像素+坐标+HEX。
4. 多屏正确(裁剪位置、Retina 清晰度)。
5. 屏幕录制权限缺失时引导,不崩。
6. 配置随 `AppPreferences` 持久化与导入导出。
7. 临时测试菜单项已移除。
8. 状态机/工具栏为 Phase 2(标注)与 Phase 3(滚动)预留了接入点(`ScreenshotSessionAction.scroll`、工具栏 dock 位、Selected 决策态)。

## 下一阶段(不在本计划)

- **Phase 2 标注编辑器**:Selected 态进标注层(箭头/矩形/椭圆/文字/画笔/马赛克/高亮/序号/裁剪),工具栏 dock 位已留。
- **Phase 3 滚动长截图**:`scroll` action 现为占位,后续实现自动滚动 + 逐帧拼接。
