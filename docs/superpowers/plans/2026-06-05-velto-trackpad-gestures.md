# Velto 触控板双指手势 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在触控板上,当光标压在某窗口标题栏时,双指上滑=最大化、下滑=最小化、左滑=关闭该窗口。

**Architecture:** 复用 `EventTapManager.handleAnnotatedScroll` 的 scroll tap 拦截双指滑动,新增 `TrackpadGestureController` 按 scroll phase 管理一次手势,仅在「无修饰键 + 触控板连续滚动 + 光标压标题栏」时接管并消费整段事件。AX 查询/写入集中在 `GestureTargetController`,实际窗口动作派发到后台队列,避免阻塞 tap 线程。

**Tech Stack:** Swift 6.2 / macOS 26 / AppKit / SwiftUI / CoreGraphics CGEventTap / ApplicationServices AXUIElement / SwiftPM。

---

## Files

- Create: `Sources/Velto/TrackpadGesture/TrackpadGestureController.swift`
- Create: `Sources/Velto/TrackpadGesture/TrackpadGesturePage.swift`
- Create: `Sources/Velto/TrackpadGesture/TrackpadGestureDebugLog.swift`
- Create: `Tests/VeltoTests/TrackpadGestureControllerTests.swift`
- Modify: `Package.swift`
- Modify: `Sources/Velto/Models.swift`
- Modify: `Sources/Velto/GestureTargetController.swift`
- Modify: `Sources/Velto/EventTapManager.swift`
- Modify: `Sources/Velto/SettingsRootView.swift`
- Modify: `Sources/Velto/SidebarView.swift`

## Task 0: 分支和基线

- [ ] **Step 1: 确认当前分支与工作区**

Run: `git status --short && git branch --show-current`
Expected: 看清当前脏文件;不要还原无关删除 `docs/superpowers/plans/2026-06-04-input-source-switch.md`。

- [ ] **Step 2: 若当前在 main/master,切功能分支**

Run: `git switch -c codex/trackpad-gestures`
Expected: `Switched to a new branch 'codex/trackpad-gestures'`

- [ ] **Step 3: 基线构建**

Run: `swift build`
Expected: `Build complete!`

## Task 1: 测试骨架与方向判定 RED

- [ ] **Step 1: 给 Package 增加测试 target**

在 `Package.swift` 的 `targets` 数组中,在 executable target 后追加:

```swift
        ,
        .testTarget(
            name: "VeltoTests",
            dependencies: ["Velto"],
            path: "Tests/VeltoTests"
        )
```

- [ ] **Step 2: 写失败测试**

Create `Tests/VeltoTests/TrackpadGestureControllerTests.swift`:

```swift
import XCTest
@testable import Velto

final class TrackpadGestureControllerTests: XCTestCase {
    func testClassifyIgnoresSmallMovement() {
        XCTAssertNil(TrackpadGestureController.classify(dx: 3, dy: -4, threshold: 35))
    }

    func testClassifyMapsVerticalMovementToMaximizeAndMinimize() {
        XCTAssertEqual(TrackpadGestureController.classify(dx: 4, dy: -40, threshold: 35), .maximize)
        XCTAssertEqual(TrackpadGestureController.classify(dx: 4, dy: 40, threshold: 35), .minimize)
    }

    func testClassifyMapsLeftMovementToCloseAndRightToNoAction() {
        XCTAssertEqual(TrackpadGestureController.classify(dx: -40, dy: 5, threshold: 35), .close)
        XCTAssertNil(TrackpadGestureController.classify(dx: 40, dy: 5, threshold: 35))
    }
}
```

- [ ] **Step 3: 跑 RED**

Run: `swift test --filter TrackpadGestureControllerTests`
Expected: FAIL,因为 `TrackpadGestureController` 尚不存在或未暴露 `classify`。

## Task 2: 偏好字段与调试日志同步

- [ ] **Step 1: 修改 `AppPreferences`**

在 `windowManagementEnabled` 后新增:

```swift
    var trackpadGesturesEnabled: Bool = false
    var trackpadGestureDebugLoggingEnabled: Bool = false
```

在 `init(from:)` 中 `windowManagementEnabled` 解码后新增:

```swift
        trackpadGesturesEnabled = try container.decodeIfPresent(Bool.self, forKey: .trackpadGesturesEnabled) ?? Self.defaults.trackpadGesturesEnabled
        trackpadGestureDebugLoggingEnabled = try container.decodeIfPresent(Bool.self, forKey: .trackpadGestureDebugLoggingEnabled) ?? Self.defaults.trackpadGestureDebugLoggingEnabled
```

- [ ] **Step 2: 新增调试日志**

Create `Sources/Velto/TrackpadGesture/TrackpadGestureDebugLog.swift`:

```swift
import Foundation

enum TrackpadGestureDebugLog {
    private static let stateQueue = DispatchQueue(label: "com.velto.trackpad.debuglog.state")
    private static let envForced = ProcessInfo.processInfo.environment["VELTO_TRACKPAD_DEBUG"] == "1"
    private nonisolated(unsafe) static var _enabled = ProcessInfo.processInfo.environment["VELTO_TRACKPAD_DEBUG"] == "1"
    private nonisolated(unsafe) static var _handle: FileHandle?
    private nonisolated(unsafe) static var _handleOpened = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var isEnabled: Bool {
        stateQueue.sync { _enabled }
    }

    static func setEnabled(_ enabled: Bool) {
        stateQueue.sync { _enabled = enabled || envForced }
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "[\(dateFormatter.string(from: Date()))] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let handle = fileHandle(), let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private static func fileHandle() -> FileHandle? {
        stateQueue.sync {
            if !_handleOpened {
                _handleOpened = true
                _handle = openLogFile()
            }
            return _handle
        }
    }

    private static func openLogFile() -> FileHandle? {
        let fm = FileManager.default
        guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Velto", isDirectory: true)
        else { return nil }
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = logsDir.appendingPathComponent("trackpad-gesture-debug.log")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        let banner = "\n=== Velto trackpad gesture debug log started \(dateFormatter.string(from: Date())) ===\n"
        if let data = banner.data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
        return handle
    }
}
```

在 `GestureStore.syncDebugLog()` 中新增:

```swift
        TrackpadGestureDebugLog.setEnabled(preferences.trackpadGestureDebugLoggingEnabled)
```

## Task 3: AX 窗口动作与标题栏命中

- [ ] **Step 1: 新增已知窗口动作**

在 `GestureTargetController.maximizeWindowUnderPointer(at:)` 后新增 `maximizeWindow(_:containingEventLocation:)`、`minimizeWindow(_:)`、`closeWindow(_:)`,分别复用 `setFrame`、`kAXMinimizedAttribute/kAXMinimizeButtonAttribute`、`kAXCloseButtonAttribute`。

- [ ] **Step 2: 新增标题栏命中**

新增:

```swift
    static func titleBarWindow(at point: CGPoint, titleBarHeight: CGFloat = 28) -> AXUIElement? {
        guard let window = windowUnderPointer(at: point),
              let frame = frame(ofWindow: window) else {
            return nil
        }
        let candidates = [point, DisplayCoordinateConverter.eventLocationToAccessibilityPoint(point)]
        for p in candidates where frame.contains(p) {
            if p.y - frame.minY <= titleBarHeight {
                return window
            }
        }
        return nil
    }
```

- [ ] **Step 3: 收紧 AX 查询超时**

把 `axMessagingTimeout` 从 `0.25` 改为 `0.10`。

## Task 4: 手势状态机 GREEN

- [ ] **Step 1: 创建 `TrackpadGestureController`**

实现 scroll phase 状态机: began 做开关/连续滚动/标题栏门控,changed 累计 `scrollWheelEventPointDeltaAxis1/2`,ended 通过 `classify(dx:dy:threshold:)` 派发最大化/最小化/关闭,动量阶段只消费不二次触发。

- [ ] **Step 2: 跑 GREEN**

Run: `swift test --filter TrackpadGestureControllerTests`
Expected: PASS。

## Task 5: 接入 scroll tap

- [ ] **Step 1: 修改 `EventTapManager`**

新增 `private let trackpadGestureController = TrackpadGestureController()`。

在 `applyPreferenceSnapshots(_:)` 同步:

```swift
        trackpadGestureController.setEnabled(preferences.trackpadGesturesEnabled)
```

在 `handleAnnotatedScroll` 中内容缩放之后、平滑滚动之前新增:

```swift
        if raw == 0, trackpadGestureController.handleScrollWheel(event: event) {
            return nil
        }
```

## Task 6: 设置页与侧栏入口

- [ ] **Step 1: 创建 `TrackpadGesturePage`**

新增「启用触控板手势」开关、三个手势说明、调试日志开关;Toggle 直接写 `GestureStore.updatePreferences`。

- [ ] **Step 2: 接入 `MGPage` 和侧栏**

`SettingsRootView.MGPage` 增加 `trackpadGesture`,label 为 `触控板手势`,icon 为 `hand.draw`;`content` 增加 `TrackpadGesturePage()`;`SidebarView` 在「窗口管理」后增加入口。

## Task 7: 集成验证、打包部署、启动新版

- [ ] **Step 1: 自动验证**

Run: `swift test --filter TrackpadGestureControllerTests && swift build`
Expected: 测试与编译均通过。

- [ ] **Step 2: 打包、kill 老进程、覆盖 app 并启动**

Run: `./scripts/build-app.sh --run`
Expected: 新包覆盖 `/Applications/Velto.app` 并启动新版。

- [ ] **Step 3: 真机手势验证**

在设置页打开「触控板手势」和「调试日志」,用 Finder 窗口标题栏实测:上滑最大化、下滑最小化、左滑关闭;正文区域滚动不触发手势。

Run:

```bash
tail -f ~/Library/Logs/Velto/trackpad-gesture-debug.log
```

Expected: 日志能看到 began/ended/dx/dy/action。若方向符号反了,只调整 `classify` 的 dx/dy 符号判断,再重跑 Step 1/2。

## Self-Review

- Spec 覆盖:目标窗口、标题栏门控、上/下/左方向、scroll tap 复用、phase 状态机、调试日志、设置页、非标题栏零干扰、真机标定均有任务。
- 占位符扫描:无 TBD/TODO;实现细节在任务里给出具体文件和命令。
- 类型一致性:`trackpadGesturesEnabled`、`trackpadGestureDebugLoggingEnabled`、`TrackpadGestureController.classify`、`GestureTargetController.titleBarWindow`、`TrackpadGesturePage` 命名一致。
