import AppKit
import Testing
@testable import Velto

/// 2026-10-29 现场:Movist Pro「播放时置顶」把播放窗口提到 layer 3,手势定位只认
/// layer 0,AX 命中了 Movist 却被校正到压在下面的访达,⌘W 关掉了后面的窗口。
@Test func gestureTargetPrefersFloatingWindowOfRegularApp() {
    let point = CGPoint(x: 100, y: 100)
    let movist = getpid() + 1
    let finder = getpid() + 2
    let agent = getpid() + 3
    func window(pid: pid_t, level: NSWindow.Level = .normal, wid: Int = 1,
                frame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 200),
                alpha: Double = 1, onscreen: Bool = true) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid,
         kCGWindowNumber as String: wid,
         kCGWindowLayer as String: level.rawValue,
         kCGWindowIsOnscreen as String: onscreen,
         kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: frame.dictionaryRepresentation]
    }
    func top(_ list: [[String: Any]], at p: CGPoint = point) -> pid_t? {
        GestureTargetController.floatingWindowOnTop(in: list, at: p, isRegularApp: { $0 != agent })?.pid
    }
    let player = window(pid: movist, level: .floating, wid: 42)
    let below = window(pid: finder)
    // macOS 27 程序坞:layer 20、铺满全屏、鼠标穿透,压在浮动窗口之上。
    let dock = window(pid: getpid() + 4, level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow))))

    #expect(top([player, below]) == movist)
    #expect(GestureTargetController.floatingWindowOnTop(
        in: [player, below], at: point, isRegularApp: { _ in true })?.wid == 42)
    #expect(top([dock, player, below]) == movist)
    #expect(top([window(pid: movist, level: .modalPanel), below]) == movist)
    // 普通窗口在最上层:不归这条路径管。
    #expect(top([below, player]) == nil)
    #expect(top([below]) == nil)
    // 后台 / 辅助 App 的浮动窗口多是 HUD、遮罩,不算。
    #expect(top([window(pid: agent, level: .floating), below]) == nil)
    #expect(top([window(pid: agent, level: .floating), player, below]) == movist)
    // 程序坞及以上层级都不算浮动窗口。
    #expect(top([dock, below]) == nil)
    #expect(top([window(pid: movist, level: .popUpMenu), below]) == nil)
    // Velto 自己的窗口压在上面:交回自身守护路径。
    #expect(top([window(pid: getpid(), level: .screenSaver), player, below]) == nil)
    // 不可见、太小、不在光标下的都跳过。
    #expect(top([window(pid: movist, level: .floating, alpha: 0), below]) == nil)
    #expect(top([window(pid: movist, level: .floating, onscreen: false), below]) == nil)
    #expect(top([window(pid: movist, level: .floating, frame: CGRect(x: 90, y: 90, width: 30, height: 30)), below]) == nil)
    #expect(top([player, below], at: CGPoint(x: 300, y: 300)) == nil)
}

@Test func floatingWindowLayersExcludeNormalAndDock() {
    let layers = GestureTargetController.floatingWindowLayers
    #expect(!layers.contains(NSWindow.Level.normal.rawValue))
    #expect(layers.contains(NSWindow.Level.floating.rawValue))
    #expect(layers.contains(NSWindow.Level.modalPanel.rawValue))
    #expect(!layers.contains(Int(CGWindowLevelForKey(.dockWindow))))
    #expect(!layers.contains(NSWindow.Level.mainMenu.rawValue))
    #expect(!layers.contains(NSWindow.Level.statusBar.rawValue))
}
