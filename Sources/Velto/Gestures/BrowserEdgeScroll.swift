import AppKit
import CoreGraphics

/// 浏览器里「置顶/置底」(⌘↑ / ⌘↓)的滚轮补发。
///
/// 只发 ⌘↑ 时,有的网页根本不响应:apple.com.cn 首页、爱奇艺上 ⌘↑/⌘↓ 毫无反应,滚轮
/// 却正常,同站的 /iphone/ 又响应 ⌘↑(2026-10-31 实测,Chrome 156)。手势识别和按键投递
/// 都没问题,问题在网页这一侧,所以按键之外再补一组滚轮:滚轮按落点找滚动容器,不依赖
/// 键盘焦点,焦点在文本框时页面也能滚。
///
/// 必须先滚轮后按键:⌘↑ 是带动画的滚动,后到的滚轮会打断它,超长页面就停在半路;
/// 反过来滚轮瞬间跳完,⌘↑ 再把超出滚轮行程的部分收尾。
///
/// 只对浏览器生效:别的 App 里 ⌘↑ 未必是「滚到顶」(访达里是上级目录)。
enum BrowserEdgeScroll {
    enum Edge: Equatable {
        case top
        case bottom
    }

    /// 3 × 30000px:单次够绝大多数页面到边,再长的由 ⌘↑ 收尾。
    private static let pixelsPerEvent: Int32 = 30_000
    private static let eventCount = 3
    /// 一帧发一个,和真实滚轮的节奏一样,一次性灌进去 Chrome 会合并丢量。
    private static let eventInterval: Duration = .milliseconds(16)

    /// 严格匹配 ⌘↑ / ⌘↓。Fn、小键盘位不看:方向键录下来天然带这两位(显示成 ⌘Fn↑)。
    static func edge(for shortcut: Shortcut) -> Edge? {
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let flags = CGEventFlags(rawValue: CGEventFlags.RawValue(shortcut.modifierFlags))
        guard flags.intersection(modifiers) == .maskCommand else { return nil }

        switch shortcut.keyCode {
        case VirtualKeyCode.upArrow: return .top
        case VirtualKeyCode.downArrow: return .bottom
        default: return nil
        }
    }

    static func isBrowser(_ application: NSRunningApplication?) -> Bool {
        SupportedBrowserCatalog.browser(forBundleID: application?.bundleIdentifier) != nil
    }

    /// 正值 = 内容下移 = 往顶部滚。不受鼠标控制的「反转」影响:合成标记让事件绕开了它。
    static func wheelDelta(for edge: Edge) -> Int32 {
        edge == .top ? pixelsPerEvent : -pixelsPerEvent
    }

    /// 事件留在光标当前位置,别改 `location`:post 到 session tap 时事件坐标会把系统光标
    /// 一起带过去,松手后光标就跳回手势起点。`postToPid` 倒是不动光标,但这样新建的事件
    /// Chrome 不接(补上窗口号、phase 也不行),鼠标控制能用它是因为复用了真实滚轮事件。
    static func makeWheelEvent(for edge: Edge) -> CGEvent? {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: wheelDelta(for: edge),
            wheel2: 0,
            wheel3: 0
        )
        event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event?.setIntegerValueField(.eventSourceUserData, value: MouseControlController.syntheticScrollMarker)
        return event
    }

    @MainActor
    static func send(_ edge: Edge) async {
        for _ in 0..<eventCount {
            makeWheelEvent(for: edge)?.post(tap: .cgSessionEventTap)
            try? await Task.sleep(for: eventInterval)
        }
    }
}
