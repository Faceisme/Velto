import CoreGraphics
import Foundation

enum WindowFrameDetector {
  /// 实时查询:返回当前应识别的窗口边界(全局坐标,CGWindowList 语义=左上原点)。
  /// 识别规则见 `hitWindowBounds`:认"触发截图时的活动 app"(`activeAppPID`)的窗口,光标落在
  /// 后台窗口上时改识别活动窗口,空桌面则返回 nil(留给手动框选)。
  /// `excluded` 仅排除截图覆盖层自身窗口号(覆盖层在 screenSaver 层本就被 layer 过滤,这里兜底)。
  static func windowFrame(
    atGlobalPoint p: CGPoint,
    excludingWindowNumbers excluded: Set<Int>,
    activeAppPID: pid_t
  ) -> CGRect? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    return hitWindowBounds(in: infos, atGlobalPoint: p, excludingWindowNumbers: excluded, activeAppPID: activeAppPID)
  }

  /// 纯逻辑(窗口数组按 CGWindowList z 序,前在先)。规则:
  /// 1. 候选 = layer==0 且窗口号不在排除集(覆盖层)的窗口;
  /// 2. 先找光标下最前的候选窗口 `topAtPoint`:
  ///    - 没有(空桌面/无窗口)→ 返回 nil,不识别,留给手动框选;
  ///    - 它属于活动 app → 就是它(支持活动 app 的多窗口按光标区分);
  ///    - 它是后台窗口 → **忽略后台窗口**,改识别活动 app 的最前窗口(用户要的就是活动窗口);
  /// 3. 活动 app 在屏上没有可见窗口时,退回光标下窗口。
  /// `activeAppPID==0`(未知)时退化为旧的"光标下最前窗口"行为。
  static func hitWindowBounds(
    in windows: [[String: Any]],
    atGlobalPoint p: CGPoint,
    excludingWindowNumbers excluded: Set<Int>,
    activeAppPID: pid_t
  ) -> CGRect? {
    func boundsOf(_ w: [String: Any]) -> CGRect? {
      (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }
    let candidates = windows.filter { w in
      (w[kCGWindowLayer as String] as? Int) == 0
        && !excluded.contains(w[kCGWindowNumber as String] as? Int ?? -1)
    }
    guard let topAtPoint = candidates.first(where: { boundsOf($0)?.contains(p) == true }) else {
      return nil
    }
    let topPID = topAtPoint[kCGWindowOwnerPID as String] as? pid_t ?? 0
    if activeAppPID == 0 || topPID == activeAppPID {
      return boundsOf(topAtPoint)
    }
    if let activeWindow = candidates.first(where: {
      ($0[kCGWindowOwnerPID as String] as? pid_t) == activeAppPID
    }), let rect = boundsOf(activeWindow) {
      return rect
    }
    return boundsOf(topAtPoint)
  }

  /// 诊断:把候选窗口(front→back)逐行 dump,并标出被层级/排除集过滤的、命中光标的、活动 app 的、
  /// 以及最终按规则选中的那个。仅在调试日志开启时调用,用于定位"识别到错误窗口"。
  static func diagnostics(
    atGlobalPoint p: CGPoint,
    excludingWindowNumbers excluded: Set<Int>,
    activeAppPID: pid_t
  ) -> String {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
      return "  <no window list>"
    }
    let chosenRect = hitWindowBounds(
      in: windows, atGlobalPoint: p, excludingWindowNumbers: excluded, activeAppPID: activeAppPID)
    var lines: [String] = ["  activeAppPID=\(activeAppPID) chosen=\(chosenRect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "nil")"]
    for w in windows {
      let layer = w[kCGWindowLayer as String] as? Int ?? -999
      let num = w[kCGWindowNumber as String] as? Int ?? -1
      let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? -1
      let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
      let name = w[kCGWindowName as String] as? String ?? ""
      let rect = (w[kCGWindowBounds as String] as? NSDictionary)
        .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
      let contains = rect.contains(p)
      guard layer == 0 || contains else { continue }
      var tag = ""
      if layer != 0 { tag = "skip(layer\(layer))" }
      else if excluded.contains(num) { tag = "skip(overlay)" }
      else if pid == activeAppPID { tag = contains ? "active+hit" : "active" }
      else if contains { tag = "bg-hit" }
      if rect == chosenRect { tag += " CHOSEN" }
      lines.append(String(
        format: "  L%-3d #%-6d pid%-6d %@ [%@] %d,%d %dx%d contains=%@ %@",
        layer, num, pid, owner as NSString, name as NSString,
        Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height),
        contains ? "Y" : "N", tag as NSString))
    }
    return lines.joined(separator: "\n")
  }
}
