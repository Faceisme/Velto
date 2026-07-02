import AppKit
import VeltoAnnotationCore

/// 标注画布:既把鼠标/键盘事件桥接到 `AnnotationEditor`,又用与导出完全相同的
/// `AnnotationRenderer` 管线绘制底图 + 马赛克 + 矢量对象 + 选中控制点,保证所见即所得。
///
/// 坐标:视图本身保持默认 y-up,绘制时套用与渲染器一致的翻转 CTM;事件坐标统一换算到
/// 选区局部(左上原点、y 向下)的标注坐标。每次编辑只把受影响对象的 bounds(含控制点
/// padding)标脏,绝不让父覆盖层整屏重绘,也绝不挖透明洞(那会导致点击穿透)。
@MainActor
final class AnnotationCanvasView: NSView {
  var editor: AnnotationEditor
  var baseImage: CGImage
  /// 底图像素 / 视图点 的比例,供马赛克把标注点映射回底图像素。
  var scale: CGFloat

  var onDocumentChange: ((AnnotationDocument) -> Void)?
  var onRequestCancelSession: (() -> Void)?
  /// 选择模式下双击空白请求完成截图(复制并退出),与 Xnip 一致。
  var onRequestComplete: (() -> Void)?
  /// 通知覆盖层开始原位文字编辑:frame 为标注坐标矩形,existing 为双击重开的对象。
  var onBeginTextEditing: ((CGRect, TextAnnotation?) -> Void)?
  /// 请求覆盖层取消正在进行的文字编辑;返回 true 表示当时确有编辑器并已取消(此次点击被消费)。
  var onRequestCancelTextEditing: (() -> Bool)?
  /// 查询当前是否有进行中的文字编辑器(用于"编辑中单击空白=取消"判定,不产生副作用)。
  var isTextEditing: (() -> Bool)?

  /// 正在被外部文字编辑器接管的对象;绘制时跳过它,避免与透明 NSTextView 重影。
  private var editingTextID: UUID?
  private var isTrackingPointer = false

  private static let handlePadding: CGFloat = 12
  private static let defaultTextWidth: CGFloat = 160

  init(editor: AnnotationEditor, baseImage: CGImage, scale: CGFloat) {
    self.editor = editor
    self.baseImage = baseImage
    self.scale = scale
    super.init(frame: NSRect(origin: .zero, size: editor.document.canvasSize))
    wantsLayer = true
  }

  required init?(coder: NSCoder) {
    fatalError("not implemented")
  }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var isFlipped: Bool { false }

  // MARK: - Coordinate conversion

  /// 标注矩形(左上原点)→ 视图矩形(y-up)。供覆盖层定位文字编辑器等子视图。
  func viewRect(forAnnotation rect: CGRect) -> CGRect {
    let standardized = rect.standardized
    return CGRect(
      x: standardized.minX,
      y: bounds.height - standardized.maxY,
      width: standardized.width,
      height: standardized.height
    )
  }

  /// 视图矩形(y-up)→ 标注矩形(左上原点)。两者互为逆变换。
  func annotationRect(forView rect: CGRect) -> CGRect {
    let standardized = rect.standardized
    return CGRect(
      x: standardized.minX,
      y: bounds.height - standardized.maxY,
      width: standardized.width,
      height: standardized.height
    )
  }

  private func annotationPoint(for event: NSEvent) -> CGPoint {
    let view = convert(event.locationInWindow, from: nil)
    return CGPoint(x: view.x, y: bounds.height - view.y)
  }

  private func modifiers(for event: NSEvent) -> AnnotationModifiers {
    var result: AnnotationModifiers = []
    if event.modifierFlags.contains(.shift) { result.insert(.shift) }
    if event.modifierFlags.contains(.option) { result.insert(.option) }
    return result
  }

  // MARK: - Pointer events

  override func mouseDown(with event: NSEvent) {
    // 正在编辑文字时:落在编辑框内的单击会被文字框自身吃掉、根本到不了这里;凡是到达画布的
    // 单击都在框外 → 取消当前输入(不提交、不开新框、不退出截图)。
    if isTextEditing?() == true {
      _ = onRequestCancelTextEditing?()
      return
    }

    let point = annotationPoint(for: event)
    window?.makeFirstResponder(self)

    if event.clickCount == 2 {
      let hitID = AnnotationGeometry.hitTest(point, elements: editor.document.elements)
      if let id = hitID,
         case .text(let text)? = editor.document.elements.first(where: { $0.id == id }) {
        startTextEditing(annotationFrame: text.rect, existing: text)
        return
      }
      // 选择模式(无活动工具)下双击空白处 = 完成截图并复制退出。
      if editor.document.activeTool == nil, hitID == nil {
        onRequestComplete?()
        return
      }
    }

    if editor.document.activeTool == .text {
      // 先把按下交给编辑器:命中已有对象会进入移动/缩放手势,这样文字框(及任意图形)即便在
      // 文字工具下也能直接挪动;只有按在空白处(无手势)才新建一个文字框。
      applyChange { $0.pointerDown(at: point, modifiers: self.modifiers(for: event)) }
      if editor.hasActiveGesture {
        isTrackingPointer = true
        return
      }
      // 指哪打哪:点击点落在首行的垂直中心、左边缘对齐点击 x,光标就出现在你点的位置,而不是
      // 把整框甩到点击点的右下角。行高用与编辑器一致的字体 boundingRect;+4 对应编辑器
      // textContainerInset 上下各 2。
      let font = NSFont.systemFont(
        ofSize: editor.style.fontSize,
        weight: editor.style.isBold ? .bold : .regular
      )
      let height = ceil(font.boundingRectForFont.height) + 4
      let frame = CGRect(
        x: point.x,
        y: point.y - height / 2,
        width: Self.defaultTextWidth,
        height: height
      )
      startTextEditing(annotationFrame: frame, existing: nil)
      return
    }

    isTrackingPointer = true
    applyChange { $0.pointerDown(at: point, modifiers: self.modifiers(for: event)) }
  }

  override func mouseDragged(with event: NSEvent) {
    guard isTrackingPointer else { return }
    let point = annotationPoint(for: event)
    applyChange { $0.pointerDragged(to: point, modifiers: self.modifiers(for: event)) }
  }

  override func mouseUp(with event: NSEvent) {
    guard isTrackingPointer else { return }
    isTrackingPointer = false
    let point = annotationPoint(for: event)
    applyChange { $0.pointerUp(at: point, modifiers: self.modifiers(for: event)) }
  }

  override func rightMouseDown(with event: NSEvent) {
    cancelLayer()
  }

  // MARK: - Keyboard

  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags

    if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
      if flags.contains(.shift) {
        applyChange { $0.redo() }
      } else {
        applyChange { $0.undo() }
      }
      return
    }

    switch event.keyCode {
    case 51, 117: // delete / forward delete
      applyChange { $0.deleteSelection() }
    case 53: // escape
      cancelLayer()
    case 123: // left
      nudge(dx: -1, dy: 0, accelerated: flags.contains(.shift))
    case 124: // right
      nudge(dx: 1, dy: 0, accelerated: flags.contains(.shift))
    case 125: // down (annotation y increases downward)
      nudge(dx: 0, dy: 1, accelerated: flags.contains(.shift))
    case 126: // up
      nudge(dx: 0, dy: -1, accelerated: flags.contains(.shift))
    default:
      super.keyDown(with: event)
    }
  }

  private func nudge(dx: CGFloat, dy: CGFloat, accelerated: Bool) {
    applyChange { $0.nudge(dx: dx, dy: dy, accelerated: accelerated) }
  }

  private func cancelLayer() {
    let before = editor.document
    let result = editor.cancelCurrentLayer()
    invalidate(before: before, after: editor.document)
    onDocumentChange?(editor.document)
    if result == .cancelSession {
      onRequestCancelSession?()
    }
  }

  // MARK: - Menu actions (responder chain)

  /// 主菜单 撤销/重做(⌘Z / ⌘⇧Z)是 `undo:`/`redo:` 这类响应链动作,会先于 keyDown 被
  /// 派发。画布是第一响应者时必须自己接住它们、走标注历史栈;否则会落到窗口的
  /// NSUndoManager(残留文字编辑器的悬垂注册)而崩溃。文字编辑时第一响应者是 NSTextView,
  /// 撤销自然落到它的专属管理器,不会进到这里。
  @objc func undo(_ sender: Any?) {
    applyChange { $0.undo() }
  }

  @objc func redo(_ sender: Any?) {
    applyChange { $0.redo() }
  }

  // MARK: - Text editing bridge

  private func startTextEditing(annotationFrame: CGRect, existing: TextAnnotation?) {
    if let existing {
      editingTextID = existing.id
      _ = editor.beginEditingText(elementID: existing.id)
    } else {
      editingTextID = nil
    }
    needsDisplay = true
    onBeginTextEditing?(annotationFrame, existing)
  }

  /// 覆盖层在文字编辑器提交时调用,annotationRect 为编辑框换算回的标注坐标。
  func commitTextEditing(_ text: String, annotationRect: CGRect) {
    let before = editor.document
    editor.commitText(text, rect: annotationRect)
    editingTextID = nil
    invalidate(before: before, after: editor.document)
    needsDisplay = true
    onDocumentChange?(editor.document)
  }

  /// 覆盖层在文字编辑取消时调用:新文字直接丢弃,既有文字还原为原值。
  func cancelTextEditing() {
    if let id = editingTextID,
       case .text(let original)? = editor.document.elements.first(where: { $0.id == id }) {
      let before = editor.document
      editor.commitText(original.text, rect: original.rect)
      invalidate(before: before, after: editor.document)
    }
    editingTextID = nil
    needsDisplay = true
    onDocumentChange?(editor.document)
  }

  // MARK: - Mutation plumbing

  private func applyChange(_ mutate: (inout AnnotationEditor) -> Void) {
    let before = editor.document
    mutate(&editor)
    invalidate(before: before, after: editor.document)
    onDocumentChange?(editor.document)
  }

  /// 仅把发生变化的对象(旧值 ∪ 新值)外扩控制点 padding 标脏,不触碰父覆盖层。
  private func invalidate(before: AnnotationDocument, after: AnnotationDocument) {
    // 裁剪框变化会改变整个画布的压暗罩,直接整画布重绘(仅裁剪拖拽期间发生)。
    if before.cropRect != after.cropRect {
      needsDisplay = true
      return
    }

    var dirty = CGRect.null
    let beforeByID = Dictionary(before.elements.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
    let afterByID = Dictionary(after.elements.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })

    for id in Set(beforeByID.keys).union(afterByID.keys) {
      let old = beforeByID[id]
      let new = afterByID[id]
      guard old != new else { continue }
      if let old { dirty = dirty.union(renderBounds(of: old)) }
      if let new { dirty = dirty.union(renderBounds(of: new)) }
    }

    if before.selectedElementID != after.selectedElementID {
      if let id = before.selectedElementID, let element = beforeByID[id] {
        dirty = dirty.union(renderBounds(of: element))
      }
      if let id = after.selectedElementID, let element = afterByID[id] {
        dirty = dirty.union(renderBounds(of: element))
      }
    }

    guard !dirty.isNull else { return }
    let viewDirty = viewRect(forAnnotation: dirty)
      .insetBy(dx: -Self.handlePadding, dy: -Self.handlePadding)
    setNeedsDisplay(viewDirty)
  }

  /// 元素的**渲染**包围盒:几何 bounds 只含锚点/点集,不含描边宽度。荧光笔描边宽达
  /// lineWidth×3、箭头有外扩箭翼,只按几何 bounds 标脏会在两侧留下未重绘的残迹(拖动重影)。
  private func renderBounds(of element: AnnotationElement) -> CGRect {
    let bounds = AnnotationGeometry.bounds(of: element)
    let inflation: CGFloat
    switch element {
    case .highlight(let value):
      inflation = max(value.style.lineWidth * 3, 8) / 2 + 4
    case .freehand(let value):
      inflation = value.style.lineWidth / 2 + 4
    case .line(let value), .arrow(let value):
      inflation = max(10, value.style.lineWidth * 3.5)
    case .rectangle(let value), .ellipse(let value):
      inflation = value.style.lineWidth / 2 + 1
    default:
      inflation = 1
    }
    return bounds.insetBy(dx: -inflation, dy: -inflation)
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let document = documentForDrawing

    context.saveGState()
    // 与 AnnotationRenderer.render 完全一致的翻转:标注左上坐标映射进 y-up 视图。
    context.translateBy(x: 0, y: bounds.height)
    context.scaleBy(x: 1, y: -1)
    context.interpolationQuality = .high
    // 底图是正立(左上原点)位图,在 y-down 标注 CTM 下直接 draw 会上下颠倒,
    // 故只为底图再翻正一次;马赛克与矢量保持 y-down(标注坐标)。
    context.saveGState()
    context.translateBy(x: 0, y: bounds.height)
    context.scaleBy(x: 1, y: -1)
    context.draw(baseImage, in: CGRect(origin: .zero, size: bounds.size))
    context.restoreGState()

    for case .mosaic(let mosaic) in document.elements {
      AnnotationMosaicRenderer.draw(mosaic, baseImage: baseImage, scale: scale, in: context)
    }
    AnnotationRenderer.drawAnnotations(in: context, document: document, scale: scale)
    drawSelectionChrome(in: context)
    drawCropChrome(in: context)
    context.restoreGState()
  }

  /// 裁剪预览:裁剪框外压暗 + accent 边框。导出时 AnnotationRenderer 会按 cropRect 真裁,
  /// 这里让"拖出裁剪框"当场可见(此前拖完全无反馈,工具形同虚设)。
  private func drawCropChrome(in context: CGContext) {
    let canvasRect = CGRect(origin: .zero, size: editor.document.canvasSize)
    let crop = editor.document.cropRect.standardized.intersection(canvasRect)
    guard !crop.isNull, crop != canvasRect else { return }

    context.saveGState()
    context.addRect(canvasRect)
    context.addRect(crop)
    context.clip(using: .evenOdd)
    context.setFillColor(CGColor(gray: 0, alpha: 0.45))
    context.fill(canvasRect)
    context.restoreGState()

    context.saveGState()
    context.setStrokeColor(NSColor.controlAccentColor.cgColor)
    context.setLineWidth(2)
    context.stroke(crop.insetBy(dx: 1, dy: 1))
    context.restoreGState()
  }

  private var documentForDrawing: AnnotationDocument {
    guard let editingTextID else { return editor.document }
    var document = editor.document
    document.elements.removeAll { $0.id == editingTextID }
    return document
  }

  private func drawSelectionChrome(in context: CGContext) {
    guard let id = editor.document.selectedElementID, id != editingTextID,
          let element = editor.document.elements.first(where: { $0.id == id }) else {
      return
    }
    let accent = NSColor.controlAccentColor
    context.saveGState()
    context.setShouldAntialias(true)

    let outline = AnnotationGeometry.bounds(of: element).insetBy(dx: -2, dy: -2)
    context.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
    context.setLineWidth(1)
    context.stroke(outline)

    for anchor in handleAnchors(for: element) {
      let dot = CGRect(x: anchor.x - 3.5, y: anchor.y - 3.5, width: 7, height: 7)
      context.setFillColor(NSColor.white.cgColor)
      context.fillEllipse(in: dot)
      context.setStrokeColor(accent.cgColor)
      context.setLineWidth(1)
      context.strokeEllipse(in: dot)
    }
    context.restoreGState()
  }

  private func handleAnchors(for element: AnnotationElement) -> [CGPoint] {
    switch element {
    case .line(let value), .arrow(let value):
      return [value.start, value.end]
    default:
      let box = AnnotationGeometry.bounds(of: element)
      return [
        CGPoint(x: box.minX, y: box.minY),
        CGPoint(x: box.midX, y: box.minY),
        CGPoint(x: box.maxX, y: box.minY),
        CGPoint(x: box.maxX, y: box.midY),
        CGPoint(x: box.maxX, y: box.maxY),
        CGPoint(x: box.midX, y: box.maxY),
        CGPoint(x: box.minX, y: box.maxY),
        CGPoint(x: box.minX, y: box.midY),
      ]
    }
  }
}
