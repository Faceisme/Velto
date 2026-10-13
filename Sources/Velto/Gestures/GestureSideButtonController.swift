import CoreGraphics

/// 鼠标侧键(后退键 / 前进键)→ 按键,默认翻页。和右键手势同属手势模块。
///
/// 只在 tap 线程上用(`EventTapManager.handle` 与 `performOnTapThread` 块),无锁。
/// 按下即触发并吞掉,同一颗键之后的 dragged / up 也要认领:只吞 down 不吞 up,
/// App 会收到一个没有按下的抬起,浏览器这类原生支持侧键的 App 可能照样再后退一次。
final class GestureSideButtonController {
    /// CGEvent 的 `mouseEventButtonNumber`:0 左键、1 右键、2 中键、3 后退、4 前进。
    static let backButtonNumber: Int64 = 3
    static let forwardButtonNumber: Int64 = 4

    private var preferences = GestureSideButtonPreferences.defaults
    /// 按下时吞掉、还没抬起的键。
    private var heldButtons: Set<Int64> = []

    func updatePreferences(_ preferences: GestureSideButtonPreferences) {
        self.preferences = preferences
    }

    /// 按下:这颗键配了按键就记账并返回要发的按键;nil = 不接管。
    func press(button: Int64) -> Shortcut? {
        guard let shortcut = Self.shortcut(forButton: button, preferences: preferences) else {
            return nil
        }
        heldButtons.insert(button)
        return shortcut
    }

    func isHolding(button: Int64) -> Bool {
        heldButtons.contains(button)
    }

    /// 抬起:按下时吞过的才吞。不看开关 —— 按住期间关掉功能,抬起也得一并吞掉。
    func release(button: Int64) -> Bool {
        heldButtons.remove(button) != nil
    }

    /// tap 被系统禁用期间 up 会丢,清掉记账,免得之后那颗键透传时 up 被误吞。
    func reset() {
        heldButtons.removeAll()
    }

    static func shortcut(forButton button: Int64, preferences: GestureSideButtonPreferences) -> Shortcut? {
        guard preferences.enabled else { return nil }
        switch button {
        case backButtonNumber: return preferences.back
        case forwardButtonNumber: return preferences.forward
        default: return nil
        }
    }
}
