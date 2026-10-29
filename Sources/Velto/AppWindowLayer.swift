import CoreGraphics

/// App 自己的窗口会落在 CGWindowList 的哪些层级。
///
/// 只认 layer 0 不够:Movist Pro「播放时置顶」把播放窗口提到 layer 3,只认 layer 0
/// 的地方一开播就当它没窗口了 —— 手势穿透到后面的窗口、专注自动化把刚开的勿扰
/// 又关掉(2026-10-29)。
enum AppWindowLayer {
    /// 「置顶」浮动段:比普通窗口(0)高、比程序坞(20)低 ——
    /// `kCGFloatingWindowLevel`(3)/ 模态面板(8)/ 工具面板(19)都在这段。
    /// 程序坞那张 layer 20 全屏穿透窗口、菜单栏、通知横幅都在段外。
    static let floating = 1..<Int(CGWindowLevelForKey(.dockWindow))

    /// 普通窗口(layer 0)或置顶浮动窗口。
    static func contains(_ layer: Int) -> Bool {
        layer == 0 || floating.contains(layer)
    }
}
