import AppKit
import CoreGraphics

/// 指定 App 全屏时把指针挡在程序坞所在的屏幕边缘内侧,程序坞就不会被误触弹出
/// (比如拖 Movist Pro 底部的进度条时蹭到屏幕底边)。
///
/// 和截图的 ScreenshotHotCornerGuard 一样只改写 event tap 里的事件坐标,不改系统设置。
/// 主线程决定挡哪块屏幕的哪条边,event tap 线程只读,用锁传状态。
final class DockRevealGuard: @unchecked Sendable {
  static let shared = DockRevealGuard()

  enum Edge: String {
    case bottom, left, right
  }

  struct Region: Equatable {
    let displayBounds: CGRect
    let edge: Edge
  }

  /// 指针离程序坞那条边至少留这么多点。程序坞只在指针碰到最边上一排像素时弹出。
  static let inset: CGFloat = 3

  private let lock = NSLock()
  private var region: Region?

  private init() {}

  /// 主线程调用;nil = 不挡。返回状态是否变了,供调用方写日志。
  @discardableResult
  func setRegion(_ newValue: Region?) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard region != newValue else { return false }
    region = newValue
    return true
  }

  /// event tap 线程调用,mouseMoved / *Dragged 都要过一遍。
  func rewriteLocationIfNeeded(in event: CGEvent) {
    lock.lock()
    let current = region
    lock.unlock()
    guard let current else { return }
    let original = event.location
    let adjusted = Self.clamped(original, region: current)
    if adjusted != original { event.location = adjusted }
  }

  static func clamped(_ point: CGPoint, region: Region, inset: CGFloat = inset) -> CGPoint {
    let b = region.displayBounds
    var p = point
    switch region.edge {
    case .bottom:
      guard p.x >= b.minX, p.x <= b.maxX, p.y >= b.minY, p.y <= b.maxY else { return point }
      p.y = min(p.y, b.maxY - inset)
    case .left:
      guard p.y >= b.minY, p.y <= b.maxY, p.x >= b.minX, p.x <= b.maxX else { return point }
      p.x = max(p.x, b.minX + inset)
    case .right:
      guard p.y >= b.minY, p.y <= b.maxY, p.x >= b.minX, p.x <= b.maxX else { return point }
      p.x = min(p.x, b.maxX - inset)
    }
    return p
  }

  // MARK: - 主线程:算该挡哪里

  /// 程序坞在屏幕哪条边(系统设置 → 桌面与程序坞 → 位置)。
  static func dockEdge() -> Edge {
    UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation").flatMap(Edge.init) ?? .bottom
  }

  /// `pid` 最前面的普通窗口铺满了哪块屏幕;没铺满返回 nil。
  /// 原生全屏时窗口和屏幕一样大;最大化(程序坞自动隐藏时)窗口左右铺满、贴到底边。
  static func fullScreenDisplay(pid: pid_t) -> CGRect? {
    guard let infos = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      // 列表从前往后排,第一个够大的普通窗口就是它最前面的窗口。
      let front = infos.lazy.compactMap({ info -> CGRect? in
        guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
              (info[kCGWindowLayer as String] as? Int) == 0,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict),
              rect.width >= 200, rect.height >= 200
        else { return nil }
        return rect
      }).first
    else { return nil }
    return activeDisplayBounds().first { display in
      abs(front.minX - display.minX) <= 1 && abs(front.maxX - display.maxX) <= 1
        && front.maxY >= display.maxY - 1 && front.minY <= display.minY + 40
    }
  }

  /// 那条边外面紧挨着别的屏幕时不挡:程序坞不会出现在两块屏幕的交界处,挡了反而过不去。
  static func edgeIsOuter(_ edge: Edge, of display: CGRect, among displays: [CGRect]) -> Bool {
    let probe: CGRect = switch edge {
    case .bottom: CGRect(x: display.minX, y: display.maxY, width: display.width, height: 1)
    case .left: CGRect(x: display.minX - 1, y: display.minY, width: 1, height: display.height)
    case .right: CGRect(x: display.maxX, y: display.minY, width: 1, height: display.height)
    }
    return !displays.contains { $0 != display && $0.intersects(probe) }
  }

  static func activeDisplayBounds() -> [CGRect] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map(CGDisplayBounds)
  }
}
