import AppKit
import Testing

@testable import Velto

/// 2026-10-29 现场:Movist Pro「播放时置顶」一开播就把窗口提到 layer 3,只认 layer 0
/// 判成「窗口=无」,刚开的勿扰两秒后又被关掉。
@Test @MainActor func focusAutomationCountsFloatingPlayerWindow() {
  let movist: pid_t = 23177
  func window(pid: pid_t = movist, level: NSWindow.Level, width: CGFloat = 1771, height: CGFloat = 996) -> [String: Any] {
    [kCGWindowOwnerPID as String: pid,
     kCGWindowLayer as String: level.rawValue,
     kCGWindowBounds as String: CGRect(x: 74, y: 30, width: width, height: height).dictionaryRepresentation]
  }
  func hasWindow(_ infos: [[String: Any]]) -> Bool {
    FocusAutomationController.hasOnScreenWindow(pids: [movist], in: infos)
  }
  #expect(hasWindow([window(level: .normal)]))
  #expect(hasWindow([window(level: .floating)]))
  #expect(hasWindow([window(level: .modalPanel)]))
  // 别家的窗口、太小的工具条、程序坞及以上层级都不算。
  #expect(!hasWindow([window(pid: movist + 1, level: .floating)]))
  #expect(!hasWindow([window(level: .floating, width: 640, height: 60)]))
  #expect(!hasWindow([window(level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow))))]))
  #expect(!hasWindow([window(level: .statusBar)]))
  #expect(!hasWindow([]))
}
