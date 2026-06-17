import AppKit
import CoreGraphics
import Foundation

enum WindowFrameDetector {
  /// 实时查询:返回光标下最上层窗口的边界(全局坐标,CGWindowList 语义=左上原点)。
  static func windowFrame(atGlobalPoint p: CGPoint, excludingPID pid: pid_t) -> CGRect? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    return hitWindowBounds(in: infos, atGlobalPoint: p, excludingPID: pid)
  }

  /// 纯逻辑:窗口数组按前后顺序(CGWindowList 已按 z 序,前在先),取第一个
  /// layer==0、非自身 PID、且 bounds 命中光标的窗口。
  static func hitWindowBounds(in windows: [[String: Any]], atGlobalPoint p: CGPoint, excludingPID pid: pid_t) -> CGRect? {
    for w in windows {
      if let layer = w[kCGWindowLayer as String] as? Int, layer != 0 { continue }
      if let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == pid { continue }
      guard let dict = w[kCGWindowBounds as String] as? [String: CGFloat],
            let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
      if rect.contains(p) { return rect }
    }
    return nil
  }
}
