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
  /// 通知覆盖层开始原位文字编辑:frame 为标注坐标矩形,existing 为双击重开的对象。
  var onBeginTextEditing: ((CGRect, TextAnnotation?) -> Void)?

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
    window?.makeFirstResponder(self)
    let point = annotationPoint(for: event)

    if event.clickCount == 2,
       let id = AnnotationGeometry.hitTest(point, elements: editor.document.elements),
       case .text(let text)? = editor.document.elements.first(where: { $0.id == id }) {
      startTextEditing(annotationFrame: text.rect, existing: text)
      return
    }

    if editor.document.activeTool == .text {
      let height = max(editor.style.fontSize * 1.6, 28)
      let frame = CGRect(x: point.x, y: point.y, width: Self.defaultTextWidth, height: height)
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
    var dirty = CGRect.null
    let beforeByID = Dictionary(before.elements.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
    let afterByID = Dictionary(after.elements.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })

    for id in Set(beforeByID.keys).union(afterByID.keys) {
      let old = beforeByID[id]
      let new = afterByID[id]
      guard old != new else { continue }
      if let old { dirty = dirty.union(AnnotationGeometry.bounds(of: old)) }
      if let new { dirty = dirty.union(AnnotationGeometry.bounds(of: new)) }
    }

    if before.selectedElementID != after.selectedElementID {
      if let id = before.selectedElementID, let element = beforeByID[id] {
        dirty = dirty.union(AnnotationGeometry.bounds(of: element))
      }
      if let id = after.selectedElementID, let element = afterByID[id] {
        dirty = dirty.union(AnnotationGeometry.bounds(of: element))
      }
    }

    guard !dirty.isNull else { return }
    let viewDirty = viewRect(forAnnotation: dirty)
      .insetBy(dx: -Self.handlePadding, dy: -Self.handlePadding)
    setNeedsDisplay(viewDirty)
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
    context.draw(baseImage, in: CGRect(origin: .zero, size: bounds.size))

    for case .mosaic(let mosaic) in document.elements {
      AnnotationMosaicRenderer.draw(mosaic, baseImage: baseImage, scale: scale, in: context)
    }
    AnnotationRenderer.drawAnnotations(in: context, document: document, scale: scale)
    drawSelectionChrome(in: context)
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
