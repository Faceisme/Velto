import AppKit
import CoreGraphics

/// CGWindowList 的一行。坐标是 Quartz,和 CGEvent 同一套。
struct WindowInfo: Equatable, Sendable {
    var id: CGWindowID = 0
    var pid: pid_t
    var ownerName = ""
    /// 窗口标题。App 没给,或者没有屏幕录制权限时是 nil。
    var name: String?
    var layer = 0
    var bounds: CGRect
    var alpha = 1.0
    var isOnscreen = true

    /// Velto 自己的 pid。所有"鼠标下的目标"查询都必须先 skip 这个 pid ——
    /// 否则当鼠标停在 Velto 设置窗口边缘时(典型场景:用户 resize 设置窗口),
    /// `AXUIElementCopyElementAtPosition` 会被 AppKit 同步路由回我们自己的
    /// NSHostingView,在 *调用方所在线程*(可能是 WindowDragController 的
    /// background queue)同步跑 SwiftUI view graph update,撞到 MainActor
    /// 隔离的 Binding 闭包时 Swift 6 runtime executor 校验直接 SIGTRAP。
    static let ownPid: pid_t = getpid()

    var isOwn: Bool { pid == Self.ownPid }

    /// 在屏幕上,而且没有透明到看不见。
    var isVisible: Bool { isOnscreen && alpha > 0.01 }

    /// 普通窗口或置顶浮动窗口,见 `AppWindowLayer`。
    var isAppWindow: Bool { AppWindowLayer.contains(layer) }

    /// 再小就是工具条、细边,不算目标。
    fileprivate var isLargeEnoughToTarget: Bool { bounds.width >= 40 && bounds.height >= 40 }

    /// 光标下一个能当目标的普通窗口。
    fileprivate func isTarget(at point: CGPoint) -> Bool {
        layer == 0 && isVisible && isLargeEnoughToTarget && bounds.contains(point)
    }
}

extension WindowInfo {
    init?(row: [String: Any]) {
        guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let bounds = (row[kCGWindowBounds as String] as? NSDictionary)
                .flatMap({ CGRect(dictionaryRepresentation: $0) })
        else { return nil }

        self.init(
            id: id,
            pid: pid,
            ownerName: row[kCGWindowOwnerName as String] as? String ?? "",
            name: row[kCGWindowName as String] as? String,
            layer: layer,
            bounds: bounds,
            alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
            isOnscreen: row[kCGWindowIsOnscreen as String] as? Bool ?? false
        )
    }
}

/// 一次 CGWindowList 枚举的结果,窗口从上到下排列。
///
/// 枚举是跨进程的全窗口查询,一次操作里取一份反复查,不要每个判断都重新枚举。
struct WindowSnapshot: Sendable {
    let windows: [WindowInfo]

    init(_ windows: [WindowInfo] = []) {
        self.windows = windows
    }

    /// 当前屏幕上的窗口,不含桌面元素。
    static func onScreen() -> WindowSnapshot {
        list([.optionOnScreenOnly, .excludeDesktopElements])
    }

    /// 所有窗口,包括最小化的和其他桌面空间上的。
    static func all() -> WindowSnapshot {
        list([.optionAll, .excludeDesktopElements])
    }

    static func window(_ id: CGWindowID) -> WindowInfo? {
        list([.optionIncludingWindow], relativeTo: id).windows.first
    }

    /// 查一批 wid。WindowServer 不认识的 wid 不在结果里;不限在屏 —— 最小化和其他桌面
    /// 空间的窗口也查得到,只是 `isOnscreen` 为 false。单次 IPC,主线程廉价。
    ///
    /// `CGWindowListCreateDescriptionFromArray` 的正确调用姿势:CFArray 元素必须
    /// 是 **raw CGWindowID 位模式塞进指针槽**(alt-tab 同款),**不是** NSNumber/
    /// CFNumber —— 用 NSNumber 时该 API 不报错、静默返回空数组。
    static func windows(_ ids: [CGWindowID]) -> [WindowInfo] {
        guard !ids.isEmpty else { return [] }
        var pointers: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = pointers.withUnsafeMutableBufferPointer { buffer in
            CFArrayCreate(kCFAllocatorDefault, buffer.baseAddress, buffer.count, nil)
        }
        guard let array,
              let rows = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
        else { return [] }
        return rows.compactMap(WindowInfo.init(row:))
    }

    private static func list(
        _ options: CGWindowListOption,
        relativeTo id: CGWindowID = kCGNullWindowID
    ) -> WindowSnapshot {
        let rows = CGWindowListCopyWindowInfo(options, id) as? [[String: Any]] ?? []
        return WindowSnapshot(rows.compactMap(WindowInfo.init(row:)))
    }
}

// MARK: - 查询

extension WindowSnapshot {
    /// 光标下最上层的别家普通窗口。Velto 自己的窗口不能当作目标。
    func topmostAppWindow(at point: CGPoint) -> WindowInfo? {
        windows.first { $0.isTarget(at: point) && !$0.isOwn }
    }

    /// 光标下最上层的 Velto 自己的普通窗口。
    func topmostOwnWindow(at point: CGPoint) -> WindowInfo? {
        windows.first { $0.isTarget(at: point) && $0.isOwn }
    }

    /// 光标下最上层是**常规 App 的浮动窗口**时返回它,否则 nil。
    ///
    /// Movist Pro「播放时置顶」把播放窗口提到 layer 3,而其余定位只认 layer 0:
    /// AX 命中了 Movist,却被「以 CG 栈顶为准」校正到压在下面的访达 / Claude,
    /// 手势穿透过去把后面的窗口 ⌘W 关了(2026-10-29)。
    ///
    /// 只收常规(程序坞里有图标的)App:CGWindowList 看不出谁鼠标穿透,后台 /
    /// 辅助 App 的浮动窗口多是 HUD、遮罩,算进来会把手势吸走。
    /// 从上往下走,先碰到 Velto 自己(任何层级)或别家 layer 0 窗口就停,交回原来的路径。
    func floatingWindowOnTop(
        at point: CGPoint,
        isRegularApp: (pid_t) -> Bool = Self.ownerIsRegularApp
    ) -> WindowInfo? {
        for window in windows where window.isVisible && window.bounds.contains(point) {
            if window.isOwn || window.layer == 0 { return nil }
            guard AppWindowLayer.floating.contains(window.layer),
                  window.isLargeEnoughToTarget,
                  isRegularApp(window.pid)
            else { continue }
            return window
        }
        return nil
    }

    static func ownerIsRegularApp(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }

    /// 全局 AX 命中测试会不会落到 Velto 自己。自己的窗口不分层级都算:截图遮罩等
    /// 高层窗口也会被全局 AX 查询同步命中,从后台进入其 UI 会触发 SIGTRAP。
    /// 别家的非 layer 0 窗口一律跳过:CGWindowList 看不出谁鼠标穿透,macOS 27 程序坞
    /// 有张 layer 20 铺满全屏的透明窗口压在所有普通窗口上,按「最上层那张」判定就
    /// 永远是程序坞,守护形同虚设(2026-09-29 在设置窗口上画手势闪退)。
    /// 只有别家 layer 0 普通窗口才算真挡住。
    func isOverOwnWindow(at point: CGPoint) -> Bool {
        for window in windows where window.isVisible && window.bounds.contains(point) {
            if window.isOwn { return true }
            if window.layer == 0 { return false }
        }
        return false
    }

    /// 这个进程的普通窗口和置顶浮动窗口,最前面的在前。
    func appWindows(of pid: pid_t) -> [WindowInfo] {
        windows.filter { $0.pid == pid && $0.isAppWindow }
    }

    func containsWindow(of pid: pid_t) -> Bool {
        windows.contains { $0.pid == pid }
    }

    func ownerName(of pid: pid_t) -> String? {
        windows.first { $0.pid == pid && !$0.ownerName.isEmpty }?.ownerName
    }
}
