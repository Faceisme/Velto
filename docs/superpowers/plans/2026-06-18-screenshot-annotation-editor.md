# 截图标注编辑器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 在 Velto 现有截图覆盖层内加入可编辑标注对象、Xnip 风格 Liquid Glass 工具栏、Shift 实时角度吸附、统一预览/导出渲染和完整撤销重做。

**Architecture:** 可测试的对象模型、几何、交互状态、图标路径和 Core Graphics 渲染放进 VeltoAnnotationCore SwiftPM library target；Velto executable 只负责 AppKit 画布、工具栏、文字编辑和现有截图会话桥接。标注对象使用选区内点坐标，预览与输出共用 AnnotationRenderer；父覆盖层保留已验证的 even-odd 暗罩，不使用会导致点击穿透的透明 clear 挖洞。

**Tech Stack:** Swift 6.2、macOS 26、AppKit、Core Graphics、Core Text、NSGlassEffectView、Swift Testing。

---

## Global Constraints

- 用户已明确不新建分支；在当前 checkout 执行，不创建 worktree。
- 先验证并独立提交当前 Phase 1 未提交生产改动，Phase 2 commit 不得混入它们。
- 仅 macOS 26+，不写旧系统回退。
- 新增截图/标注 Swift 文件使用 2 空格缩进。
- Tests/ 文件先写、先运行并观察失败，但最终 commit 不暂存测试文件。
- 每个生产提交前运行对应测试和 git diff --check。
- 不实现滚动长截图、跨屏选区、自由笔刷马赛克、图层面板或工程文件持久化。
- 不恢复 Phase 1 已证明会穿透的透明洞分层方案。
- 最终部署使用 CONFIGURATION=release SKIP_TCC_RESET=1 ./scripts/build-app.sh --run。脚本会结束旧进程、覆盖 /Applications/Velto.app、签名并启动。

## File Structure

为获得真实行为测试，纯逻辑放进可导入 target：

~~~text
Sources/VeltoAnnotationCore/
├── AnnotationTool.swift
├── AnnotationStyle.swift
├── AnnotationElement.swift
├── AnnotationDocument.swift
├── AnnotationHistory.swift
├── AnnotationGeometry.swift
├── AnnotationEditor.swift
├── AnnotationRenderer.swift
├── AnnotationMosaicRenderer.swift
├── AnnotationIconLibrary.swift
└── AnnotationToolbarLayout.swift

Sources/Velto/Screenshot/Annotation/
├── AnnotationCanvasView.swift
├── AnnotationToolbarView.swift
├── AnnotationPropertyBarView.swift
└── AnnotationTextEditor.swift
~~~

现有文件改动：Package.swift、ScreenshotOverlayView.swift、ScreenshotOverlayWindow.swift、ScreenshotSession.swift、ScreenshotPreferences.swift、ScreenshotPage.swift、ScreenshotImageWriter.swift。

---

### Task 0: 验证并独立提交 Phase 1 工作区改动

**Files:**
- Review: Sources/Velto/EventTapManager.swift
- Review: Sources/Velto/Screenshot/ScreenshotGeometry.swift
- Review: Sources/Velto/Screenshot/ScreenshotOverlayView.swift
- Review: Sources/Velto/Screenshot/ScreenshotSession.swift
- Review: Sources/Velto/Screenshot/ScreenshotHotCornerGuard.swift
- Do not stage: Tests/
- Do not stage: .superpowers/

- [ ] **Step 1: 确认脏改动只属于 Phase 1**

Run:

~~~bash
git status -sb
git diff -- Sources/Velto/EventTapManager.swift \
  Sources/Velto/Screenshot/ScreenshotGeometry.swift \
  Sources/Velto/Screenshot/ScreenshotOverlayView.swift \
  Sources/Velto/Screenshot/ScreenshotSession.swift
sed -n '1,260p' Sources/Velto/Screenshot/ScreenshotHotCornerGuard.swift
~~~

Expected: 生产改动仅包含触发角守卫、边缘吸附、移动选区保持尺寸和选框视觉修正；没有 Phase 2 标注代码。

- [ ] **Step 2: 运行当前基线验证**

Run:

~~~bash
swift test
swift build -c release --arch arm64 --scratch-path .build --product Velto
~~~

Expected: 测试 0 failures；Release 显示 Build complete，exit 0。

- [ ] **Step 3: 只提交 Phase 1 生产文件**

~~~bash
git add Sources/Velto/EventTapManager.swift \
  Sources/Velto/Screenshot/ScreenshotGeometry.swift \
  Sources/Velto/Screenshot/ScreenshotOverlayView.swift \
  Sources/Velto/Screenshot/ScreenshotSession.swift \
  Sources/Velto/Screenshot/ScreenshotHotCornerGuard.swift
git diff --cached --check
git commit -m "截图：完善触发角守卫与选区交互"
~~~

Expected: commit 不包含 Tests/、.superpowers/ 或 Phase 2 文件。

---

### Task 1: 建立可测试 Core target、工具和样式

**Files:**
- Modify: Package.swift
- Create: Sources/VeltoAnnotationCore/AnnotationTool.swift
- Create: Sources/VeltoAnnotationCore/AnnotationStyle.swift
- Test: Tests/VeltoTests/AnnotationToolStyleTests.swift（不提交）

- [ ] **Step 1: 写失败测试**

~~~swift
import Foundation
import Testing
@testable import VeltoAnnotationCore

@Test func annotationToolsHaveApprovedOrder() {
  #expect(AnnotationTool.allCases == [
    .rectangle, .ellipse, .line, .arrow, .pen,
    .mosaic, .text, .highlight, .sequence, .crop
  ])
}

@Test func annotationStyleDefaultsMatchSpec() {
  let style = AnnotationStyle.defaults
  #expect(style.lineWidth == 3)
  #expect(style.fontSize == 18)
  #expect(style.highlightOpacity == 0.35)
  #expect(style.mosaicBlockSize == 12)
  #expect(style.fillOpacity == 0)
  #expect(style.strokeColor == .systemRed)
}

@Test func annotationColorRoundTripsRGBA() throws {
  let color = AnnotationColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
  let data = try JSONEncoder().encode(color)
  #expect(try JSONDecoder().decode(AnnotationColor.self, from: data) == color)
}
~~~

- [ ] **Step 2: 运行测试并观察正确失败**

Run: swift test --filter annotation

Expected: FAIL，no such module VeltoAnnotationCore。

- [ ] **Step 3: 修改 Package.swift**

Velto dependencies 改为 ["betterfinder", "VeltoAnnotationCore"]，VeltoTests dependencies 改为 ["betterfinder", "VeltoAnnotationCore"]，并增加：

~~~swift
.target(
    name: "VeltoAnnotationCore",
    path: "Sources/VeltoAnnotationCore"
),
~~~

- [ ] **Step 4: 实现工具与样式**

~~~swift
// AnnotationTool.swift
import Foundation

public enum AnnotationTool: String, CaseIterable, Codable, Equatable, Sendable {
  case rectangle, ellipse, line, arrow, pen, mosaic, text, highlight, sequence, crop
}

public enum AnnotationTextAlignment: String, Codable, Equatable, Sendable {
  case left, center, right
}
~~~

~~~swift
// AnnotationStyle.swift
import AppKit
import Foundation

public struct AnnotationColor: Codable, Equatable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
  }

  public init(resolving color: NSColor) {
    let rgb = color.usingColorSpace(.deviceRGB) ?? color
    red = Double(rgb.redComponent); green = Double(rgb.greenComponent)
    blue = Double(rgb.blueComponent); alpha = Double(rgb.alphaComponent)
  }

  public var nsColor: NSColor {
    NSColor(red: CGFloat(red), green: CGFloat(green),
            blue: CGFloat(blue), alpha: CGFloat(alpha))
  }

  public static let systemRed = AnnotationColor(resolving: .systemRed)
}

public struct AnnotationStyle: Codable, Equatable, Sendable {
  public var strokeColor: AnnotationColor
  public var lineWidth: CGFloat
  public var fillColor: AnnotationColor
  public var fillOpacity: CGFloat
  public var fontSize: CGFloat
  public var isBold: Bool
  public var textAlignment: AnnotationTextAlignment
  public var highlightOpacity: CGFloat
  public var mosaicBlockSize: Int
  public var sequenceDiameter: CGFloat

  public init(
    strokeColor: AnnotationColor, lineWidth: CGFloat,
    fillColor: AnnotationColor, fillOpacity: CGFloat,
    fontSize: CGFloat, isBold: Bool, textAlignment: AnnotationTextAlignment,
    highlightOpacity: CGFloat, mosaicBlockSize: Int, sequenceDiameter: CGFloat
  ) {
    self.strokeColor = strokeColor; self.lineWidth = lineWidth
    self.fillColor = fillColor; self.fillOpacity = fillOpacity
    self.fontSize = fontSize; self.isBold = isBold; self.textAlignment = textAlignment
    self.highlightOpacity = highlightOpacity
    self.mosaicBlockSize = mosaicBlockSize; self.sequenceDiameter = sequenceDiameter
  }

  public static let defaults = AnnotationStyle(
    strokeColor: .systemRed, lineWidth: 3, fillColor: .systemRed, fillOpacity: 0,
    fontSize: 18, isBold: false, textAlignment: .left,
    highlightOpacity: 0.35, mosaicBlockSize: 12, sequenceDiameter: 28
  )
}
~~~

- [ ] **Step 5: 验证并提交**

Run: swift test --filter annotation

Expected: 3 tests PASS。

~~~bash
git add Package.swift Sources/VeltoAnnotationCore/AnnotationTool.swift \
  Sources/VeltoAnnotationCore/AnnotationStyle.swift
git diff --cached --check
git commit -m "截图标注：建立可测试核心模块与样式模型"
~~~

---

### Task 2: 对象、文档和撤销历史

**Files:**
- Create: Sources/VeltoAnnotationCore/AnnotationElement.swift
- Create: Sources/VeltoAnnotationCore/AnnotationDocument.swift
- Create: Sources/VeltoAnnotationCore/AnnotationHistory.swift
- Test: Tests/VeltoTests/AnnotationDocumentHistoryTests.swift（不提交）

- [ ] **Step 1: 写失败测试**

~~~swift
import CoreGraphics
import Testing
@testable import VeltoAnnotationCore

@Test func annotationDocumentStartsWithFullCropAndNoTool() {
  let document = AnnotationDocument(canvasSize: CGSize(width: 320, height: 180))
  #expect(document.cropRect == CGRect(x: 0, y: 0, width: 320, height: 180))
  #expect(document.elements.isEmpty)
  #expect(document.selectedElementID == nil)
  #expect(document.activeTool == nil)
  #expect(document.nextSequenceNumber == 1)
}

@Test func annotationHistoryRecordsOneGestureAsOneStep() {
  var document = AnnotationDocument(canvasSize: CGSize(width: 200, height: 100))
  let before = document
  document.elements.append(.rectangle(BoxAnnotation(
    rect: CGRect(x: 10, y: 10, width: 50, height: 30), style: .defaults
  )))
  var history = AnnotationHistory(limit: 100)
  history.record(before: before, after: document)
  #expect(history.undo(document: &document))
  #expect(document.elements.isEmpty)
  #expect(history.redo(document: &document))
  #expect(document.elements.count == 1)
}

@Test func annotationHistoryLimitAndRedoClearingWork() {
  var history = AnnotationHistory(limit: 2)
  var document = AnnotationDocument(canvasSize: CGSize(width: 10, height: 10))
  for value in 1...3 {
    let before = document
    document.nextSequenceNumber = value + 1
    history.record(before: before, after: document)
  }
  #expect(history.undoCount == 2)
  #expect(history.undo(document: &document))
  let before = document
  document.nextSequenceNumber = 99
  history.record(before: before, after: document)
  #expect(history.redoCount == 0)
}
~~~

- [ ] **Step 2: 运行并确认因类型缺失失败**

Run: swift test --filter annotation

Expected: FAIL，缺少 AnnotationDocument、AnnotationElement 或 AnnotationHistory。

- [ ] **Step 3: 实现对象值类型**

AnnotationElement.swift 定义以下公开结构：

~~~swift
public struct BoxAnnotation: Equatable, Sendable {
  public var id: UUID; public var rect: CGRect; public var style: AnnotationStyle
  public init(id: UUID = UUID(), rect: CGRect, style: AnnotationStyle) {
    self.id = id; self.rect = rect; self.style = style
  }
}
public struct SegmentAnnotation: Equatable, Sendable {
  public var id: UUID; public var start: CGPoint; public var end: CGPoint; public var style: AnnotationStyle
  public init(id: UUID = UUID(), start: CGPoint, end: CGPoint, style: AnnotationStyle) {
    self.id = id; self.start = start; self.end = end; self.style = style
  }
}
public struct PathAnnotation: Equatable, Sendable {
  public var id: UUID; public var points: [CGPoint]; public var style: AnnotationStyle
  public init(id: UUID = UUID(), points: [CGPoint], style: AnnotationStyle) {
    self.id = id; self.points = points; self.style = style
  }
}
public struct MosaicAnnotation: Equatable, Sendable {
  public var id: UUID; public var rect: CGRect; public var blockSize: Int
  public init(id: UUID = UUID(), rect: CGRect, blockSize: Int) {
    self.id = id; self.rect = rect; self.blockSize = blockSize
  }
}
public struct TextAnnotation: Equatable, Sendable {
  public var id: UUID; public var rect: CGRect; public var text: String; public var style: AnnotationStyle
  public init(id: UUID = UUID(), rect: CGRect, text: String, style: AnnotationStyle) {
    self.id = id; self.rect = rect; self.text = text; self.style = style
  }
}
public struct SequenceAnnotation: Equatable, Sendable {
  public var id: UUID; public var center: CGPoint; public var number: Int; public var style: AnnotationStyle
  public init(id: UUID = UUID(), center: CGPoint, number: Int, style: AnnotationStyle) {
    self.id = id; self.center = center; self.number = number; self.style = style
  }
}
public enum AnnotationElement: Equatable, Sendable {
  case rectangle(BoxAnnotation), ellipse(BoxAnnotation)
  case line(SegmentAnnotation), arrow(SegmentAnnotation)
  case freehand(PathAnnotation), highlight(PathAnnotation)
  case mosaic(MosaicAnnotation), text(TextAnnotation), sequence(SequenceAnnotation)
  public var id: UUID {
    switch self {
    case .rectangle(let value), .ellipse(let value): value.id
    case .line(let value), .arrow(let value): value.id
    case .freehand(let value), .highlight(let value): value.id
    case .mosaic(let value): value.id
    case .text(let value): value.id
    case .sequence(let value): value.id
    }
  }
}
~~~

- [ ] **Step 4: 实现文档与历史**

~~~swift
public struct AnnotationDocument: Equatable, Sendable {
  public var canvasSize: CGSize
  public var cropRect: CGRect
  public var elements: [AnnotationElement]
  public var selectedElementID: UUID?
  public var activeTool: AnnotationTool?
  public var nextSequenceNumber: Int

  public init(canvasSize: CGSize) {
    self.canvasSize = canvasSize
    cropRect = CGRect(origin: .zero, size: canvasSize)
    elements = []; selectedElementID = nil; activeTool = nil; nextSequenceNumber = 1
  }
}
~~~

~~~swift
public struct AnnotationHistory: Sendable {
  private struct Entry: Sendable {
    var before: AnnotationDocument
    var after: AnnotationDocument
  }
  private let limit: Int
  private var undoStack: [Entry] = []
  private var redoStack: [Entry] = []

  public init(limit: Int = 100) { self.limit = max(1, limit) }
  public var undoCount: Int { undoStack.count }
  public var redoCount: Int { redoStack.count }

  public mutating func record(before: AnnotationDocument, after: AnnotationDocument) {
    guard before != after else { return }
    undoStack.append(Entry(before: before, after: after))
    if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
    redoStack.removeAll()
  }

  public mutating func undo(document: inout AnnotationDocument) -> Bool {
    guard let entry = undoStack.popLast() else { return false }
    document = entry.before; redoStack.append(entry); return true
  }

  public mutating func redo(document: inout AnnotationDocument) -> Bool {
    guard let entry = redoStack.popLast() else { return false }
    document = entry.after; undoStack.append(entry); return true
  }
}
~~~

- [ ] **Step 5: 验证并提交**

Run: swift test --filter annotation

Expected: 3 tests PASS。

~~~bash
git add Sources/VeltoAnnotationCore/AnnotationElement.swift \
  Sources/VeltoAnnotationCore/AnnotationDocument.swift \
  Sources/VeltoAnnotationCore/AnnotationHistory.swift
git diff --cached --check
git commit -m "截图标注：加入对象文档与撤销历史"
~~~

---

### Task 3: Shift 角度吸附、图形约束和命中几何

**Files:**
- Create: Sources/VeltoAnnotationCore/AnnotationGeometry.swift
- Test: Tests/VeltoTests/AnnotationGeometryBehaviorTests.swift（不提交）

- [ ] **Step 1: 写失败测试**

~~~swift
import CoreGraphics
import Testing
@testable import VeltoAnnotationCore

@Test func annotationShiftLocksHorizontalAndVerticalExactly() {
  var state = AngleSnapState()
  let horizontal = AnnotationGeometry.constrainedEndpoint(
    anchor: CGPoint(x: 10, y: 20), cursor: CGPoint(x: 110, y: 24),
    shiftPressed: true, state: &state
  )
  #expect(horizontal.y == 20)
  state = AngleSnapState()
  let vertical = AnnotationGeometry.constrainedEndpoint(
    anchor: CGPoint(x: 10, y: 20), cursor: CGPoint(x: 14, y: 120),
    shiftPressed: true, state: &state
  )
  #expect(vertical.x == 10)
}

@Test func annotationShiftUsesFourDegreeHysteresis() {
  var state = AngleSnapState()
  _ = AnnotationGeometry.constrainedEndpoint(
    anchor: .zero, cursor: AnnotationGeometry.point(radius: 100, degrees: 20),
    shiftPressed: true, state: &state
  )
  #expect(state.directionIndex == 0)
  _ = AnnotationGeometry.constrainedEndpoint(
    anchor: .zero, cursor: AnnotationGeometry.point(radius: 100, degrees: 25),
    shiftPressed: true, state: &state
  )
  #expect(state.directionIndex == 0)
  _ = AnnotationGeometry.constrainedEndpoint(
    anchor: .zero, cursor: AnnotationGeometry.point(radius: 100, degrees: 27),
    shiftPressed: true, state: &state
  )
  #expect(state.directionIndex == 1)
}

@Test func annotationReleasingShiftReturnsRawCursor() {
  var state = AngleSnapState(directionIndex: 0)
  let cursor = CGPoint(x: 40, y: 13)
  #expect(AnnotationGeometry.constrainedEndpoint(
    anchor: .zero, cursor: cursor, shiftPressed: false, state: &state
  ) == cursor)
  #expect(state.directionIndex == nil)
}

@Test func annotationShiftOptionCreatesCenteredSquare() {
  #expect(AnnotationGeometry.constrainedBox(
    anchor: CGPoint(x: 50, y: 50), cursor: CGPoint(x: 70, y: 60),
    shiftPressed: true, optionPressed: true
  ) == CGRect(x: 30, y: 30, width: 40, height: 40))
}
~~~

- [ ] **Step 2: 运行并确认失败**

Run: swift test --filter annotation

Expected: FAIL，缺少 AnnotationGeometry 和 AngleSnapState。

- [ ] **Step 3: 实现角度吸附**

~~~swift
public struct AngleSnapState: Equatable, Sendable {
  public var directionIndex: Int?
  public init(directionIndex: Int? = nil) { self.directionIndex = directionIndex }
}

public enum AnnotationGeometry {
  private static let step = CGFloat.pi / 4
  private static let hysteresis = 4 * CGFloat.pi / 180

  public static func constrainedEndpoint(
    anchor: CGPoint, cursor: CGPoint, shiftPressed: Bool,
    state: inout AngleSnapState
  ) -> CGPoint {
    guard shiftPressed else { state.directionIndex = nil; return cursor }
    let dx = cursor.x - anchor.x, dy = cursor.y - anchor.y
    let radius = hypot(dx, dy)
    guard radius > 0 else { return anchor }
    let raw = atan2(dy, dx)
    let nearest = normalizedIndex(Int((raw / step).rounded()))
    if let active = state.directionIndex {
      let center = CGFloat(active) * step
      if abs(atan2(sin(raw - center), cos(raw - center))) > step / 2 + hysteresis {
        state.directionIndex = nearest
      }
    } else {
      state.directionIndex = nearest
    }
    let index = state.directionIndex ?? nearest
    switch index {
    case 0: return CGPoint(x: anchor.x + radius, y: anchor.y)
    case 2: return CGPoint(x: anchor.x, y: anchor.y + radius)
    case 4: return CGPoint(x: anchor.x - radius, y: anchor.y)
    case 6: return CGPoint(x: anchor.x, y: anchor.y - radius)
    default:
      let angle = CGFloat(index) * step
      return CGPoint(x: anchor.x + radius * cos(angle), y: anchor.y + radius * sin(angle))
    }
  }

  public static func constrainedBox(
    anchor: CGPoint, cursor: CGPoint, shiftPressed: Bool, optionPressed: Bool
  ) -> CGRect {
    var dx = cursor.x - anchor.x
    var dy = cursor.y - anchor.y
    if shiftPressed {
      let side = max(abs(dx), abs(dy))
      dx = dx < 0 ? -side : side
      dy = dy < 0 ? -side : side
    }
    if optionPressed {
      return CGRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy),
                    width: abs(dx) * 2, height: abs(dy) * 2)
    }
    return CGRect(x: min(anchor.x, anchor.x + dx),
                  y: min(anchor.y, anchor.y + dy),
                  width: abs(dx), height: abs(dy))
  }

  public static func point(radius: CGFloat, degrees: CGFloat) -> CGPoint {
    let angle = degrees * .pi / 180
    return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
  }
  private static func normalizedIndex(_ value: Int) -> Int { (value % 8 + 8) % 8 }
}
~~~

constrainedBox 在 Shift 时把 dx/dy 绝对值统一为较大值；Option 时以 anchor 为中心生成两倍宽高。

- [ ] **Step 4: 加入对象几何 API 和测试**

~~~swift
public enum AnnotationResizeHandle: CaseIterable, Sendable {
  case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

public static func hitTest(
  _ point: CGPoint, elements: [AnnotationElement], minimumTolerance: CGFloat = 6
) -> UUID?
public static func bounds(of element: AnnotationElement) -> CGRect
public static func moved(_ element: AnnotationElement, by delta: CGPoint) -> AnnotationElement
public static func resized(
  _ element: AnnotationElement, handle: AnnotationResizeHandle, to point: CGPoint
) -> AnnotationElement
public static func distance(
  from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint
) -> CGFloat
public static func smoothedPath(
  points: [CGPoint], minimumDistance: CGFloat = 1.5
) -> CGPath
~~~

命中倒序扫描 elements；线/箭头容差为 max(6, lineWidth / 2 + 4)；矩形/椭圆按描边或填充命中；文字、马赛克、序号按 bounds 命中。

- [ ] **Step 5: 验证并提交**

Run: swift test --filter annotation

Expected: 全部 PASS。

~~~bash
git add Sources/VeltoAnnotationCore/AnnotationGeometry.swift
git diff --cached --check
git commit -m "截图标注：实现 Shift 角度吸附与对象几何"
~~~

---

### Task 4: 可测试的编辑状态机

**Files:**
- Create: Sources/VeltoAnnotationCore/AnnotationEditor.swift
- Test: Tests/VeltoTests/AnnotationEditorTests.swift（不提交）

- [ ] **Step 1: 写失败测试**

~~~swift
import CoreGraphics
import Testing
@testable import VeltoAnnotationCore

@Test func annotationEditorCreatesShiftLockedArrowAsOneStep() {
  var editor = AnnotationEditor(canvasSize: CGSize(width: 400, height: 300))
  editor.selectTool(.arrow)
  editor.pointerDown(at: CGPoint(x: 20, y: 30), modifiers: [])
  editor.pointerDragged(to: CGPoint(x: 180, y: 36), modifiers: [.shift])
  editor.pointerUp(at: CGPoint(x: 180, y: 36), modifiers: [.shift])
  guard case .arrow(let arrow) = editor.document.elements.first else {
    Issue.record("expected arrow"); return
  }
  #expect(arrow.start.y == arrow.end.y)
  #expect(editor.history.undoCount == 1)
  #expect(editor.undo())
  #expect(editor.document.elements.isEmpty)
}

@Test func annotationSequenceNumbersDoNotRenumberAfterDelete() {
  var editor = AnnotationEditor(canvasSize: CGSize(width: 200, height: 200))
  editor.selectTool(.sequence)
  editor.click(at: CGPoint(x: 20, y: 20))
  editor.click(at: CGPoint(x: 50, y: 50))
  editor.select(elementID: editor.document.elements[0].id)
  editor.deleteSelection()
  editor.click(at: CGPoint(x: 80, y: 80))
  let numbers = editor.document.elements.compactMap { element -> Int? in
    guard case .sequence(let value) = element else { return nil }
    return value.number
  }
  #expect(numbers == [2, 3])
}

@Test func annotationNudgeUsesOneOrTenPoints() {
  var editor = AnnotationEditor(canvasSize: CGSize(width: 100, height: 100))
  editor.selectTool(.rectangle)
  editor.pointerDown(at: CGPoint(x: 10, y: 10), modifiers: [])
  editor.pointerUp(at: CGPoint(x: 30, y: 30), modifiers: [])
  editor.nudge(dx: 1, dy: 0, accelerated: false)
  editor.nudge(dx: 0, dy: 1, accelerated: true)
  guard case .rectangle(let value) = editor.document.elements[0] else { return }
  #expect(value.rect.origin == CGPoint(x: 11, y: 20))
}

@Test func annotationCropClampsToSixteenPoints() {
  var editor = AnnotationEditor(canvasSize: CGSize(width: 100, height: 100))
  editor.updateCrop(CGRect(x: 20, y: 20, width: 2, height: 3))
  #expect(editor.document.cropRect.width == 16)
  #expect(editor.document.cropRect.height == 16)
}
~~~

- [ ] **Step 2: 运行并确认失败**

Run: swift test --filter annotation

Expected: FAIL，缺少 AnnotationEditor。

- [ ] **Step 3: 实现公开状态机**

~~~swift
public struct AnnotationModifiers: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let shift = AnnotationModifiers(rawValue: 1 << 0)
  public static let option = AnnotationModifiers(rawValue: 1 << 1)
}

public enum AnnotationCancelResult: Equatable, Sendable {
  case cancelledGesture, deselectedObject, deactivatedTool, cancelSession
}

public struct AnnotationEditor: Sendable {
  public private(set) var document: AnnotationDocument
  public private(set) var history = AnnotationHistory(limit: 100)
  public var style: AnnotationStyle

  public init(canvasSize: CGSize, style: AnnotationStyle = .defaults) {
    document = AnnotationDocument(canvasSize: canvasSize)
    self.style = style
  }
  public mutating func selectTool(_ tool: AnnotationTool?)
  public mutating func select(elementID: UUID?)
  public mutating func pointerDown(at point: CGPoint, modifiers: AnnotationModifiers)
  public mutating func pointerDragged(to point: CGPoint, modifiers: AnnotationModifiers)
  public mutating func pointerUp(at point: CGPoint, modifiers: AnnotationModifiers)
  public mutating func click(at point: CGPoint)
  public mutating func commitText(_ text: String, rect: CGRect)
  public mutating func updateCrop(_ rect: CGRect)
  public mutating func deleteSelection()
  public mutating func nudge(dx: CGFloat, dy: CGFloat, accelerated: Bool)
  public mutating func undo() -> Bool
  public mutating func redo() -> Bool
  public mutating func cancelCurrentLayer() -> AnnotationCancelResult
}
~~~

内部状态保存 gestureBeforeDocument、起点、临时对象、移动/缩放目标和 AngleSnapState。pointerDragged 只改预览，pointerUp 合并为一个 history entry；小于 2pt 的对象丢弃。

- [ ] **Step 4: 穷举全部工具行为**

~~~swift
switch document.activeTool {
case .rectangle: createOrUpdateBox(kind: .rectangle, point: point, modifiers: modifiers)
case .ellipse: createOrUpdateBox(kind: .ellipse, point: point, modifiers: modifiers)
case .line: createOrUpdateSegment(kind: .line, point: point, modifiers: modifiers)
case .arrow: createOrUpdateSegment(kind: .arrow, point: point, modifiers: modifiers)
case .pen: appendPathPoint(point, kind: .freehand)
case .highlight: appendPathPoint(point, kind: .highlight)
case .mosaic: createOrUpdateMosaic(point)
case .text: break
case .sequence: createSequence(at: point)
case .crop: updateCropPreview(point, modifiers: modifiers)
case nil: selectOrMoveElement(at: point)
}
~~~

cancelCurrentLayer 顺序为：取消当前手势、取消对象选择、退出工具、请求取消会话。

- [ ] **Step 5: 验证并提交**

Run: swift test --filter annotation

Expected: 全部 PASS。

~~~bash
git add Sources/VeltoAnnotationCore/AnnotationEditor.swift
git diff --cached --check
git commit -m "截图标注：实现对象编辑状态机"
~~~

---

### Task 5: 统一渲染、马赛克和裁剪

**Files:**
- Create: Sources/VeltoAnnotationCore/AnnotationRenderer.swift
- Create: Sources/VeltoAnnotationCore/AnnotationMosaicRenderer.swift
- Test: Tests/VeltoTests/AnnotationRendererTests.swift（不提交）

- [ ] **Step 1: 写失败测试**

~~~swift
import CoreGraphics
import Testing
@testable import VeltoAnnotationCore

@Test func annotationRendererAppliesCropAtScale() throws {
  var document = AnnotationDocument(canvasSize: CGSize(width: 32, height: 32))
  document.cropRect = CGRect(x: 8, y: 8, width: 16, height: 12)
  let image = try AnnotationRenderer.render(
    baseImage: TestImage.solid(width: 64, height: 64),
    document: document, scale: 2
  ).get()
  #expect(image.width == 32)
  #expect(image.height == 24)
}

@Test func annotationMosaicRendersBelowVectorObjects() throws {
  var document = AnnotationDocument(canvasSize: CGSize(width: 32, height: 32))
  document.elements = [
    .arrow(SegmentAnnotation(
      start: CGPoint(x: 2, y: 2), end: CGPoint(x: 30, y: 30), style: .defaults
    )),
    .mosaic(MosaicAnnotation(
      rect: CGRect(x: 0, y: 0, width: 32, height: 32), blockSize: 8
    ))
  ]
  let image = try AnnotationRenderer.render(
    baseImage: TestImage.solid(width: 32, height: 32),
    document: document, scale: 1
  ).get()
  #expect(image.width == 32)
}
~~~

TestImage.solid 在测试文件内创建 RGBA8 CGContext 并返回纯色 CGImage。

- [ ] **Step 2: 运行并确认失败**

Run: swift test --filter annotation

Expected: FAIL，缺少 renderer 类型。

- [ ] **Step 3: 实现统一 renderer**

~~~swift
public enum AnnotationRenderError: Error, Equatable {
  case contextCreationFailed
  case imageCreationFailed
  case invalidCropRect
}

public enum AnnotationRenderer {
  public static func render(
    baseImage: CGImage, document: AnnotationDocument, scale: CGFloat
  ) -> Result<CGImage, AnnotationRenderError>

  public static func drawAnnotations(
    in context: CGContext, document: AnnotationDocument, scale: CGFloat
  )
}
~~~

render 固定顺序：

~~~swift
context.draw(baseImage, in: pixelCanvasRect)
for case .mosaic(let mosaic) in document.elements {
  AnnotationMosaicRenderer.draw(
    mosaic, baseImage: baseImage, scale: scale, in: context
  )
}
for element in document.elements {
  if case .mosaic = element { continue }
  drawVector(element, in: context, scale: scale)
}
return crop(context.makeImage(), to: document.cropRect, scale: scale)
~~~

矩形/椭圆绘制描边和填充；线/箭头共用 segment path；画笔/高亮使用 smoothedPath；文字用 Core Text；序号绘制圆形和居中数字。

- [ ] **Step 4: 实现矩形像素化**

AnnotationMosaicRenderer：

1. rect 乘 scale 并夹进底图 bounds。
2. 从不可变 baseImage 裁出区域。
3. 创建 max(1, region / blockSize) 的小位图并绘制裁片。
4. 关闭插值，把小位图放大绘回原区域。
5. 缓存键包含 base image identity、rect、blockSize 和 scale。
6. 不读取已经画入矢量标注的 context 内容。

- [ ] **Step 5: 验证并提交**

Run:

~~~bash
swift test --filter annotation
~~~

Expected: 全部 PASS。

~~~bash
git add Sources/VeltoAnnotationCore/AnnotationRenderer.swift \
  Sources/VeltoAnnotationCore/AnnotationMosaicRenderer.swift
git diff --cached --check
git commit -m "截图标注：统一预览导出渲染与马赛克"
~~~

---

### Task 6: 自绘图标和工具栏定位几何

**Files:**
- Create: Sources/VeltoAnnotationCore/AnnotationIconLibrary.swift
- Create: Sources/VeltoAnnotationCore/AnnotationToolbarLayout.swift
- Test: Tests/VeltoTests/AnnotationIconLayoutTests.swift（不提交）

- [ ] **Step 1: 写失败测试**

~~~swift
import CoreGraphics
import Testing
@testable import VeltoAnnotationCore

@Test func annotationAllSixteenIconsUseNormalizedBounds() {
  #expect(AnnotationIcon.allCases.count == 16)
  for icon in AnnotationIcon.allCases {
    let box = AnnotationIconLibrary.path(for: icon).boundingBoxOfPath
    #expect(box.minX >= 3 && box.maxX <= 21)
    #expect(box.minY >= 3 && box.maxY <= 21)
    #expect(abs(box.midX - 12) <= 0.5)
    #expect(abs(box.midY - 12) <= 0.5)
  }
}

@Test func annotationToolbarFlipsAboveAndClamps() {
  let placement = AnnotationToolbarLayout.place(
    selection: CGRect(x: 2, y: 2, width: 200, height: 100),
    screenBounds: CGRect(x: 0, y: 0, width: 500, height: 300),
    mainSize: CGSize(width: 460, height: 54),
    propertySize: CGSize(width: 260, height: 34)
  )
  #expect(placement.mainFrame.minX >= 0)
  #expect(placement.mainFrame.maxX <= 500)
  #expect(placement.mainFrame.minY > 102)
}
~~~

- [ ] **Step 2: 运行并确认失败**

Run: swift test --filter annotation

Expected: FAIL，缺少 icon/layout 类型。

- [ ] **Step 3: 实现 16 个路径**

~~~swift
public enum AnnotationIcon: CaseIterable, Sendable {
  case rectangle, ellipse, line, arrow, pen, mosaic, text, highlight, sequence, crop
  case undo, redo, cancel, save, copy, complete
}

public enum AnnotationIconLibrary {
  public static func path(for icon: AnnotationIcon) -> CGPath
}
~~~

path switch 在 24×24 坐标中构造：矩形、椭圆、斜线、折角箭头、笔尖、网格、T、高亮笔、圆形 1、裁剪角、左右回转箭头、X、下载箭头、两个错位圆角矩形、三点勾。路径不携带颜色和线宽。

- [ ] **Step 4: 实现位置计算**

~~~swift
public struct AnnotationToolbarPlacement: Equatable, Sendable {
  public var mainFrame: CGRect
  public var propertyFrame: CGRect
}

public enum AnnotationToolbarLayout {
  public static func place(
    selection: CGRect, screenBounds: CGRect,
    mainSize: CGSize, propertySize: CGSize,
    selectionGap: CGFloat = 10, barGap: CGFloat = 6
  ) -> AnnotationToolbarPlacement
}
~~~

默认放下方，整体放不下时翻上方；X 按最大宽度夹进 screenBounds，不压缩控件。

- [ ] **Step 5: 验证并提交**

Run: swift test --filter annotation

Expected: 2 tests PASS，16 个 path 通过 bounds 检查。

~~~bash
git add Sources/VeltoAnnotationCore/AnnotationIconLibrary.swift \
  Sources/VeltoAnnotationCore/AnnotationToolbarLayout.swift
git diff --cached --check
git commit -m "截图标注：加入统一矢量图标与工具栏布局"
~~~

---

### Task 7: Liquid Glass 主工具栏和属性条

**Files:**
- Create: Sources/Velto/Screenshot/Annotation/AnnotationToolbarView.swift
- Create: Sources/Velto/Screenshot/Annotation/AnnotationPropertyBarView.swift
- Test: Tests/VeltoTests/AnnotationToolbarSourceTests.swift（不提交）

- [ ] **Step 1: 写 UI 结构失败测试**

~~~swift
import Foundation
import Testing

@Test func annotationToolbarUsesCustomPathsAndFixedGeometry() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let src = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/Annotation/AnnotationToolbarView.swift"
  ), encoding: .utf8)
  #expect(src.contains("NSGlassEffectView"))
  #expect(src.contains("buttonSize: CGFloat = 36"))
  #expect(src.contains("AnnotationIconLibrary.path"))
  #expect(src.contains("setLineWidth(2)"))
  #expect(!src.contains("Image(systemName:"))
  #expect(!src.contains("title = \"×\""))
  #expect(!src.contains("title = \"✓\""))
}
~~~

- [ ] **Step 2: 运行并确认文件缺失失败**

Run: swift test --filter annotation

Expected: FAIL，无法读取 toolbar 文件。

- [ ] **Step 3: 实现主工具栏**

公开接口：

~~~swift
enum AnnotationToolbarAction {
  case selectTool(AnnotationTool?)
  case undo, redo, cancel, save, copy, complete
}

final class AnnotationToolbarView: NSGlassEffectView {
  static let buttonSize: CGFloat = 36
  var onAction: ((AnnotationToolbarAction) -> Void)?
  func update(activeTool: AnnotationTool?, canUndo: Bool, canRedo: Bool)
}
~~~

实现约束：

- style = .regular，圆角 18，高度 54。
- 水平 NSStackView；内边距 10、按钮间距 2、分组间距 4。
- 10 工具 + 2 history + 4 action，共 16 个 36×36 按钮。
- AnnotationIconView 固定 24×24，draw 使用 AnnotationIconLibrary.path、2pt、round cap/join。
- 选中工具背景 controlAccentColor，图标白色。
- cancel systemRed，complete systemGreen，普通 labelColor，禁用 disabledControlTextColor。
- hover/pressed/disabled 不改变 frame 或图标 scale。

- [ ] **Step 4: 实现属性条**

~~~swift
final class AnnotationPropertyBarView: NSGlassEffectView {
  var onStyleChange: ((AnnotationStyle) -> Void)?
  func update(tool: AnnotationTool?, style: AnnotationStyle, cropRect: CGRect)
}
~~~

固定映射：

- rectangle/ellipse：颜色、1/3/5 线宽、填充透明度。
- line/arrow/pen：颜色、1/3/5 线宽。
- mosaic：8/12/16/24 px。
- text：颜色、14/18/24/32pt、粗体、左中右。
- highlight：颜色、三档宽度、透明度。
- sequence：前景色、24/28/32 直径。
- crop：只读 W × H。

- [ ] **Step 5: 测试、编译并提交**

Run:

~~~bash
swift test --filter annotation
swift build -c release --arch arm64 --scratch-path .build --product Velto
~~~

Expected: PASS，Release build exit 0。

~~~bash
git add Sources/Velto/Screenshot/Annotation/AnnotationToolbarView.swift \
  Sources/Velto/Screenshot/Annotation/AnnotationPropertyBarView.swift
git diff --cached --check
git commit -m "截图标注：实现整齐的 Liquid Glass 工具栏"
~~~

---

### Task 8: 标注画布和原位文字编辑

**Files:**
- Create: Sources/Velto/Screenshot/Annotation/AnnotationCanvasView.swift
- Create: Sources/Velto/Screenshot/Annotation/AnnotationTextEditor.swift
- Test: Tests/VeltoTests/AnnotationCanvasSourceTests.swift（不提交）

- [ ] **Step 1: 写画布职责失败测试**

~~~swift
import Foundation
import Testing

@Test func annotationCanvasForwardsModifiersAndAvoidsClear() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let src = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/Annotation/AnnotationCanvasView.swift"
  ), encoding: .utf8)
  #expect(src.contains("AnnotationEditor"))
  #expect(src.contains("modifierFlags.contains(.shift)"))
  #expect(src.contains("modifierFlags.contains(.option)"))
  #expect(src.contains("setNeedsDisplay"))
  #expect(!src.contains("context.clear"))
  #expect(!src.contains("ctx.clear"))
}
~~~

- [ ] **Step 2: 运行并确认失败**

Run: swift test --filter annotation

Expected: FAIL，画布文件不存在。

- [ ] **Step 3: 实现画布桥接**

~~~swift
@MainActor
final class AnnotationCanvasView: NSView {
  var editor: AnnotationEditor
  var baseImage: CGImage
  var scale: CGFloat
  var onDocumentChange: ((AnnotationDocument) -> Void)?
  var onRequestCancelSession: (() -> Void)?
  var onBeginTextEditing: ((CGRect, TextAnnotation?) -> Void)?

  override var acceptsFirstResponder: Bool { true }
  override func mouseDown(with event: NSEvent)
  override func mouseDragged(with event: NSEvent)
  override func mouseUp(with event: NSEvent)
  override func keyDown(with event: NSEvent)
  override func rightMouseDown(with event: NSEvent)
  override func draw(_ dirtyRect: NSRect)
}
~~~

事件坐标转换到选区局部坐标；Shift/Option 映射 AnnotationModifiers。每次 editor 变化只让旧/新对象 bounds 加控制点 padding 成为脏区，不设置父 overlay 全屏 needsDisplay。

键盘顺序：文字编辑器优先；随后 Cmd-Z、Cmd-Shift-Z、Delete、方向键、Shift+方向键；Esc/右键走 editor 分层取消。

- [ ] **Step 4: 实现原位文字编辑器**

~~~swift
@MainActor
final class AnnotationTextEditor: NSView, NSTextViewDelegate {
  var onCommit: ((String, CGRect) -> Void)?
  var onCancel: (() -> Void)?
  func begin(text: String, frame: CGRect, style: AnnotationStyle, in parent: NSView)
  func commit()
  func cancel()
}
~~~

使用无边框 NSScrollView + NSTextView，透明背景；颜色、字号、粗体、对齐来自 style。空文本 commit 交 editor 丢弃；双击 text 用原内容和 frame 重开。

- [ ] **Step 5: 验证并提交**

Run:

~~~bash
swift test --filter annotation
swift build -c release --arch arm64 --scratch-path .build --product Velto
~~~

Expected: 全部 PASS，build exit 0。

~~~bash
git add Sources/Velto/Screenshot/Annotation/AnnotationCanvasView.swift \
  Sources/Velto/Screenshot/Annotation/AnnotationTextEditor.swift
git diff --cached --check
git commit -m "截图标注：加入可编辑画布与原位文字"
~~~

---

### Task 9: 接入覆盖层和单活动屏幕

**Files:**
- Modify: Sources/Velto/Screenshot/ScreenshotOverlayView.swift
- Modify: Sources/Velto/Screenshot/ScreenshotOverlayWindow.swift
- Modify: Sources/Velto/Screenshot/ScreenshotSession.swift
- Test: Tests/VeltoTests/AnnotationOverlayIntegrationTests.swift（不提交）

- [ ] **Step 1: 写集成失败测试**

~~~swift
import Foundation
import Testing

@Test func annotationOverlayHostsUIAndSessionLocksWindow() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let overlay = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScreenshotOverlayView.swift"
  ), encoding: .utf8)
  let session = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScreenshotSession.swift"
  ), encoding: .utf8)
  #expect(overlay.contains("AnnotationCanvasView"))
  #expect(overlay.contains("AnnotationToolbarView"))
  #expect(overlay.contains("AnnotationToolbarLayout.place"))
  #expect(session.contains("activeOverlay"))
  #expect(session.contains("setSelectionEnabled"))
}
~~~

- [ ] **Step 2: 运行并确认失败**

Run: swift test --filter annotation

Expected: FAIL。

- [ ] **Step 3: 扩展 delegate 和 window**

~~~swift
@MainActor
protocol ScreenshotOverlayDelegate: AnyObject {
  func overlayDidActivateSelection(_ overlay: ScreenshotOverlayView)
  func overlayDidCancel()
  func overlayDidRequest(
    _ action: ScreenshotSessionAction,
    globalRect: CGRect,
    document: AnnotationDocument?
  )
}
~~~

ScreenshotOverlayWindow 增加：

~~~swift
var screenshotOverlayView: ScreenshotOverlayView { overlayView }
func setSelectionEnabled(_ enabled: Bool) {
  overlayView.selectionEnabled = enabled
}
~~~

- [ ] **Step 4: 选区形成后挂载标注 UI**

有效 mouseUp 后按顺序：

1. overlayDidActivateSelection(self)。
2. 用选区大小建立 AnnotationEditor。
3. 从 snapshot 裁出选区 baseImage。
4. 添加 frame 等于选区的 AnnotationCanvasView。
5. 添加 AnnotationToolbarView 和 AnnotationPropertyBarView。
6. 用 AnnotationToolbarLayout.place 定位。
7. tool/style/history 变化同步三个视图。

document 为空时选区仍可缩放并重建画布；已有标注后普通手柄停止改变底图，裁剪只通过 crop 工具修改 cropRect。

- [ ] **Step 5: Session 锁定一个活动 overlay**

~~~swift
private weak var activeOverlay: ScreenshotOverlayView?

func overlayDidActivateSelection(_ overlay: ScreenshotOverlayView) {
  activeOverlay = overlay
  for window in windows {
    window.setSelectionEnabled(window.screenshotOverlayView === overlay)
  }
}
~~~

teardown 先调用 tearDownAnnotationUI，结束文字编辑、mosaic cache 和 history，再 dismiss。

- [ ] **Step 6: 验证并提交**

Run:

~~~bash
swift test --filter annotation
swift build -c release --arch arm64 --scratch-path .build --product Velto
~~~

Expected: PASS，build exit 0。

~~~bash
git add Sources/Velto/Screenshot/ScreenshotOverlayView.swift \
  Sources/Velto/Screenshot/ScreenshotOverlayWindow.swift \
  Sources/Velto/Screenshot/ScreenshotSession.swift
git diff --cached --check
git commit -m "截图标注：接入覆盖层与单屏会话状态"
~~~

---

### Task 10: 输出结果和失败保留

**Files:**
- Modify: Sources/Velto/Screenshot/ScreenshotImageWriter.swift
- Modify: Sources/Velto/Screenshot/ScreenshotSession.swift
- Test: Tests/VeltoTests/AnnotationOutputIntegrationTests.swift（不提交）

- [ ] **Step 1: 写失败测试**

~~~swift
import Foundation
import Testing

@Test func annotationOutputUsesExplicitResultsAndRenderer() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let writer = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScreenshotImageWriter.swift"
  ), encoding: .utf8)
  let session = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScreenshotSession.swift"
  ), encoding: .utf8)
  #expect(writer.contains("enum ScreenshotWriteError"))
  #expect(writer.contains("Result<URL, ScreenshotWriteError>"))
  #expect(session.contains("AnnotationRenderer.render"))
  #expect(session.contains("presentOutputFailure"))
}
~~~

- [ ] **Step 2: 运行并确认失败**

Run: swift test --filter annotation

Expected: FAIL。

- [ ] **Step 3: Writer 返回明确结果**

~~~swift
enum ScreenshotWriteError: Error {
  case encodingFailed
  case clipboardRejected
  case fileWriteFailed(String)
}

enum ScreenshotImageWriter {
  static func copyToClipboard(_ image: CGImage) -> Result<Void, ScreenshotWriteError>
  static func save(
    _ image: CGImage, toDirectory dir: String,
    format: ScreenshotImageFormat, alsoCopy: Bool
  ) -> Result<URL, ScreenshotWriteError>
}
~~~

copy 检查 NSPasteboard.setData 返回值；save 保留目录不可写时回退桌面，编码或写入失败返回 failure。

- [ ] **Step 4: Session 只在成功时 teardown**

输出顺序：裁原图 → 有 document 时 AnnotationRenderer.render → copy/save → success teardown。任何 failure 调 presentOutputFailure：记录 ScreenshotDebugLog、蜂鸣、工具栏附近显示 3 秒非阻塞提示，并保留 overlay、document、history。

- [ ] **Step 5: 验证并提交**

Run:

~~~bash
swift test --filter annotation
swift build -c release --arch arm64 --scratch-path .build --product Velto
~~~

Expected: PASS，build exit 0。

~~~bash
git add Sources/Velto/Screenshot/ScreenshotImageWriter.swift \
  Sources/Velto/Screenshot/ScreenshotSession.swift
git diff --cached --check
git commit -m "截图标注：统一合成输出并保留失败会话"
~~~

---

### Task 11: 标注偏好和设置页

**Files:**
- Modify: Sources/Velto/Screenshot/ScreenshotPreferences.swift
- Modify: Sources/Velto/Screenshot/ScreenshotPage.swift
- Test: Tests/VeltoTests/AnnotationPreferencesTests.swift（不提交）

- [ ] **Step 1: 写失败测试**

~~~swift
import Foundation
import Testing

@Test func annotationPreferencesDeclareDefaults() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let prefs = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScreenshotPreferences.swift"
  ), encoding: .utf8)
  for token in ["annotationColor", "annotationLineWidth", "annotationFontSize",
                "annotationHighlightOpacity", "annotationMosaicBlockSize",
                "annotationFillOpacity"] {
    #expect(prefs.contains(token))
  }
  let page = try String(contentsOf: root.appendingPathComponent(
    "Sources/Velto/Screenshot/ScreenshotPage.swift"
  ), encoding: .utf8)
  #expect(page.contains("标注默认样式"))
}
~~~

- [ ] **Step 2: 运行并确认失败**

Run: swift test --filter annotation

Expected: FAIL。

- [ ] **Step 3: 扩展 ScreenshotPreferences**

增加字段：

~~~swift
var annotationColor: AnnotationColor
var annotationLineWidth: CGFloat
var annotationFontSize: CGFloat
var annotationHighlightOpacity: CGFloat
var annotationMosaicBlockSize: Int
var annotationFillOpacity: CGFloat
~~~

memberwise init、defaults、init(from:) 全部接入。默认值为 .systemRed、3、18、0.35、12、0。每个字段用 decodeIfPresent 回退，旧 JSON 必须可读。

增加 annotationStyle 计算属性，把六个设置映射为 AnnotationStyle，其余字段使用 isBold false、alignment left、sequenceDiameter 28。

- [ ] **Step 4: 设置页加入标注默认样式**

在 magnifierSection 前加入 annotationSection：

- ColorPicker 默认颜色。
- 1/3/5 线宽 segmented。
- 14/18/24/32 字号 segmented。
- 0.15...0.65 高亮透明度 slider。
- 8/12/16/24 马赛克粒度 segmented。
- 0...1 填充透明度 slider。

写入全部走 updatePrefs，复用 GroupCard、row 和 MGSectionLabel。

- [ ] **Step 5: 验证并提交**

Run:

~~~bash
swift test --filter annotation
swift test --filter ScreenshotPreferences
swift build -c release --arch arm64 --scratch-path .build --product Velto
~~~

Expected: PASS，build exit 0。

~~~bash
git add Sources/Velto/Screenshot/ScreenshotPreferences.swift \
  Sources/Velto/Screenshot/ScreenshotPage.swift
git diff --cached --check
git commit -m "截图标注：增加默认样式配置"
~~~

---

### Task 12: 全量验证、实机验收和部署

**Files:**
- Verify: Tasks 1-11 全部生产文件
- Do not stage: Tests/
- Do not stage: .superpowers/

- [ ] **Step 1: 全量自动化测试**

Run: swift test

Expected: 0 failures；Annotation 测试和原测试全部 PASS。

- [ ] **Step 2: Release 编译**

Run: swift build -c release --arch arm64 --scratch-path .build --product Velto

Expected: Build complete，exit 0。

- [ ] **Step 3: 检查性能和图标约束**

Run:

~~~bash
rg -n "ctx\.clear|context\.clear|Image\(systemName:" \
  Sources/Velto/Screenshot/Annotation Sources/VeltoAnnotationCore
git diff --check
~~~

Expected: 标注画布没有 clear；工具栏没有 SF Symbol；diff check 无错误。

- [ ] **Step 4: 打包、结束旧进程、覆盖并启动**

Run:

~~~bash
CONFIGURATION=release SKIP_TCC_RESET=1 ./scripts/build-app.sh --run
~~~

Expected output 包含 /Applications/Velto.app、启动中、进程已启动 (pid: ...)。脚本内部执行 pkill、删除旧 app、cp -R 覆盖、签名和 open -a。

- [ ] **Step 5: 校验签名和进程**

Run:

~~~bash
codesign --verify --deep --strict /Applications/Velto.app
pgrep -fl '/Applications/Velto.app/Contents/MacOS/Velto'
~~~

Expected: codesign exit 0；存在新 Velto 进程。

- [ ] **Step 6: 实机验收**

1. 框选/选窗后原覆盖层显示主工具栏和属性条。
2. 16 按钮上下左右对齐，取消/完成视觉尺寸一致。
3. 十种工具均可创建。
4. 对象可再次选择、移动、缩放、改样式和删除。
5. Shift 横线 Y 不漂移、竖线 X 不漂移、45° 斜线稳定。
6. 22.5° 临界角附近小幅抖动时不来回切换。
7. Cmd-Z、Cmd-Shift-Z、Delete、方向键、Shift+方向键正确。
8. 文字可原位输入和双击编辑。
9. 马赛克只处理底图，不破坏箭头和文字。
10. 空格/完成复制退出；Cmd-S 保存退出；取消不输出。
11. 多屏只有一个活动选区。
12. 连续画笔/拖动无全屏卡顿、无点击穿透。

- [ ] **Step 7: 最终提交范围检查**

Run:

~~~bash
git status -sb
git log --oneline -15
git diff --name-only
git diff --cached --name-only
~~~

Expected: 没有未提交 Phase 2 生产文件；Tests/ 和 .superpowers/ 未暂存；不 push，除非用户另行要求。

---

## Completion Checklist

- [ ] 十种标注工具可用且对象可再次编辑。
- [ ] Shift 实时角度吸附通过逻辑测试和实机验证。
- [ ] 16 图标通过画布、中心、边界和笔宽校验。
- [ ] 预览和导出共用 renderer，Retina 结果一致。
- [ ] 撤销/重做覆盖新增、删除、移动、缩放、样式、文字和裁剪。
- [ ] 输出失败保留会话与标注。
- [ ] 无全屏重绘回归，无点击穿透。
- [ ] 测试、Release build、签名校验通过。
- [ ] 旧进程已结束，新包已覆盖 /Applications/Velto.app 并启动。
- [ ] commit 不包含测试文件。
