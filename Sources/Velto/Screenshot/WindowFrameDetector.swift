import CoreGraphics
import Foundation

/// Immutable window snapshot and pointer-based hit testing, adapted from CapCap.
enum WindowFrameDetector {
  static func hitWindowBounds(
    in windows: [[String: Any]],
    atGlobalPoint p: CGPoint,
    excludingWindowNumbers excluded: Set<Int>,
    activeAppPID _: pid_t
  ) -> CGRect? {
    // CapCap-style window snap: the visible topmost window under the cursor wins.
    // In particular, never jump to another app's window away from the pointer.
    return windows.first { w in
      let layer = w[kCGWindowLayer as String] as? Int ?? -1
      guard [0, 3, 8, 24, 25, 101].contains(layer),
            !excluded.contains(w[kCGWindowNumber as String] as? Int ?? -1),
            (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
            let value = w[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: value), rect.width > 1, rect.height > 1 else { return false }
      return rect.contains(p)
    }.flatMap { w in
      (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }
  }

  /// Capture once before presenting the overlays, matching the frozen desktop.
  static func snapshot() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
  }

}
