import AppKit

/// 滚动截图期间骑在选区底边中央的下拽手柄:滚到底发现还差一点没框进来时,
/// 把底边往下拖,松手后由会话把新露出的条带追加进长图。
/// 与操作条同为非激活浮窗,不改变目标 App 前台状态,只有手柄本身接收鼠标;
/// 属于本进程窗口,SCScreenshotManager 按 PID 排除,不会进拼接结果。
@MainActor
final class ScrollCaptureEdgeHandle: NSPanel {
  /// 拖动中实时回调(供边框预览),松手回调提交;delta 单位为点,≥0 表示向下扩展。
  var onPreview: ((CGFloat) -> Void)?
  var onCommit: ((CGFloat) -> Void)?

  static let handleSize = CGSize(width: 64, height: 20)
  private let screenMinY: CGFloat
  private var selectionBottom: CGFloat
  private var dragStartMouseY: CGFloat = 0
  private var dragStartBottom: CGFloat = 0

  init(selectionRect: CGRect, screenFrame: CGRect) {
    screenMinY = screenFrame.minY
    selectionBottom = selectionRect.minY
    super.init(
      contentRect: Self.frame(for: selectionRect),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isOpaque = false
    backgroundColor = .clear
    level = .screenSaver
    hasShadow = true
    hidesOnDeactivate = false
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    let view = EdgeHandleView(frame: CGRect(origin: .zero, size: Self.handleSize))
    view.toolTip = "向下拖动,把选区下方没框进来的内容补进长图"
    contentView = view
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// 手柄横向居中骑在底边上(一半在选区内、一半在外)。
  static func frame(for selection: CGRect) -> CGRect {
    CGRect(
      x: selection.midX - handleSize.width / 2,
      y: selection.minY - handleSize.height / 2,
      width: handleSize.width,
      height: handleSize.height
    )
  }

  /// 提交结果落定后由会话调用:按最终选区归位并更新底边基准。
  func position(selectionRect: CGRect) {
    selectionBottom = selectionRect.minY
    setFrame(Self.frame(for: selectionRect), display: true)
  }

  // MARK: - 拖拽(手柄内容简单,事件直接落到窗口的 responder 链上)

  override func mouseDown(with event: NSEvent) {
    dragStartMouseY = NSEvent.mouseLocation.y
    dragStartBottom = selectionBottom
  }

  override func mouseDragged(with event: NSEvent) {
    let delta = clampedDragDelta()
    setFrameOrigin(CGPoint(
      x: frame.minX,
      y: dragStartBottom - delta - Self.handleSize.height / 2
    ))
    onPreview?(delta)
  }

  override func mouseUp(with event: NSEvent) {
    onCommit?(clampedDragDelta())
  }

  /// 只允许向下(不许缩小已捕获内容),且不出屏底;取整保证像素对齐。
  private func clampedDragDelta() -> CGFloat {
    let raw = (dragStartMouseY - NSEvent.mouseLocation.y).rounded()
    return min(max(0, raw), dragStartBottom - screenMinY)
  }
}

/// 手柄外观:强调色圆角药丸 + 白色下箭头,与选区边框同色系。
private final class EdgeHandleView: NSView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .resizeDown)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let pill = bounds.insetBy(dx: 1, dy: 1)
    let path = CGPath(
      roundedRect: pill,
      cornerWidth: pill.height / 2,
      cornerHeight: pill.height / 2,
      transform: nil
    )
    ctx.addPath(path)
    ctx.setFillColor(NSColor.controlAccentColor.cgColor)
    ctx.fillPath()

    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(2)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: bounds.midX - 6, y: bounds.midY + 2.5))
    ctx.addLine(to: CGPoint(x: bounds.midX, y: bounds.midY - 2.5))
    ctx.addLine(to: CGPoint(x: bounds.midX + 6, y: bounds.midY + 2.5))
    ctx.strokePath()
  }
}
