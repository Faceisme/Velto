import ApplicationServices
import Cocoa
import Foundation

/// 切换器调试通道 —— 用来排查"莫名其妙的窗口出现在切换器里"这类问题。
///
/// 默认完全关闭(`isEnabled` 一次性求值,运行时无开销)。出问题时:
///   1. `pkill -x Velto`
///   2. `VELTO_SWITCHER_DEBUG=1 /Applications/Velto.app/Contents/MacOS/Velto`
///   3. 触发场景
///   4. 把 `~/Library/Logs/Velto/switcher-debug.log` 发过来
///
/// 只对 `AppQuirks.hidesSyntheticSwitcherWindows` 名单里的 app 打日志
/// (当前是:微信、Dropbox、1Password)—— 别的 app 静默,免得日志噪音。
enum SwitcherDebugLog {
    // 运行时可切换:由切换器设置页的"调试日志"开关经 SwitcherController.setEnabled 驱动,
    // 同时保留环境变量 VELTO_SWITCHER_DEBUG=1 作为开发期强制开启入口。
    // `shouldTrace` 在 Cmd+Tab 召唤路径被 snapshot 按窗口逐个调用,开关读取必须零等待,
    // `DebugLogFile` 用的是原子读取。
    private static let file = DebugLogFile(
        name: "switcher", fileName: "switcher-debug.log", environmentKey: "VELTO_SWITCHER_DEBUG")

    static var fileURL: URL { file.fileURL }
    static var isEnabled: Bool { file.isEnabled }

    /// 由 `SwitcherController` 在启动 / 偏好变更时调用。环境变量为真时强制保持开启。
    static func setEnabled(_ enabled: Bool) {
        file.setEnabled(enabled)
    }

    static func log(_ message: @autoclosure () -> String) {
        file.log(message())
    }

    /// 临时 trace 名单:`VELTO_SWITCHER_TRACE_APPS=DBeaver,Figma`(逗号分隔,对
    /// app 名和 bundle id 做大小写无关子串匹配)。
    ///
    /// 排查"某个 app 不出现在候选框"时必须能盯着那个 app 看,而 trace 原先绑死在
    /// `AppQuirks.hidesSyntheticSwitcherWindows` 名单上 —— 想看新 app 就得先改
    /// quirk 规则(那有真实副作用)。这个口子只影响日志,不碰任何业务判定。
    private static let extraTraceKeywords: [String] = {
        guard let raw = ProcessInfo.processInfo.environment["VELTO_SWITCHER_TRACE_APPS"] else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }()

    /// 只对"我们想盯着看"的 app 触发(quirk 名单:微信/Dropbox/1Password,
    /// 外加 VELTO_SWITCHER_TRACE_APPS 指定的)。其他 app 静默。
    static func shouldTrace(bundleIdentifier: String?, appName: String?) -> Bool {
        guard isEnabled else { return false }
        if !extraTraceKeywords.isEmpty {
            let haystack = "\(appName ?? "") \(bundleIdentifier ?? "")".lowercased()
            if extraTraceKeywords.contains(where: { haystack.contains($0) }) { return true }
        }
        return AppQuirks.hidesSyntheticSwitcherWindows(
            bundleIdentifier: bundleIdentifier,
            appName: appName
        )
    }

    /// 把一个 AX 窗口下的所有子元素(role/subrole/title/size)dump 出来。
    /// 用来确认那个"鬼窗"到底装了什么控件。
    nonisolated static func describeChildren(of window: AXUIElement) -> String {
        guard let children = AXClient.elements(kAXChildrenAttribute, of: window) else {
            return "<no children attr>"
        }
        if children.isEmpty { return "<children=[]>" }
        let lines = children.enumerated().map { idx, child -> String in
            let attrs = AXClient.values(of: child, [
                kAXRoleAttribute as String,
                kAXSubroleAttribute as String,
                kAXTitleAttribute as String,
                kAXValueAttribute as String,
                kAXSizeAttribute as String,
            ])
            let role = attrs[kAXRoleAttribute as String] as? String ?? "?"
            let subrole = attrs[kAXSubroleAttribute as String] as? String ?? "-"
            let title = attrs[kAXTitleAttribute as String] as? String ?? ""
            let valueStr = attrs[kAXValueAttribute as String] as? String ?? ""
            let size: String
            if let raw = attrs[kAXSizeAttribute as String],
               let s = AXClient.size(from: raw)
            {
                size = "\(Int(s.width))x\(Int(s.height))"
            } else {
                size = "-"
            }
            return "    [\(idx)] role=\(role) subrole=\(subrole) size=\(size) title=\"\(title)\" value=\"\(valueStr)\""
        }
        return "<children count=\(children.count)>\n" + lines.joined(separator: "\n")
    }
}
