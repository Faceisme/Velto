import CoreGraphics
import Foundation

enum ScreenshotHandle: CaseIterable {
  case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

enum ScreenshotGeometry {
  /// 触发角守卫会把系统指针限制在角内侧；框选坐标仍吸附到真实屏幕边缘。
  static func snapPointToBoundsEdges(
    _ point: CGPoint,
    bounds: CGRect,
    threshold: CGFloat = ScreenshotHotCornerGuard.cornerInset + 1
  ) -> CGPoint {
    var point = point
    if abs(point.x - bounds.minX) <= threshold { point.x = bounds.minX }
    if abs(point.x - bounds.maxX) <= threshold { point.x = bounds.maxX }
    if abs(point.y - bounds.minY) <= threshold { point.y = bounds.minY }
    if abs(point.y - bounds.maxY) <= threshold { point.y = bounds.maxY }
    return point
  }

  /// 任意方向的两点 → 正矩形(始终非负宽高)。
  static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
  }

  /// 把选区夹进 bounds(超出部分截断)。
  static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
    rect.intersection(bounds)
  }

  /// 平移选区时只约束位置，不裁剪宽高。越过边界的部分通过夹住 origin 拉回屏幕内。
  static func moved(_ rect: CGRect, by delta: CGPoint, within bounds: CGRect) -> CGRect {
    let maxOriginX = max(bounds.minX, bounds.maxX - rect.width)
    let maxOriginY = max(bounds.minY, bounds.maxY - rect.height)
    let origin = CGPoint(
      x: min(max(rect.minX + delta.x, bounds.minX), maxOriginX),
      y: min(max(rect.minY + delta.y, bounds.minY), maxOriginY)
    )
    return CGRect(origin: origin, size: rect.size)
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
    let rects = handleRects(for: s, handleSize: h)
    return ScreenshotHandle.allCases.first { rects[$0]?.contains(p) == true }
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
    f.locale = Locale(identifier: "en_US_POSIX")
    return "Velto-\(f.string(from: date)).\(format.rawValue)"
  }
}
