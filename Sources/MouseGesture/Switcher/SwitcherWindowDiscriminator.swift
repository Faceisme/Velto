import ApplicationServices
import Cocoa

/// 判断某个 AX 元素到底是不是"用户能切到的真窗口"。
///
/// 主要踩坑来源:
///   - AXUI 里的"窗口"包含一堆鬼东西:tooltips、popovers、菜单项浮层、
///     启动时还没成型的 placeholder
///   - subrole 经常不可靠;有时 standard 窗口暂时给 AXDialog,过会儿才变回来
///   - 第三方框架(Electron / Steam / Adobe / JetBrains)各有奇葩
///
/// 我们只移植 alt-tab 里**通用**的判别条件 —— 不带任何 app 专属规则。
/// 等真的发现某个 app 漏识别,再单独加规则。
enum SwitcherWindowDiscriminator {
    /// 标准窗口的两种 subrole。绝大多数 app 走这两条路径。
    static let standardSubroles: Set<String> = [
        kAXStandardWindowSubrole as String,
        kAXDialogSubrole as String,
    ]

    /// 输入参数都允许 nil —— AX 调用可能漏字段,但我们必须给出确定的 yes/no。
    static func isActualWindow(
        bundleIdentifier: String?,
        wid: CGWindowID,
        title: String?,
        subrole: String?,
        role: String?,
        size: CGSize?
    ) -> Bool {
        // 没 wid 的不是真窗口(典型来源:打开 app 时勾了"启动时隐藏",AX 还会
        // 报一个空壳 element 但 _AXUIElementGetWindow 拿不到 id)
        guard wid != 0 else { return false }
        // 太小的不是窗口,是浮层/工具提示
        guard let size, size.width > 100, size.height > 50 else { return false }
        // subrole 必须在白名单。这条会过滤掉 99% 的非窗口噪音。
        guard let subrole, standardSubroles.contains(subrole) else { return false }
        // JetBrains 系常造出 subrole=AXStandardWindow 但 title 为空、
        // size 异常小的幽灵窗口。size 已经卡了 >100x50 但他们能造 101x51,
        // 这里加一刀:JetBrains app 必须有 title。
        if let bundleIdentifier,
           bundleIdentifier.range(of: #"^com\.(jetbrains\.|google\.android\.studio)"#, options: .regularExpression) != nil
        {
            if (title?.isEmpty ?? true) && size.width < 200 { return false }
        }
        _ = role  // 留着接口位置;P1 不用,后续 app-specific 规则要用
        return true
    }
}
