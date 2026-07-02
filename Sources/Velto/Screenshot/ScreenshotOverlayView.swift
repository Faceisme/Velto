import AppKit
import VeltoAnnotationCore

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
  /// 触发截图时的前台 app PID:窗口自动识别只认它的窗口,忽略后台窗口(0=未知,退化为光标下窗口)。
  var activeAppPID: pid_t = 0

  /// 会话内按键(由偏好注入,替代写死的 keyCode);与滚动阶段的 keytap/HUD 用同一份配置,
  /// 保证用户自定义的保存快捷键在框选/标注阶段同样生效。saveModifierFlags 已是归一化值。
  var copyKeyCode: UInt16 = ScreenshotPreferences.defaults.copyKeyCode
  var cancelKeyCode: UInt16 = ScreenshotPreferences.defaults.cancelKeyCode
  var scrollKeyCode: UInt16 = ScreenshotPreferences.defaults.scrollKeyCode
  var saveKeyCode: UInt16 = ScreenshotPreferences.defaults.saveShortcut.keyCode
  var saveModifierFlags: UInt64 = ScreenshotPreferences.defaults.saveShortcut.modifierFlags

  /// 选区确认后传给 delegate 的全局 rect(AppKit 左下原点),供 ScreenshotCapturer.crop 使用。
  var currentSelectionGlobal: CGRect? {
    guard let s = selection else { return nil }
    return CGRect(
      x: s.minX + globalFrame.minX, y: s.minY + globalFrame.minY,
      width: s.width, height: s.height
    )
  }

  /// 本屏是否允许框选;另一块屏激活选区后会被会话置为 false。
  var selectionEnabled: Bool = true { didSet { needsDisplay = true } }
  /// 滚动捕获进行中:不压暗、不画冻结快照,只保留选区边框,露出底下真实 App 供滚动。
  var scrollCaptureActive: Bool = false { didSet { needsDisplay = true } }

  // MARK: - 标注 UI(选区激活后挂载)

  /// 选区一旦激活就置 true:此后不再画自带选区 chrome / 放大镜,交给画布与工具栏。
  private var hasActivated = false
  private var canvasView: AnnotationCanvasView?
  private var toolbar: AnnotationToolbarView?
  private var propertyBar: AnnotationPropertyBarView?
  private var textEditor: AnnotationTextEditor?

  /// 还没画任何标注前,选区仍可用手柄缩放并重建画布。
  private var canEditSelectionGeometry: Bool {
    !hasActivated || (canvasView?.editor.document.elements.isEmpty ?? true)
  }

  /// 缩放/平移选区是否可用:还没画标注、且当前没有激活的标注工具(处于选择/移动模式)。
  private var canAdjustSelectionGeometry: Bool {
    canEditSelectionGeometry && (canvasView?.editor.document.activeTool == nil)
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
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)
    // 选区仍可调整时,在八个手柄命中区盖上对应的缩放光标(后加的 rect 在其区域内覆盖十字)。
    guard selectionEnabled, canAdjustSelectionGeometry, let s = selection else { return }
    let rects = ScreenshotGeometry.handleRects(for: s, handleSize: handleHitSize)
    for handle in ScreenshotHandle.allCases {
      guard let rect = rects[handle] else { continue }
      addCursorRect(rect, cursor: Self.cursor(for: handle))
    }
  }

  /// 手柄 → 缩放光标。对角光标用私有 NSCursor(项目本就用私有 API),取不到时退化为左右缩放。
  private static func cursor(for handle: ScreenshotHandle) -> NSCursor {
    switch handle {
    case .left, .right: return .resizeLeftRight
    case .top, .bottom: return .resizeUpDown
    case .topLeft, .bottomRight:
      return diagonalCursor("_windowResizeNorthWestSouthEastCursor", fallback: .resizeLeftRight)
    case .topRight, .bottomLeft:
      return diagonalCursor("_windowResizeNorthEastSouthWestCursor", fallback: .resizeLeftRight)
    }
  }

  private static func diagonalCursor(_ selectorName: String, fallback: NSCursor) -> NSCursor {
    let selector = NSSelectorFromString(selectorName)
    if NSCursor.responds(to: selector),
       let cursor = NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor {
      return cursor
    }
    return fallback
  }

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

  /// 选区成形后,标注画布(冻结快照)铺满整个选区,既挡住边缘缩放手柄,又吞掉"拖内部平移"。
  /// 这里在仍可调整几何时,把命中手柄 / 选区内部(无激活工具)的点击改交回覆盖层自身处理。
  override func hitTest(_ point: NSPoint) -> NSView? {
    let result = super.hitTest(point)
    guard result === canvasView, selectionEnabled, canAdjustSelectionGeometry,
          let s = selection else {
      return result
    }
    let local = convert(point, from: superview)
    if ScreenshotGeometry.handle(at: local, selection: s, handleSize: handleHitSize) != nil {
      return self
    }
    if s.contains(local) {
      return self
    }
    return result
  }

  override func mouseDown(with event: NSEvent) {
    // 多屏:点哪块屏就把那块屏的覆盖窗口提为 key,保证后续空格/⌘S 键盘确认落到本 View。
    window?.makeKey()
    // 编辑文字时,输入框外单击(此处为选区外的压暗区)= 取消当前输入,而非新建/调整选区。
    if cancelActiveTextEditing() { return }
    guard selectionEnabled else { return }
    let p = ScreenshotGeometry.snapPointToBoundsEdges(
      convert(event.locationInWindow, from: nil), bounds: bounds)
    lastMouseLocal = p

    // 选区成形且未开始标注:双击选区内部 = 完成并复制(与画布选择模式一致)。
    if event.clickCount == 2, let s = selection, s.contains(p), canAdjustSelectionGeometry {
      confirm(.copy)
      return
    }

    if let s = selection,
       let h = ScreenshotGeometry.handle(at: p, selection: s, handleSize: handleHitSize),
       canAdjustSelectionGeometry {
      // 拖手柄缩放:先隐藏冻结快照画布,让覆盖层用实时快照重绘选区,保证跟手。
      beginGeometryEdit()
      mode = .dragHandle(h)
    } else if let s = selection, s.contains(p), canAdjustSelectionGeometry {
      // 在选区内部按下并拖动 = 整体平移选区(尚未画标注时)。
      beginGeometryEdit()
      mode = .moving
      dragOrigin = p
    } else if hasActivated {
      // 选区已锁定:画布外的点击(压暗区/手柄)不再新建或移动选区。
      return
    } else {
      dragOrigin = p
      selection = CGRect(origin: p, size: .zero)
      mode = .dragging
    }
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard selectionEnabled else { return }
    let p = ScreenshotGeometry.snapPointToBoundsEdges(
      convert(event.locationInWindow, from: nil), bounds: bounds)
    let previousMouse = lastMouseLocal
    lastMouseLocal = p
    let previousSelection = selection
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
      if let s = selection {
        selection = ScreenshotGeometry.moved(
          s,
          by: CGPoint(x: p.x - dragOrigin.x, y: p.y - dragOrigin.y),
          within: bounds
        )
        dragOrigin = p
      }
    case .idle:
      return
    }
    // 只失效实际变化的区域(旧/新选区 chrome + 放大镜),不再整屏重绘 Retina 底图。
    if let previousSelection { setNeedsDisplay(selectionInvalidRect(previousSelection)) }
    if let s = selection { setNeedsDisplay(selectionInvalidRect(s)) }
    if showMagnifier, !hasActivated {
      if let previousMouse { setNeedsDisplay(magnifierInvalidRect(around: previousMouse)) }
      setNeedsDisplay(magnifierInvalidRect(around: p))
    }
  }

  override func mouseUp(with event: NSEvent) {
    guard selectionEnabled else { return }
    var didAdjustGeometry = false
    if hasActivated {
      switch mode {
      case .dragHandle, .moving: didAdjustGeometry = true
      default: break
      }
    }
    // 单击未拖(尺寸≈0)且有悬停窗口 → 采纳整窗为选区。
    if case .dragging = mode, let s = selection, s.width < 3, s.height < 3, let w = hoverWindowRectLocal {
      selection = ScreenshotGeometry.clamp(w, to: bounds)
      hoverWindowRectLocal = nil
      ScreenshotDebugLog.log("window-snap adopted localRect="
        + "\(Int(w.minX)),\(Int(w.minY)) \(Int(w.width))x\(Int(w.height))")
    }
    mode = .idle
    needsDisplay = true
    // 选区落定后刷新光标区,让手柄缩放光标随新选区位置生效。
    window?.invalidateCursorRects(for: self)
    if didAdjustGeometry {
      // 缩放/平移结束:按新选区重建画布(重新裁切底图)并恢复工具栏。
      remountAnnotationUIAfterGeometryChange()
    } else {
      activateSelectionIfNeeded()
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    // 右键退出截图(与 Esc 等价)。
    delegate?.overlayDidCancel()
  }

  /// 若当前有进行中的文字编辑,取消它并返回 true;否则返回 false。
  /// 供画布"编辑中单击空白=取消"复用(`onRequestCancelTextEditing`)。
  @discardableResult
  private func cancelActiveTextEditing() -> Bool {
    guard textEditor != nil else { return false }
    textEditor?.cancel()
    return true
  }

  override func mouseMoved(with event: NSEvent) {
    let local = convert(event.locationInWindow, from: nil)
    let previousMouse = lastMouseLocal
    lastMouseLocal = local

    // 放大镜只在选区激活前显示;此前无条件整屏重绘,激活后移动鼠标也在空烧 CPU。
    if showMagnifier, !hasActivated {
      if let previousMouse { setNeedsDisplay(magnifierInvalidRect(around: previousMouse)) }
      setNeedsDisplay(magnifierInvalidRect(around: local))
    }

    // 已有选区时不再做选窗高亮,只需清掉残留的悬停边框。
    guard selection == nil else {
      if let hover = hoverWindowRectLocal {
        hoverWindowRectLocal = nil
        setNeedsDisplay(hover.insetBy(dx: -4, dy: -4))
      }
      return
    }
    // 窗口列表查询较重,限频 ~20Hz;两次查询之间沿用上次高亮结果。
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastHoverQueryTime >= 0.05 {
      lastHoverQueryTime = now
      let topLeft = appKitGlobalToTopLeft(localToAppKitGlobal(local))
      // 仅排除本截图覆盖层窗口,保留对 Velto 其它普通窗口(如设置窗)的识别能力。
      let excluded = Set([window?.windowNumber].compactMap { $0 })
      if ScreenshotDebugLog.isEnabled {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? bounds.height
        ScreenshotDebugLog.log(
          "[hover] local=\(Int(local.x)),\(Int(local.y)) globalFrame=\(Int(globalFrame.minX)),\(Int(globalFrame.minY)) "
          + "primaryH=\(Int(primaryHeight)) excluded=\(excluded.sorted()) topLeft=\(Int(topLeft.x)),\(Int(topLeft.y))\n"
          + WindowFrameDetector.diagnostics(
            atGlobalPoint: topLeft, excludingWindowNumbers: excluded, activeAppPID: activeAppPID))
      }
      let previousHover = hoverWindowRectLocal
      if let g = WindowFrameDetector.windowFrame(
        atGlobalPoint: topLeft,
        excludingWindowNumbers: excluded,
        activeAppPID: activeAppPID
      ) {
        hoverWindowRectLocal = appKitGlobalRectToLocal(topLeftRectToAppKitGlobal(g))
      } else {
        hoverWindowRectLocal = nil
      }
      if previousHover != hoverWindowRectLocal {
        if let previousHover { setNeedsDisplay(previousHover.insetBy(dx: -4, dy: -4)) }
        if let hover = hoverWindowRectLocal { setNeedsDisplay(hover.insetBy(dx: -4, dy: -4)) }
      }
    }
  }

  // MARK: - 脏矩形

  /// 放大镜(方框 + 下方信息标签)以光标为中心的保守外包区域。
  private func magnifierInvalidRect(around p: CGPoint) -> CGRect {
    CGRect(x: p.x - 160, y: p.y - 168, width: 320, height: 336)
  }

  /// 选区 chrome(3pt 边框、手柄、上/下方的尺寸标签)的保守外包区域。
  private func selectionInvalidRect(_ s: CGRect) -> CGRect {
    s.insetBy(dx: -110, dy: -42)
  }

  // MARK: - 键盘

  override func keyDown(with event: NSEvent) {
    let keyCode = event.keyCode
    let modifiers = ModifierFormatter.normalizedRawValue(from: event.modifierFlags)
    // 保存键带修饰,先于无修饰的复制/滚动判断,避免 ⌘S 被当成 S(滚动)。
    if keyCode == saveKeyCode, modifiers == saveModifierFlags {
      confirm(.save)                                  // 保存(默认 ⌘S)
    } else if modifiers == 0, keyCode == cancelKeyCode {
      delegate?.overlayDidCancel()                    // 取消(默认 Esc)
    } else if modifiers == 0, keyCode == copyKeyCode {
      confirm(.copy)                                  // 复制(默认 空格)
    } else if modifiers == 0, keyCode == 36 {
      confirm(.copy)                                  // Enter 始终 = 默认动作(复制)
    } else if modifiers == 0, keyCode == scrollKeyCode {
      confirm(.scroll)                                // 滚动长截图(默认 S)
    } else {
      super.keyDown(with: event)
    }
  }

  private func confirm(_ action: ScreenshotSessionAction) {
    guard let g = currentSelectionGlobal, g.width > 1, g.height > 1 else { return }
    delegate?.overlayDidRequest(action, globalRect: g, document: canvasView?.editor.document)
  }

  // MARK: - 绘制

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    // 滚动捕获中:整屏透明、只画选区边框。用户看到真实 App 并能滚动,边框标出捕获范围
    // (覆盖层已被截图过滤排除,边框不会进入拼接结果)。
    if scrollCaptureActive {
      if let s = selection { drawSelectionBorder(s, ctx: ctx) }
      return
    }

    // 底图整幅只画一次(亮),再仅在“选区/悬停区以外”压暗罩。
    // 关键性能点:旧实现每帧把全屏快照画两遍(底图 + 选区重绘),拖拽时严重卡顿;
    // 改为单次绘图 + even-odd 裁剪压暗,效果一致但开销减半。
    if let img = snapshotImage { ctx.draw(img, in: bounds) }

    // 非活动屏(另一块屏已激活选区):整屏压暗,无选区交互。
    guard selectionEnabled else {
      ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
      ctx.fill(bounds)
      return
    }

    let brightRegion = (selection ?? hoverWindowRectLocal)?.intersection(bounds)
    ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
    if let bright = brightRegion, !bright.isNull, bright.width > 0, bright.height > 0 {
      ctx.saveGState()
      ctx.addRect(bounds)
      ctx.addRect(bright)
      ctx.clip(using: .evenOdd)   // 裁到“bounds 去掉 bright”的区域,只压暗选区以外
      ctx.fill(bounds)
      ctx.restoreGState()
    } else {
      ctx.fill(bounds)
    }

    // 已激活且画过标注:选区 chrome 与放大镜交给画布/工具栏,这里只保留压暗罩。
    if hasActivated && !canEditSelectionGeometry {
      return
    }

    if let s = selection {
      drawSelectionBorder(s, ctx: ctx)
      drawHandles(for: s, ctx: ctx)
      drawSizeLabel(for: s, ctx: ctx)
    } else if let hover = hoverWindowRectLocal {
      drawHoverBorder(hover, ctx: ctx)
    }

    // 放大镜只在选区激活前(像素级框选阶段)出现。
    if showMagnifier, !hasActivated, let p = lastMouseLocal {
      drawMagnifier(at: p, ctx: ctx)
    }
  }

  private func drawSelectionBorder(_ s: CGRect, ctx: CGContext) {
    ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
    ctx.setLineWidth(3)
    ctx.stroke(s.insetBy(dx: 1.5, dy: 1.5))
  }

  private func drawHoverBorder(_ r: CGRect, ctx: CGContext) {
    ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
    ctx.setLineWidth(2)
    ctx.stroke(r.insetBy(dx: 1, dy: 1))
  }

  private func drawHandles(for s: CGRect, ctx: CGContext) {
    let rects = ScreenshotGeometry.handleRects(for: s, handleSize: handleSize)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
    ctx.setLineWidth(1.5)
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
    // 采样窗保持完整(可越界),裁剪时与图像求交;绘制按采样窗映射,越界部分留背板,
    // 避免屏幕边缘把不足 NxN 的裁剪图拉伸铺满、中心像素偏离十字。
    let sampleWindow = CGRect(
      x: pxX - half, y: pxYFromTop - half,
      width: CGFloat(sampleCount), height: CGFloat(sampleCount)
    ).integral
    let imageBounds = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    let clampedWindow = sampleWindow.intersection(imageBounds)
    let cropped = clampedWindow.isNull ? nil : img.cropping(to: clampedWindow)

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
      // 翻转子上下文里 y 向下:目标子矩形按「裁剪窗相对采样窗的偏移」对位。
      let unitX = boxSize / sampleWindow.width
      let unitY = boxSize / sampleWindow.height
      ctx.draw(cropped, in: CGRect(
        x: (clampedWindow.minX - sampleWindow.minX) * unitX,
        y: (clampedWindow.minY - sampleWindow.minY) * unitY,
        width: clampedWindow.width * unitX,
        height: clampedWindow.height * unitY
      ))
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

  // MARK: - 标注 UI 挂载

  /// 开始缩放/平移选区:隐藏会冻结快照的标注画布,改由覆盖层用实时快照重绘,保证跟手。
  private func beginGeometryEdit() {
    guard hasActivated else { return }
    setAnnotationUIHidden(true)
  }

  /// 缩放/平移结束:还没画标注时按新选区重建画布(重新裁切底图);否则仅恢复显示。
  private func remountAnnotationUIAfterGeometryChange() {
    guard let s = selection, s.width > 2, s.height > 2 else { return }
    if canvasView?.editor.document.elements.isEmpty != false {
      mountAnnotationUI(selection: s)
    } else {
      setAnnotationUIHidden(false)
    }
  }

  /// 选区有效后激活标注:首次激活通知会话锁定本屏;尚无标注时允许重建画布以跟随缩放。
  private func activateSelectionIfNeeded() {
    guard let s = selection, s.width > 2, s.height > 2 else { return }
    if !hasActivated {
      hasActivated = true
      delegate?.overlayDidActivateSelection(self)
      mountAnnotationUI(selection: s)
    } else if canvasView?.editor.document.elements.isEmpty == true {
      mountAnnotationUI(selection: s)
    }
  }

  private func mountAnnotationUI(selection s: CGRect) {
    tearDownAnnotationUI()
    guard let snapshot = snapshotImage,
          let baseImage = croppedSelectionImage(snapshot: snapshot, selection: s) else {
      return
    }

    let editor = AnnotationEditor(canvasSize: s.size)
    let canvas = AnnotationCanvasView(editor: editor, baseImage: baseImage, scale: scale)
    canvas.frame = s
    canvas.onDocumentChange = { [weak self] _ in self?.syncAnnotationChrome() }
    canvas.onRequestCancelSession = { [weak self] in self?.delegate?.overlayDidCancel() }
    canvas.onRequestComplete = { [weak self] in self?.confirm(.copy) }
    canvas.onBeginTextEditing = { [weak self] frame, existing in
      self?.beginTextEditing(annotationFrame: frame, existing: existing)
    }
    canvas.onRequestCancelTextEditing = { [weak self] in self?.cancelActiveTextEditing() ?? false }
    canvas.isTextEditing = { [weak self] in self?.textEditor != nil }
    addSubview(canvas)
    canvasView = canvas

    let bar = AnnotationToolbarView(frame: .zero)
    bar.onAction = { [weak self] action in self?.handleToolbarAction(action) }
    addSubview(bar)
    toolbar = bar

    let property = AnnotationPropertyBarView(frame: .zero)
    property.onStyleChange = { [weak self] style in self?.applyAnnotationStyle(style) }
    addSubview(property)
    propertyBar = property

    layoutAnnotationBars()
    syncAnnotationChrome()
    // 玻璃条刚挂上,强制重建光标区,确保其箭头光标覆盖父层的全屏十字。
    window?.invalidateCursorRects(for: bar)
    window?.invalidateCursorRects(for: property)
    window?.makeFirstResponder(canvas)
  }

  /// 选区(视图局部、左下原点)→ 快照像素图(左上原点),作为画布底图。
  private func croppedSelectionImage(snapshot: CGImage, selection s: CGRect) -> CGImage? {
    let px = CGRect(
      x: s.minX * scale,
      y: (bounds.height - s.maxY) * scale,
      width: s.width * scale,
      height: s.height * scale
    ).integral
    guard px.width >= 1, px.height >= 1 else { return nil }
    return snapshot.cropping(to: px)
  }

  private func layoutAnnotationBars() {
    guard let s = selection, let toolbar, let propertyBar else { return }
    let placement = AnnotationToolbarLayout.place(
      selection: s,
      screenBounds: bounds,
      mainSize: toolbar.barSize,
      propertySize: propertyBar.barSize
    )
    toolbar.frame = placement.mainFrame
    propertyBar.frame = placement.propertyFrame
    propertyBar.isHidden = (canvasView?.editor.document.activeTool == nil)
  }

  private func syncAnnotationChrome() {
    guard let canvas = canvasView, let toolbar, let propertyBar else { return }
    let editor = canvas.editor
    toolbar.update(
      activeTool: editor.document.activeTool,
      canUndo: editor.canUndo,
      canRedo: editor.canRedo
    )
    propertyBar.update(
      tool: editor.document.activeTool,
      style: editor.style,
      cropRect: editor.document.cropRect
    )
    layoutAnnotationBars()
  }

  private func handleToolbarAction(_ action: AnnotationToolbarAction) {
    guard let canvas = canvasView else { return }
    // 正在原位编辑文字时点工具栏:玻璃工具栏虽在本窗口内,但其自绘按钮点击不夺第一响应者,
    // NSTextView 不会失焦、textDidEndEditing 不触发,导致切走工具后仍能继续输入(且保存会丢
    // 未提交文字)。任何工具栏交互前,先把在编辑的文字提交(置 nil 并把第一响应者还给画布)。
    textEditor?.commit()
    switch action {
    case .selectTool(let tool):
      // 再次点击当前工具回到选择/移动模式。
      let next = (canvas.editor.document.activeTool == tool) ? nil : tool
      canvas.editor.selectTool(next)
      canvas.needsDisplay = true
      syncAnnotationChrome()
    case .undo:
      canvas.editor.undo()
      canvas.needsDisplay = true
      syncAnnotationChrome()
    case .redo:
      canvas.editor.redo()
      canvas.needsDisplay = true
      syncAnnotationChrome()
    case .cancel:
      delegate?.overlayDidCancel()
    case .save:
      confirm(.save)
    case .copy, .complete:
      confirm(.copy)
    }
  }

  private func applyAnnotationStyle(_ style: AnnotationStyle) {
    guard let canvas = canvasView else { return }
    canvas.editor.applyStyle(style)
    canvas.needsDisplay = true
    syncAnnotationChrome()
  }

  private func beginTextEditing(annotationFrame: CGRect, existing: TextAnnotation?) {
    guard let canvas = canvasView else { return }
    textEditor?.cancel()

    let style = existing?.style ?? canvas.editor.style
    let frameInCanvas = canvas.viewRect(forAnnotation: annotationFrame)
    let editor = AnnotationTextEditor(frame: .zero)
    editor.onCommit = { [weak self, weak canvas] text, committedFrame in
      guard let canvas else { return }
      canvas.commitTextEditing(text, annotationRect: canvas.annotationRect(forView: committedFrame))
      self?.textEditor = nil
      self?.window?.makeFirstResponder(canvas)
      self?.syncAnnotationChrome()
    }
    editor.onCancel = { [weak self, weak canvas] in
      canvas?.cancelTextEditing()
      self?.textEditor = nil
      if let canvas { self?.window?.makeFirstResponder(canvas) }
      self?.syncAnnotationChrome()
    }
    editor.begin(text: existing?.text ?? "", frame: frameInCanvas, style: style, in: canvas)
    textEditor = editor
  }

  /// 拆除标注 UI:先结束文字编辑,再移除画布/工具栏(连带其 history 与马赛克缓存)。
  /// 滚动捕获期间隐藏标注画布/工具栏/属性栏:画布会盖在选区上显示冻结快照(看似"锁死"),
  /// 工具栏在透传后又点不动。隐藏后露出底下真实滚动内容;取消滚动时再恢复。
  func setAnnotationUIHidden(_ hidden: Bool) {
    canvasView?.isHidden = hidden
    toolbar?.isHidden = hidden
    if hidden {
      propertyBar?.isHidden = true
    } else {
      propertyBar?.isHidden = (canvasView?.editor.document.activeTool == nil)
    }
  }

  func tearDownAnnotationUI() {
    textEditor?.cancel()
    textEditor = nil
    canvasView?.removeFromSuperview()
    canvasView = nil
    toolbar?.removeFromSuperview()
    toolbar = nil
    propertyBar?.removeFromSuperview()
    propertyBar = nil
  }
}
