# 滚动长截图(Scroll Capture)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户手动滚动目标 App,Velto 实时抓取选区帧、按帧间重叠自动拼成一张长图,完成后直接复制或保存。

**Architecture:** 纯逻辑的帧间重叠检测(`ScrollOverlapDetector`,VeltoAnnotationCore)+ AppKit 侧拼接器(`ScrollStitcher`)+ 选区实时捕获(`ScreenshotCapturer.captureRegion`)+ 浮窗 HUD(`ScrollCaptureHUD`)+ 会话编排(`ScreenshotSession` 扩展 scroll 模式)。捕获用 ScreenCaptureKit 定时抓取(M1),overlay 进入 scroll 模式后透明透传,露出真实 App 供滚动。

**Tech Stack:** Swift 6.2、macOS 26、AppKit、Core Graphics、ScreenCaptureKit、Swift Testing。

## Global Constraints

- 缩进 2 空格;注释与面向用户文案用中文。
- `Tests/` 下文件**照写照跑但绝不 git add**;每个 commit 只暂存 `Sources/` 与 `docs/`。
- 按用户要求**只在 `main` 分支工作**,不开 feature 分支 / worktree。
- 每个任务跑 `swift test`(纯逻辑)或 `swift build`(AppKit 源串);最终任务跑 `./scripts/build-app.sh --run` 实测一次长截图。
- 源串测试取仓库根:`URL(fileURLWithPath: #filePath).deletingLastPathComponent()` ×3。
- 复用既有:`ScreenshotImageWriter.copyToClipboard(_)->Result<Void,ScreenshotWriteError>`、`ScreenshotImageWriter.save(_,toDirectory:,format:,alsoCopy:)->Result<URL,ScreenshotWriteError>`、`ScreenshotDebugLog.log(_)`、`ScreenshotPreferences`(`scrollKeyCode/copyKeyCode/cancelKeyCode/saveShortcut/saveDirectoryPath/imageFormat/saveAlsoCopiesToClipboard`)。
- 坐标:`DisplaySnapshot.frame` 为 NSScreen 左下原点全局点;CGImage/sourceRect 为左上原点。

---

### Task 1: ScrollOverlapDetector(纯逻辑,帧间重叠检测)

**Files:**
- Create: `Sources/VeltoAnnotationCore/ScrollOverlapDetector.swift`
- Test: `Tests/VeltoTests/ScrollOverlapDetectorTests.swift`

**Interfaces:**
- Produces: `ScrollOverlapDetector.appendableRowCount(canvasTail: [UInt64], frame: [UInt64], maxMismatchFraction: Double = 0.1, minOverlapRows: Int = 8) -> Int?`

- [ ] **Step 1: 写失败测试**

`Tests/VeltoTests/ScrollOverlapDetectorTests.swift`:

```swift
import Testing
@testable import VeltoAnnotationCore

@Test func scrollOverlapFirstFrameReturnsFullHeight() {
  let frame = (0..<100).map { UInt64($0) }
  #expect(ScrollOverlapDetector.appendableRowCount(canvasTail: [], frame: frame) == 100)
}

@Test func scrollOverlapNoScrollReturnsZero() {
  let rows = (0..<100).map { UInt64($0) }
  #expect(ScrollOverlapDetector.appendableRowCount(canvasTail: rows, frame: rows) == 0)
}

@Test func scrollOverlapScrolledDownReturnsNewRowCount() {
  // 画布尾 = 文档行 1...100;新帧 = 文档行 31...130,重叠 70、新增 30。
  let canvasTail = (1...100).map { UInt64($0) }
  let frame = (31...130).map { UInt64($0) }
  #expect(ScrollOverlapDetector.appendableRowCount(canvasTail: canvasTail, frame: frame) == 30)
}

@Test func scrollOverlapTooFastReturnsNil() {
  // 仅 6 行重叠,低于最小可信重叠(maxOverlap/5=20)→ nil。
  let canvasTail = (1...100).map { UInt64($0) }
  let frame = (95...194).map { UInt64($0) }
  #expect(ScrollOverlapDetector.appendableRowCount(canvasTail: canvasTail, frame: frame) == nil)
}

@Test func scrollOverlapToleratesFewMismatchedRows() {
  // 重叠 70 行内 3 行被改(模拟光标闪烁),容差 0.1 → 仍对齐、新增 30。
  let canvasTail = (1...100).map { UInt64($0) }
  var frame = (31...130).map { UInt64($0) }
  frame[5] = 9999; frame[20] = 9999; frame[40] = 9999
  #expect(ScrollOverlapDetector.appendableRowCount(canvasTail: canvasTail, frame: frame) == 30)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ScrollOverlap 2>&1 | tail -20`
Expected: 编译失败(`ScrollOverlapDetector` 未定义)。

- [ ] **Step 3: 写最小实现**

`Sources/VeltoAnnotationCore/ScrollOverlapDetector.swift`:

```swift
import Foundation

/// 竖直向下滚动的帧间重叠检测(纯逻辑,逐行 UInt64 指纹,不依赖 AppKit/CGImage)。
public enum ScrollOverlapDetector {
  /// 在 `canvasTail`(已拼画布底部若干行,自顶向下)里找与 `frame`(新帧逐行,自顶向下)顶部
  /// 对齐的最长重叠,返回应追加到画布底部的新行数 = `frame.count - overlap`。
  ///
  /// - canvasTail 为空(首帧)→ frame.count;frame 为空 → 0;完全重叠(没滚)→ 0;
  ///   找不到 ≥ 最小可信重叠的对齐(滚太快/跳变/向上滚)→ nil。
  /// - maxMismatchFraction:重叠区内允许不匹配的行占比(抗光标闪烁等少量动态行)。
  /// - minOverlapRows:可信重叠的行数下限(防重复/空白行造成的假匹配)。
  public static func appendableRowCount(
    canvasTail: [UInt64],
    frame: [UInt64],
    maxMismatchFraction: Double = 0.1,
    minOverlapRows: Int = 8
  ) -> Int? {
    if canvasTail.isEmpty { return frame.count }
    if frame.isEmpty { return 0 }
    let maxOverlap = min(canvasTail.count, frame.count)
    let minOverlap = max(minOverlapRows, maxOverlap / 5)
    if maxOverlap < minOverlap { return nil }
    var overlap = maxOverlap
    while overlap >= minOverlap {
      let allowed = Int(Double(overlap) * maxMismatchFraction)
      let base = canvasTail.count - overlap
      var mismatches = 0
      var matched = true
      var i = 0
      while i < overlap {
        if canvasTail[base + i] != frame[i] {
          mismatches += 1
          if mismatches > allowed { matched = false; break }
        }
        i += 1
      }
      if matched { return frame.count - overlap }
      overlap -= 1
    }
    return nil
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter ScrollOverlap 2>&1 | tail -10`
Expected: 5 个测试全 PASS。

- [ ] **Step 5: 提交(只暂存 Sources)**

```bash
git add Sources/VeltoAnnotationCore/ScrollOverlapDetector.swift
git commit -m "滚动截图:帧间重叠检测 ScrollOverlapDetector(纯逻辑)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: ScreenshotCapturer.captureRegion(选区实时捕获)

**Files:**
- Modify: `Sources/Velto/Screenshot/ScreenshotCapturer.swift`(在 `crop(_:toPointRect:)` 之后加方法)
- Test: `Tests/VeltoTests/ScreenshotCapturerTests.swift`(已存在,追加一个源串断言)

**Interfaces:**
- Consumes: `DisplaySnapshot { displayID, image, frame, scale }`(已存在)
- Produces: `static func captureRegion(in snapshot: DisplaySnapshot, globalRect: CGRect) async throws -> CGImage?`

- [ ] **Step 1: 写失败测试(源串,追加到现有文件末尾)**

`Tests/VeltoTests/ScreenshotCapturerTests.swift` 追加:

```swift
@Test func screenshotCapturerExposesRegionCapture() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let src = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScreenshotCapturer.swift"), encoding: .utf8)
  #expect(src.contains("func captureRegion(in snapshot: DisplaySnapshot"))
  #expect(src.contains("config.sourceRect"))
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter screenshotCapturerExposesRegionCapture 2>&1 | tail -10`
Expected: FAIL(断言失败,源里还没有 `captureRegion`)。

- [ ] **Step 3: 写实现(在 `crop(...)` 方法之后插入)**

`Sources/Velto/Screenshot/ScreenshotCapturer.swift`,加方法:

```swift
  /// 抓取选区那块的当前像素图(滚动捕获用,实时反映屏上内容)。
  /// globalRect 为全局点坐标(NSScreen 左下原点);snapshot 提供所在屏 displayID/frame/scale。
  static func captureRegion(in snapshot: DisplaySnapshot, globalRect: CGRect) async throws -> CGImage? {
    let content = try await SCShareableContent.current
    guard let display = content.displays.first(where: { $0.displayID == snapshot.displayID }) else {
      return nil
    }
    // 全局点(左下原点) → 显示局部点(左上原点),作为 sourceRect。
    let localX = globalRect.minX - snapshot.frame.minX
    let localTopY = snapshot.frame.maxY - globalRect.maxY
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.showsCursor = false
    config.sourceRect = CGRect(x: localX, y: localTopY, width: globalRect.width, height: globalRect.height)
    config.width = Int(globalRect.width * snapshot.scale)
    config.height = Int(globalRect.height * snapshot.scale)
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
  }
```

- [ ] **Step 4: 跑测试 + 编译确认通过**

Run: `swift test --filter screenshotCapturerExposesRegionCapture 2>&1 | tail -10 && swift build 2>&1 | tail -3`
Expected: 测试 PASS;`Build complete!`。

- [ ] **Step 5: 提交**

```bash
git add Sources/Velto/Screenshot/ScreenshotCapturer.swift
git commit -m "滚动截图:ScreenshotCapturer.captureRegion 选区实时捕获

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: ScrollStitcher(帧→指纹、拼接、产出长图)

**Files:**
- Create: `Sources/Velto/Screenshot/ScrollStitcher.swift`
- Test: `Tests/VeltoTests/ScrollStitcherTests.swift`

**Interfaces:**
- Consumes: `ScrollOverlapDetector.appendableRowCount(canvasTail:frame:)`(Task 1)
- Produces:
  - `ScrollStitcher.init(maxPixelHeight: Int = 30000)`
  - `func append(frame: CGImage) -> ScrollStitcher.Outcome`
  - `func finalize() -> CGImage?`
  - `func thumbnail(maxHeight: Int) -> CGImage?`
  - `var pixelHeight: Int`(get)
  - `enum Outcome { case first(rows: Int); case grew(rows: Int); case unchanged; case skippedNoOverlap; case reachedLimit }`
  - `static func rowFingerprints(of image: CGImage, samples: Int) -> [UInt64]`

- [ ] **Step 1: 写失败测试(源串)**

`Tests/VeltoTests/ScrollStitcherTests.swift`:

```swift
import Foundation
import Testing

@Test func scrollStitcherUsesDetectorAndBuildsImage() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let src = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScrollStitcher.swift"), encoding: .utf8)
  #expect(src.contains("ScrollOverlapDetector.appendableRowCount"))
  #expect(src.contains("func append(frame: CGImage)"))
  #expect(src.contains("func finalize()"))
  #expect(src.contains("func thumbnail(maxHeight"))
  #expect(src.contains("static func rowFingerprints(of image: CGImage"))
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter scrollStitcherUsesDetectorAndBuildsImage 2>&1 | tail -10`
Expected: FAIL(文件不存在,读文件抛错)。

- [ ] **Step 3: 写实现**

`Sources/Velto/Screenshot/ScrollStitcher.swift`:

```swift
import CoreGraphics
import Foundation
import VeltoAnnotationCore

/// 把滚动过程中抓到的选区帧按帧间重叠拼成一张长图。负责:帧→逐行指纹、调用纯
/// `ScrollOverlapDetector` 决定追加多少行、维护增长的条带与尾部指纹、产出最终长图与缩略。
final class ScrollStitcher {
  enum Outcome {
    case first(rows: Int)
    case grew(rows: Int)
    case unchanged
    case skippedNoOverlap
    case reachedLimit
  }

  /// 每行等距取色采样点数(量化后并入指纹)。
  private static let samplesPerRow = 32

  private let maxPixelHeight: Int
  private(set) var pixelWidth = 0
  private(set) var pixelHeight = 0
  private var strips: [CGImage] = []          // 自顶向下:strips[0]=首帧,其后为各帧新增底部条带
  private var fingerprints: [UInt64] = []     // 整张画布逐行指纹(像素行,自顶向下)

  init(maxPixelHeight: Int = 30000) { self.maxPixelHeight = maxPixelHeight }

  /// 追加一帧,返回拼接结果。
  func append(frame: CGImage) -> Outcome {
    let fp = Self.rowFingerprints(of: frame, samples: Self.samplesPerRow)
    if strips.isEmpty {
      pixelWidth = frame.width
      pixelHeight = frame.height
      strips = [frame]
      fingerprints = fp
      return .first(rows: frame.height)
    }
    if pixelHeight >= maxPixelHeight { return .reachedLimit }
    let tail = Array(fingerprints.suffix(fp.count))
    guard let appendable = ScrollOverlapDetector.appendableRowCount(canvasTail: tail, frame: fp) else {
      return .skippedNoOverlap
    }
    if appendable == 0 { return .unchanged }
    let newRows = min(appendable, frame.height)
    // 新行 = 新帧底部 newRows 行(CGImage 左上原点,故 y 取 height-newRows)。
    guard let strip = frame.cropping(to: CGRect(
      x: 0, y: frame.height - newRows, width: frame.width, height: newRows)) else {
      return .skippedNoOverlap
    }
    strips.append(strip)
    fingerprints.append(contentsOf: fp.suffix(newRows))
    pixelHeight += newRows
    return .grew(rows: newRows)
  }

  /// 把条带竖直堆叠产出最终长图。
  func finalize() -> CGImage? {
    guard !strips.isEmpty, pixelWidth > 0, pixelHeight > 0 else { return nil }
    guard let ctx = CGContext(
      data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    var y = pixelHeight   // CGContext 左下原点:从顶往下逐条画。
    for strip in strips {
      y -= strip.height
      ctx.draw(strip, in: CGRect(x: 0, y: y, width: pixelWidth, height: strip.height))
    }
    return ctx.makeImage()
  }

  /// HUD 用等比缩略(限制高度)。
  func thumbnail(maxHeight: Int) -> CGImage? {
    guard pixelWidth > 0, pixelHeight > 0 else { return nil }
    let scale = min(1.0, CGFloat(maxHeight) / CGFloat(pixelHeight))
    let tw = max(1, Int(CGFloat(pixelWidth) * scale))
    let th = max(1, Int(CGFloat(pixelHeight) * scale))
    guard let ctx = CGContext(
      data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .low
    let s = CGFloat(th) / CGFloat(pixelHeight)
    var y = th
    for strip in strips {
      let sh = max(1, Int(CGFloat(strip.height) * s))
      y -= sh
      ctx.draw(strip, in: CGRect(x: 0, y: y, width: tw, height: sh))
    }
    return ctx.makeImage()
  }

  /// 逐行指纹:每行等距取 samples 个像素,各取 RGB 高 4 位并入 FNV-1a 哈希。
  /// CGImage 数据为左上原点(行 0 = 顶部),与"自顶向下"约定一致。
  static func rowFingerprints(of image: CGImage, samples: Int) -> [UInt64] {
    let w = image.width, h = image.height
    guard w > 0, h > 0, samples > 0,
          let data = image.dataProvider?.data,
          let ptr = CFDataGetBytePtr(data) else { return [] }
    let bpr = image.bytesPerRow
    let bpp = max(1, image.bitsPerPixel / 8)
    let count = CFDataGetLength(data)
    var result = [UInt64](repeating: 0, count: h)
    for row in 0..<h {
      var hash: UInt64 = 1469598103934665603
      for s in 0..<samples {
        let col = samples > 1 ? (w - 1) * s / (samples - 1) : 0
        let off = row * bpr + col * bpp
        guard off + 2 < count else { continue }
        let r = UInt64(ptr[off] & 0xF0)
        let g = UInt64(ptr[off + 1] & 0xF0)
        let b = UInt64(ptr[off + 2] & 0xF0)
        hash = (hash ^ (r &+ (g << 8) &+ (b << 16))) &* 1099511628211
      }
      result[row] = hash
    }
    return result
  }
}
```

- [ ] **Step 4: 跑测试 + 编译确认通过**

Run: `swift test --filter scrollStitcherUsesDetectorAndBuildsImage 2>&1 | tail -10 && swift build 2>&1 | tail -3`
Expected: 测试 PASS;`Build complete!`。

- [ ] **Step 5: 提交**

```bash
git add Sources/Velto/Screenshot/ScrollStitcher.swift
git commit -m "滚动截图:ScrollStitcher 帧间拼接与长图产出

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: ScrollCaptureHUD(浮窗:缩略 + 提示 + 键盘)

**Files:**
- Create: `Sources/Velto/Screenshot/ScrollCaptureHUD.swift`
- Test: `Tests/VeltoTests/ScrollCaptureHUDTests.swift`

**Interfaces:**
- Produces:
  - `ScrollCaptureHUD.init(onScreen screenFrame: CGRect)`
  - `var onCopy: (() -> Void)?` / `var onSave: (() -> Void)?` / `var onCancel: (() -> Void)?`
  - `func update(thumbnail: CGImage?, heightPx: Int, hint: String?)`

- [ ] **Step 1: 写失败测试(源串)**

`Tests/VeltoTests/ScrollCaptureHUDTests.swift`:

```swift
import Foundation
import Testing

@Test func scrollCaptureHUDHandlesKeysAndUpdates() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let src = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScrollCaptureHUD.swift"), encoding: .utf8)
  #expect(src.contains("class ScrollCaptureHUD"))
  #expect(src.contains("var onCopy"))
  #expect(src.contains("var onSave"))
  #expect(src.contains("var onCancel"))
  #expect(src.contains("func update(thumbnail"))
  #expect(src.contains("override func keyDown"))
  #expect(src.contains("case 36, 49"))   // Enter / 空格 = 完成
  #expect(src.contains("case 53"))        // Esc = 取消
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter scrollCaptureHUDHandlesKeysAndUpdates 2>&1 | tail -10`
Expected: FAIL(文件不存在)。

- [ ] **Step 3: 写实现**

`Sources/Velto/Screenshot/ScrollCaptureHUD.swift`:

```swift
import AppKit

/// 滚动捕获浮窗:展示长图缩略 + 提示;作为 key 窗口接 Enter/空格(完成复制)、⌘S(保存)、Esc(取消)。
/// 滚轮事件落在光标下的窗口(与 key 焦点无关),故 HUD 接键盘不影响用户滚动目标 App。
@MainActor
final class ScrollCaptureHUD: NSWindow {
  var onCopy: (() -> Void)?
  var onSave: (() -> Void)?
  var onCancel: (() -> Void)?

  private let imageView = NSImageView()
  private let hintLabel = NSTextField(labelWithString: "")
  private static let defaultHint = "向下滚动目标窗口(滚慢一点)\nEnter/空格 完成 · ⌘S 保存 · Esc 取消"

  init(onScreen screenFrame: CGRect) {
    let size = NSSize(width: 240, height: 340)
    let origin = NSPoint(x: screenFrame.maxX - size.width - 24, y: screenFrame.minY + 24)
    super.init(contentRect: CGRect(origin: origin, size: size),
               styleMask: [.borderless], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    level = .screenSaver
    hasShadow = true
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    setupContent(size: size)
  }

  override var canBecomeKey: Bool { true }

  private func setupContent(size: NSSize) {
    let container = NSView(frame: CGRect(origin: .zero, size: size))
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
    container.layer?.cornerRadius = 12

    imageView.frame = CGRect(x: 12, y: 60, width: size.width - 24, height: size.height - 72)
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.wantsLayer = true
    imageView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
    container.addSubview(imageView)

    hintLabel.frame = CGRect(x: 12, y: 8, width: size.width - 24, height: 44)
    hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
    hintLabel.textColor = .white
    hintLabel.alignment = .center
    hintLabel.maximumNumberOfLines = 3
    hintLabel.lineBreakMode = .byWordWrapping
    hintLabel.stringValue = Self.defaultHint
    container.addSubview(hintLabel)
    contentView = container
  }

  func update(thumbnail: CGImage?, heightPx: Int, hint: String?) {
    if let thumbnail {
      imageView.image = NSImage(cgImage: thumbnail, size: .zero)
    }
    hintLabel.stringValue = hint ?? Self.defaultHint
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 49: onCopy?()                                            // Enter / 空格
    case 1 where event.modifierFlags.contains(.command): onSave?()    // ⌘S
    case 53: onCancel?()                                              // Esc
    default: super.keyDown(with: event)
    }
  }
}
```

- [ ] **Step 4: 跑测试 + 编译确认通过**

Run: `swift test --filter scrollCaptureHUDHandlesKeysAndUpdates 2>&1 | tail -10 && swift build 2>&1 | tail -3`
Expected: 测试 PASS;`Build complete!`。

- [ ] **Step 5: 提交**

```bash
git add Sources/Velto/Screenshot/ScrollCaptureHUD.swift
git commit -m "滚动截图:ScrollCaptureHUD 浮窗(缩略+提示+键盘)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: ScreenshotSession 接入 scroll 模式(编排 + 替换占位)

**Files:**
- Modify: `Sources/Velto/Screenshot/ScreenshotSession.swift`
- Test: `Tests/VeltoTests/ScreenshotSessionScrollTests.swift`

**Interfaces:**
- Consumes: `ScrollStitcher`(Task 3)、`ScrollCaptureHUD`(Task 4)、`ScreenshotCapturer.captureRegion(in:globalRect:)`(Task 2)
- 现有入口:`overlayDidRequest(.scroll, globalRect:, document:)` 已由 overlay 的 `confirm(.scroll)`(S 键)触发。

- [ ] **Step 1: 写失败测试(源串)**

`Tests/VeltoTests/ScreenshotSessionScrollTests.swift`:

```swift
import Foundation
import Testing

@Test func screenshotSessionWiresScrollCapture() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let src = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScreenshotSession.swift"), encoding: .utf8)
  #expect(src.contains("func beginScrollCapture"))
  #expect(src.contains("ScrollStitcher("))
  #expect(src.contains("ScrollCaptureHUD("))
  #expect(src.contains("ScreenshotCapturer.captureRegion"))
  #expect(src.contains("ignoresMouseEvents = true"))
  // 占位的 "not implemented" 必须被真正实现替换。
  #expect(!src.contains("scroll capture not implemented yet"))
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter screenshotSessionWiresScrollCapture 2>&1 | tail -10`
Expected: FAIL(`beginScrollCapture` 等不存在,且仍含占位串)。

- [ ] **Step 3a: 替换 `.scroll` 占位分支**

`Sources/Velto/Screenshot/ScreenshotSession.swift`,把 `overlayDidRequest` 里现有的:

```swift
    case .scroll:
      // Phase 3 占位:本期不实现滚动拼接,轻提示后留在会话。
      ScreenshotDebugLog.log("scroll capture not implemented yet")
      NSSound.beep()
      return
```

改为:

```swift
    case .scroll:
      beginScrollCapture(globalRect: globalRect)
      return
```

- [ ] **Step 3b: 加 scroll 模式状态与方法(插到 `teardown()` 之前)**

```swift
  // MARK: - 滚动长截图

  private var scrollStitcher: ScrollStitcher?
  private var scrollHUD: ScrollCaptureHUD?
  private var scrollTimer: DispatchSourceTimer?
  private var scrollRegion: CGRect = .zero
  private var scrollSnapshot: DisplaySnapshot?
  private var scrollCapturing = false

  /// 进入滚动捕获:overlay 透传+隐形露出真实 App,弹 HUD,起定时器逐帧抓取拼接。
  private func beginScrollCapture(globalRect: CGRect) {
    guard let overlay = activeOverlay,
          let snapshot = snapshots.first(where: { $0.frame == overlay.globalFrame }) else {
      ScreenshotDebugLog.log("scroll: 无活动 overlay/snapshot"); NSSound.beep(); return
    }
    ScreenshotDebugLog.log("scroll: begin region="
      + "\(Int(globalRect.minX)),\(Int(globalRect.minY)) \(Int(globalRect.width))x\(Int(globalRect.height))")
    scrollRegion = globalRect
    scrollSnapshot = snapshot
    scrollStitcher = ScrollStitcher()

    overlay.window?.ignoresMouseEvents = true
    overlay.window?.alphaValue = 0   // 隐形透传,露出真实 App 供滚动

    let hud = ScrollCaptureHUD(onScreen: snapshot.frame)
    hud.onCopy = { [weak self] in self?.finishScrollCapture(.copy) }
    hud.onSave = { [weak self] in self?.finishScrollCapture(.save) }
    hud.onCancel = { [weak self] in self?.cancelScrollCapture() }
    hud.orderFrontRegardless()
    hud.makeKey()
    scrollHUD = hud

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + .milliseconds(120), repeating: .milliseconds(120))
    timer.setEventHandler { [weak self] in self?.scrollTick() }
    scrollTimer = timer
    timer.resume()
  }

  /// 定时一帧:串行化(同一时刻只一帧在飞),抓选区→拼接→刷新 HUD。
  private func scrollTick() {
    guard !scrollCapturing, let snapshot = scrollSnapshot, let stitcher = scrollStitcher else { return }
    scrollCapturing = true
    Task { @MainActor in
      defer { scrollCapturing = false }
      guard let frame = try? await ScreenshotCapturer.captureRegion(
        in: snapshot, globalRect: scrollRegion) else { return }
      let outcome = stitcher.append(frame: frame)
      let hint: String?
      switch outcome {
      case .skippedNoOverlap: hint = "滚慢一点,刚才那段没接上"
      case .reachedLimit: hint = "已达最大长度,可按 Enter 完成"
      default: hint = nil
      }
      scrollHUD?.update(thumbnail: stitcher.thumbnail(maxHeight: 260),
                        heightPx: stitcher.pixelHeight, hint: hint)
      ScreenshotDebugLog.log("scroll tick: \(outcome) height=\(stitcher.pixelHeight)")
    }
  }

  /// 完成:定稿长图 → 复制/保存。成功 teardown 整个会话;失败保留(可重试 Enter/⌘S)。
  private func finishScrollCapture(_ action: ScreenshotSessionAction) {
    stopScrollTimer()
    guard let image = scrollStitcher?.finalize() else {
      ScreenshotDebugLog.log("scroll: finalize 为空"); cancelScrollCapture(); return
    }
    ScreenshotDebugLog.log("scroll: finalize \(image.width)x\(image.height) action=\(action)")
    let outcome: Result<Void, ScreenshotWriteError>
    switch action {
    case .copy:
      outcome = ScreenshotImageWriter.copyToClipboard(image)
    case .save:
      outcome = ScreenshotImageWriter.save(
        image, toDirectory: preferences.saveDirectoryPath,
        format: preferences.imageFormat, alsoCopy: preferences.saveAlsoCopiesToClipboard).map { _ in () }
    case .scroll:
      return
    }
    switch outcome {
    case .success:
      teardownScrollUI()
      teardown()
    case .failure(let error):
      // 保留已拼结果与 HUD,允许再次 Enter/⌘S;仅提示,不 teardown。
      presentOutputFailure(describe(error), screenFrame: scrollSnapshot?.frame, near: scrollRegion)
    }
  }

  /// 取消滚动:丢弃长图,overlay 复原可见可交互,回到选区。
  private func cancelScrollCapture() {
    stopScrollTimer()
    teardownScrollUI()
    if let overlay = activeOverlay {
      overlay.window?.makeKey()
      overlay.needsDisplay = true
    }
    ScreenshotDebugLog.log("scroll: 取消,回到选区")
  }

  private func teardownScrollUI() {
    scrollHUD?.orderOut(nil)
    scrollHUD = nil
    scrollStitcher = nil
    scrollSnapshot = nil
    if let overlay = activeOverlay {
      overlay.window?.ignoresMouseEvents = false
      overlay.window?.alphaValue = 1
    }
  }

  private func stopScrollTimer() {
    scrollTimer?.cancel()
    scrollTimer = nil
  }
```

- [ ] **Step 3c: teardown 里兜底清理 scroll(防会话外部取消时残留)**

在 `teardown()` 顶部(`failureToast?.orderOut(nil)` 之前)加:

```swift
    stopScrollTimer()
    scrollHUD?.orderOut(nil)
    scrollHUD = nil
    scrollStitcher = nil
```

- [ ] **Step 4: 跑测试 + 编译确认通过**

Run: `swift test --filter screenshotSessionWiresScrollCapture 2>&1 | tail -10 && swift test 2>&1 | tail -3`
Expected: 该测试 PASS;全量 `Test run with N tests ... passed`。

- [ ] **Step 5: 提交**

```bash
git add Sources/Velto/Screenshot/ScreenshotSession.swift
git commit -m "滚动截图:ScreenshotSession 接入 scroll 模式编排,替换占位

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 6: 实机验收(必做)**

Run: `./scripts/build-app.sh --run 2>&1 | tail -6`
然后手测:打开一个长页面 → ⇧⌘D → 框选正文(避开滚动条与固定头部)→ 按 `S` 进入滚动 → 缓慢向下滚 → 看 HUD 缩略实时变长且不错位 → `Enter` 完成并粘贴验证长图;再试 `⌘S` 保存、`Esc` 取消。若拼接异常,开"调试日志"看 `scroll tick` 段(按 [[velto-screenshot-debug-logging-workflow]])。
Expected: 长图连续、无重影/错位;复制/保存/取消都正常。

---

## Self-Review(对照 spec)

- **流程/状态机**:Task 5 的 begin/tick/finish/cancel + 键位(Enter/空格复制、⌘S 保存、Esc 取消)对齐 spec「交互流程与状态机」。✓
- **不压暗**:overlay `alphaValue = 0` + `ignoresMouseEvents = true` 对齐「不压暗整屏 + 透传」。✓
- **HUD**:Task 4 缩略 + 提示 + key 接键盘对齐 spec「HUD」。✓
- **M1 定时抓取**:Task 2 `captureRegion` + Task 5 ~120ms 定时器、串行化 `scrollCapturing` 对齐「捕获机制」。✓
- **拼接**:Task 1 detector(行指纹重叠)+ Task 3 stitcher(条带/finalize/thumbnail)对齐「拼接算法」。✓
- **错误处理**:skippedNoOverlap→提示慢滚、unchanged→不增长、reachedLimit→上限提示、抓帧失败→跳过、finalize 空→取消、输出失败→保留可重试,对齐 spec「错误处理」。✓
- **测试**:detector 行为单测(5 例)+ 各 AppKit 单元源串,按约定不入库,对齐「测试策略」。✓
- **非目标**:未实现自动滚动/固定头部/横向/向上/进标注。✓
- **Placeholder 扫描**:无 TBD/TODO;每个代码步含完整代码。✓
- **类型一致性**:`Outcome`、`appendableRowCount`、`captureRegion`、`finalize/thumbnail/pixelHeight` 在 Task 间签名一致。✓
