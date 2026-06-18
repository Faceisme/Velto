import CoreGraphics
import Foundation

/// 截图会话期间把指针挡在屏幕角内侧，避免 Dock 执行系统触发角动作。
/// 只改写当前事件坐标，不修改用户的 macOS 触发角设置。
final class ScreenshotHotCornerGuard: @unchecked Sendable {
  static let shared = ScreenshotHotCornerGuard()

  static let cornerInset: CGFloat = 4

  private let lock = NSLock()
  private var displayBounds: [CGRect] = []

  private init() {}

  func activate(displayIDs: [CGDirectDisplayID]) {
    let bounds = displayIDs.map(CGDisplayBounds)
    lock.lock()
    displayBounds = bounds
    lock.unlock()
    ScreenshotDebugLog.log("hot-corner guard active displays=\(bounds.count)")
  }

  func deactivate() {
    lock.lock()
    displayBounds = []
    lock.unlock()
    ScreenshotDebugLog.log("hot-corner guard inactive")
  }

  func rewriteLocationIfNeeded(in event: CGEvent) {
    lock.lock()
    let bounds = displayBounds
    lock.unlock()
    guard !bounds.isEmpty else { return }

    let original = event.location
    let adjusted = Self.adjustedLocation(original, displayBounds: bounds)
    guard adjusted != original else { return }
    event.location = adjusted
  }

  static func adjustedLocation(
    _ location: CGPoint,
    displayBounds: [CGRect],
    inset: CGFloat = cornerInset
  ) -> CGPoint {
    guard inset > 0 else { return location }

    for bounds in displayBounds where bounds.contains(location) || isOnMaximumEdge(location, of: bounds) {
      let nearLeft = location.x <= bounds.minX + inset
      let nearRight = location.x >= bounds.maxX - inset
      let nearTop = location.y <= bounds.minY + inset
      let nearBottom = location.y >= bounds.maxY - inset

      if nearLeft && nearTop {
        return CGPoint(x: bounds.minX + inset, y: bounds.minY + inset)
      }
      if nearRight && nearTop {
        return CGPoint(x: bounds.maxX - inset, y: bounds.minY + inset)
      }
      if nearLeft && nearBottom {
        return CGPoint(x: bounds.minX + inset, y: bounds.maxY - inset)
      }
      if nearRight && nearBottom {
        return CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset)
      }
    }
    return location
  }

  private static func isOnMaximumEdge(_ point: CGPoint, of bounds: CGRect) -> Bool {
    (point.x == bounds.maxX && point.y >= bounds.minY && point.y <= bounds.maxY)
      || (point.y == bounds.maxY && point.x >= bounds.minX && point.x <= bounds.maxX)
  }
}
