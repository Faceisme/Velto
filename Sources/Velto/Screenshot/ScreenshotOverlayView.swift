import AppKit

/// 截图覆盖层的核心交互视图。
/// 坐标模型:本视图保持默认**非 flipped(左下原点)**——下方所有 helper、draw、放大镜采样都依赖这一点,切勿加 isFlipped。
/// 视图局部点 ↔ AppKit 全局点:`global = local + globalFrame.origin`(y 同为左下原点)。
/// AppKit 全局点 ↔ CGWindowList 左上原点:绕主屏高度翻转(与 ScreenshotCapturer.cgFrameToNSFrame 同基准)。
final class ScreenshotOverlayView: NSView {
  weak var delegate: ScreenshotOverlayDelegate?
  var snapshotImage: CGImage? { didSet { needsDisplay = true } }
  var dimAlpha: CGFloat = 0.35

  /// 取色放大镜开关(由偏好驱动,默认开)。
  var showMagnifier: Bool = true
  /// 本窗口在全局点坐标(NSScreen.frame 语义,左下原点)中的 frame。
  var globalFrame: CGRect = .zero
  /// 快照像素相对点的缩放(backingScaleFactor)。
  var scale: CGFloat = 2.0

  /// 选区确认后传给 delegate 的全局 rect(AppKit 左下原点),供 Task 8 的 ScreenshotCapturer.crop 使用。
  var currentSelectionGlobal: CGRect? {
    guard let s = selection else { return nil }
    return CGRect(
      x: s.minX + globalFrame.minX, y: s.minY + globalFrame.minY,
      width: s.width, height: s.height
    )
  }

  // MARK: - 交互状态

  private enum Mode {
    case idle
    case dragging
    case dragHandle(ScreenshotHandle)
    case moving
  }

  private var mode: Mode = .idle
  /// 选区(视图局部点坐标,左下原点)。
  private var selection: CGRect?
  /// 拖拽起点 / 移动锚点(视图局部点)。
  private var dragOrigin: CGPoint = .zero
  /// 悬停窗口高亮区域(视图局部点坐标)。
  private var hoverWindowRectLocal: CGRect?
  /// 最近一次鼠标位置(视图局部点),供放大镜定位。
  private var lastMouseLocal: CGPoint?
  /// 选窗高亮的窗口列表查询较重,用时间戳限频。
  private var lastHoverQueryTime: TimeInterval = 0

  private let handleSize: CGFloat = 8
  /// 命中手柄的判定半径放大,便于点中。
  private var handleHitSize: CGFloat { handleSize * 2 }

  override var acceptsFirstResponder: Bool { true }
  /// agent 应用未激活时,首次点击默认仅用于“激活窗口”而被吞掉;返回 true 让首次点击即开始框选。
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

  // MARK: - 坐标换算 helper(本任务关键决策:不走 DisplayCoordinateConverter)

  /// 视图局部点 → AppKit 全局点(左下原点)。
  private func localToAppKitGlobal(_ p: CGPoint) -> CGPoint {
    CGPoint(x: p.x + globalFrame.minX, y: p.y + globalFrame.minY)
  }

  /// AppKit 全局点(左下原点)→ CGWindowList 左上原点点(原点在主屏左上)。
  private func appKitGlobalToTopLeft(_ p: CGPoint) -> CGPoint {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? bounds.height
    return CGPoint(x: p.x, y: primaryHeight - p.y)
  }

  /// CGWindowList 左上原点 rect → AppKit 全局 rect(左下原点)。
  private func topLeftRectToAppKitGlobal(_ r: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? bounds.height
    return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
  }

  /// AppKit 全局 rect(左下原点)→ 视图局部 rect。
  private func appKitGlobalRectToLocal(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX - globalFrame.minX, y: r.minY - globalFrame.minY, width: r.width, height: r.height)
  }

  // MARK: - 鼠标

  override func mouseDown(with event: NSEvent) {
    // 多屏:点哪块屏就把那块屏的覆盖窗口提为 key,保证后续空格/⌘S 键盘确认落到本 View。
    window?.makeKey()
    let p = convert(event.locationInWindow, from: nil)
    lastMouseLocal = p
    if let s = selection, let h = ScreenshotGeometry.handle(at: p, selection: s, handleSize: handleHitSize) {
      mode = .dragHandle(h)
    } else if let s = selection, s.contains(p) {
      mode = .moving
      dragOrigin = p
    } else {
      dragOrigin = p
      selection = CGRect(origin: p, size: .zero)
      mode = .dragging
    }
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    lastMouseLocal = p
    switch mode {
    case .dragging:
      selection = ScreenshotGeometry.clamp(
        ScreenshotGeometry.normalizedRect(from: dragOrigin, to: p), to: bounds)
    case .dragHandle(let h):
      if let s = selection {
        selection = ScreenshotGeometry.clamp(
          ScreenshotGeometry.resized(s, handle: h, to: p), to: bounds)
      }
    case .moving:
      if var s = selection {
        s.origin.x += p.x - dragOrigin.x
        s.origin.y += p.y - dragOrigin.y
        selection = ScreenshotGeometry.clamp(s, to: bounds)
        dragOrigin = p
      }
    case .idle:
      break
    }
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    // 单击未拖(尺寸≈0)且有悬停窗口 → 采纳整窗为选区。
    if case .dragging = mode, let s = selection, s.width < 3, s.height < 3, let w = hoverWindowRectLocal {
      selection = ScreenshotGeometry.clamp(w, to: bounds)
      hoverWindowRectLocal = nil
    }
    mode = .idle
    needsDisplay = true
  }

  override func rightMouseDown(with event: NSEvent) {
    // 右键退出截图(与 Esc 等价)。
    delegate?.overlayDidCancel()
  }

  override func mouseMoved(with event: NSEvent) {
    let local = convert(event.locationInWindow, from: nil)
    lastMouseLocal = local
    // 已有选区时不再做选窗高亮;但放大镜仍随光标刷新。
    guard selection == nil else {
      hoverWindowRectLocal = nil
      needsDisplay = true
      return
    }
    // 窗口列表查询较重,限频 ~20Hz;两次查询之间沿用上次高亮结果。
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastHoverQueryTime >= 0.05 {
      lastHoverQueryTime = now
      let topLeft = appKitGlobalToTopLeft(localToAppKitGlobal(local))
      if let g = WindowFrameDetector.windowFrame(
        atGlobalPoint: topLeft,
        excludingPID: ProcessInfo.processInfo.processIdentifier
      ) {
        hoverWindowRectLocal = appKitGlobalRectToLocal(topLeftRectToAppKitGlobal(g))
      } else {
        hoverWindowRectLocal = nil
      }
    }
    needsDisplay = true
  }

  // MARK: - 键盘

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 53:                                                   // Esc
      delegate?.overlayDidCancel()
    case 49:                                                   // 空格 = 复制
      confirm(.copy)
    case 36:                                                   // Enter = 默认动作(复制)
      confirm(.copy)
    case 1 where event.modifierFlags.contains(.command):       // ⌘S = 保存
      confirm(.save)
    case 1:                                                     // S = 滚动(Task 8 占位)
      confirm(.scroll)
    default:
      super.keyDown(with: event)
    }
  }

  private func confirm(_ action: ScreenshotSessionAction) {
    guard let g = currentSelectionGlobal, g.width > 1, g.height > 1 else { return }
    delegate?.overlayDidRequest(action, globalRect: g)
  }

  // MARK: - 绘制

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    // 快照由下层 ScreenshotSnapshotBackgroundView 静态绘制(只画一次、GPU 合成)。
    // 本层每帧只:铺半透明暗罩 → 把选区/悬停区 clear 成透明露出下层亮快照 → 画选框/手柄/放大镜。
    // 关键性能点:不再每帧重绘全屏快照(那是拖拽卡顿的根因),只做一次暗罩填充。
    ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
    ctx.fill(bounds)
    if let bright = (selection ?? hoverWindowRectLocal)?.intersection(bounds),
       !bright.isNull, bright.width > 0, bright.height > 0 {
      ctx.clear(bright)
    }

    if let s = selection {
      drawSelectionBorder(s, ctx: ctx)
      drawHandles(for: s, ctx: ctx)
      drawSizeLabel(for: s, ctx: ctx)
    } else if let hover = hoverWindowRectLocal {
      drawHoverBorder(hover, ctx: ctx)
    }

    if showMagnifier, let p = lastMouseLocal {
      drawMagnifier(at: p, ctx: ctx)
    }
  }

  private func drawSelectionBorder(_ s: CGRect, ctx: CGContext) {
    ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
    ctx.setLineWidth(1)
    ctx.stroke(s.insetBy(dx: 0.5, dy: 0.5))
  }

  private func drawHoverBorder(_ r: CGRect, ctx: CGContext) {
    ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
    ctx.setLineWidth(1)
    ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
  }

  private func drawHandles(for s: CGRect, ctx: CGContext) {
    let rects = ScreenshotGeometry.handleRects(for: s, handleSize: handleSize)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
    ctx.setLineWidth(1)
    for handle in ScreenshotHandle.allCases {
      guard let r = rects[handle] else { continue }
      ctx.fill(r)
      ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
    }
  }

  /// 选区上方小标签 `W×H`(深底白字);贴近顶边时改放下方,再不行放内部。
  private func drawSizeLabel(for s: CGRect, ctx: CGContext) {
    let text = "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))"
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .medium),
      .foregroundColor: NSColor.white
    ]
    let textSize = (text as NSString).size(withAttributes: attrs)
    let padX: CGFloat = 6, padY: CGFloat = 3
    let labelSize = CGSize(width: textSize.width + padX * 2, height: textSize.height + padY * 2)
    let gap: CGFloat = 4

    // 左下原点:选区上方 = y 更大方向。
    var labelOrigin = CGPoint(x: s.minX, y: s.maxY + gap)
    if labelOrigin.y + labelSize.height > bounds.maxY {
      // 顶部放不下 → 放选区下方。
      labelOrigin.y = s.minY - gap - labelSize.height
    }
    if labelOrigin.y < bounds.minY {
      // 下方也放不下 → 放选区内顶部。
      labelOrigin.y = s.maxY - gap - labelSize.height
    }
    labelOrigin.x = min(max(labelOrigin.x, bounds.minX), bounds.maxX - labelSize.width)

    let labelRect = CGRect(origin: labelOrigin, size: labelSize)
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
    fillRoundedRect(labelRect, radius: 3, ctx: ctx)

    let textRect = CGRect(
      x: labelRect.minX + padX, y: labelRect.minY + padY,
      width: textSize.width, height: textSize.height
    )
    drawText(text as NSString, in: textRect, attrs: attrs)
  }

  // MARK: - 放大镜

  /// 在光标旁画放大镜:裁光标周围 NxN 像素放大 + 中心十字 + 坐标(+ 尽量给中心像素 HEX)。
  private func drawMagnifier(at local: CGPoint, ctx: CGContext) {
    guard let img = snapshotImage else { return }

    let sampleCount = 15          // 采样像素边长(NxN)
    let boxSize: CGFloat = 120    // 放大镜方框边长(点)
    let cellSize = boxSize / CGFloat(sampleCount)

    // 光标点 → 快照像素坐标(快照像素是左上原点、scale 倍)。
    // 视图局部左下原点:像素 x = local.x * scale;像素 y(自顶)= imageHeight - local.y * scale。
    let pxX = local.x * scale
    let pxYFromTop = CGFloat(img.height) - local.y * scale
    let half = CGFloat(sampleCount) / 2
    let cropTopLeft = CGRect(
      x: pxX - half, y: pxYFromTop - half,
      width: CGFloat(sampleCount), height: CGFloat(sampleCount)
    )
    let cropped = img.cropping(to: cropTopLeft.integral)

    // 放大镜方框位置:光标右上偏移;越界则翻到对侧。
    let offset: CGFloat = 16
    var boxOrigin = CGPoint(x: local.x + offset, y: local.y + offset)
    if boxOrigin.x + boxSize > bounds.maxX { boxOrigin.x = local.x - offset - boxSize }
    if boxOrigin.y + boxSize > bounds.maxY { boxOrigin.y = local.y - offset - boxSize }
    boxOrigin.x = min(max(boxOrigin.x, bounds.minX), bounds.maxX - boxSize)
    boxOrigin.y = min(max(boxOrigin.y, bounds.minY), bounds.maxY - boxSize)
    let box = CGRect(origin: boxOrigin, size: CGSize(width: boxSize, height: boxSize))

    ctx.saveGState()
    // 背板。
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
    ctx.fill(box)
    // 放大像素:cropped 是左上原点,view 是左下原点,绘制时 Y 翻转一次。
    ctx.clip(to: box)
    if let cropped {
      ctx.interpolationQuality = .none
      ctx.saveGState()
      ctx.translateBy(x: box.minX, y: box.maxY)
      ctx.scaleBy(x: 1, y: -1)
      ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: boxSize, height: boxSize))
      ctx.restoreGState()
    }
    ctx.restoreGState()

    // 边框。
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
    ctx.setLineWidth(1)
    ctx.stroke(box.insetBy(dx: 0.5, dy: 0.5))

    // 中心十字(高亮中心像素那一格)。
    let center = CGPoint(x: box.midX, y: box.midY)
    let cell = CGRect(
      x: center.x - cellSize / 2, y: center.y - cellSize / 2,
      width: cellSize, height: cellSize
    )
    ctx.setStrokeColor(NSColor.systemRed.cgColor)
    ctx.setLineWidth(1)
    ctx.stroke(cell)

    // 坐标 + 中心像素 HEX 标签(放大镜下方)。
    let coordText = "\(Int(local.x.rounded())), \(Int(local.y.rounded()))"
    var infoText = coordText
    if let hex = centerPixelHex(of: img, atPixelX: Int(pxX.rounded()), pixelYFromTop: Int(pxYFromTop.rounded())) {
      infoText += "  \(hex)"
    }
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
      .foregroundColor: NSColor.white
    ]
    let textSize = (infoText as NSString).size(withAttributes: attrs)
    let labelRect = CGRect(
      x: box.minX, y: box.minY - 2 - textSize.height,
      width: max(textSize.width + 8, box.width), height: textSize.height + 4
    )
    if labelRect.minY >= bounds.minY {
      ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
      ctx.fill(labelRect)
      let textRect = CGRect(
        x: labelRect.minX + 4, y: labelRect.minY + 2,
        width: textSize.width, height: textSize.height
      )
      drawText(infoText as NSString, in: textRect, attrs: attrs)
    }
  }

  /// 读取快照单像素的 HEX 颜色字符串(#RRGGBB)。
  /// 做法稳健:把该像素绘制进 1×1 的 RGBA8 上下文再读 buffer,避开直接解析任意 CGImage 的 bitmap 布局。
  private func centerPixelHex(of img: CGImage, atPixelX x: Int, pixelYFromTop y: Int) -> String? {
    guard x >= 0, y >= 0, x < img.width, y < img.height else { return nil }
    guard let single = img.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
      data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: colorSpace, bitmapInfo: bitmapInfo
    ) else { return nil }
    context.draw(single, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
  }

  // MARK: - 绘制小工具

  private func fillRoundedRect(_ rect: CGRect, radius: CGFloat, ctx: CGContext) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.fillPath()
  }

  /// 用 NSAttributedString 在非 flipped 上下文里绘字。
  private func drawText(_ text: NSString, in rect: CGRect, attrs: [NSAttributedString.Key: Any]) {
    NSGraphicsContext.saveGraphicsState()
    text.draw(in: rect, withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
  }
}
