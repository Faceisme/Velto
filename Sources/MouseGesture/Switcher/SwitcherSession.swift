import Cocoa

/// 一次切换器从弹出到隐藏之间的状态。
/// 只在 panel 显示期间存活 —— controller 在 show 时创建,hide 时丢弃。
@MainActor
final class SwitcherSession {
    static var current: SwitcherSession?
    static var isActive: Bool { current != nil }

    /// 当前快照(已按 MRU 排好、ghost / 过滤已生效)
    var windows: [SwitcherWindow]

    /// 选中下标。范围 [0, windows.count) 或 -1(空)。
    var selectedIndex: Int

    /// 鼠标 hover 下标。-1 表示当前没 hover。selected 跟 hovered 互不依赖,
    /// 但显示时 hover 会临时覆盖 selected(松开还是切到 selected)。
    var hoveredIndex: Int

    init(windows: [SwitcherWindow], initialSelection: Int = 0) {
        self.windows = windows
        self.selectedIndex = windows.isEmpty ? -1 : min(initialSelection, windows.count - 1)
        self.hoveredIndex = -1
    }

    /// 当前选中(优先 selected,不计 hover)的窗口。空列表返回 nil。
    var selectedWindow: SwitcherWindow? {
        guard selectedIndex >= 0, selectedIndex < windows.count else { return nil }
        return windows[selectedIndex]
    }

    /// 循环选中。step 为正向下/向右,为负向上/向左。空列表是 no-op。
    func cycleSelection(_ step: Int) {
        guard !windows.isEmpty else { return }
        let n = windows.count
        // Swift 的 % 对负数会返回负 —— 这里手动 normalize 一下
        selectedIndex = ((selectedIndex + step) % n + n) % n
    }
}
