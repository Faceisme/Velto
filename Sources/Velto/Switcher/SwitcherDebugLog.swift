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
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["VELTO_SWITCHER_DEBUG"] == "1"
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let logFileHandle: FileHandle? = {
        guard isEnabled else { return nil }
        let fm = FileManager.default
        guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Velto", isDirectory: true)
        else { return nil }
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = logsDir.appendingPathComponent("switcher-debug.log")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        let banner = "\n=== Velto switcher debug log started \(dateFormatter.string(from: Date())) ===\n"
        if let data = banner.data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
        return handle
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "[\(dateFormatter.string(from: Date()))] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let handle = logFileHandle, let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    /// 只对"我们想盯着看"的 app 触发(目前是微信/Dropbox/1Password)。其他 app 静默。
    static func shouldTrace(bundleIdentifier: String?, appName: String?) -> Bool {
        guard isEnabled else { return false }
        return AppQuirks.hidesSyntheticSwitcherWindows(
            bundleIdentifier: bundleIdentifier,
            appName: appName
        )
    }

    /// 把一个 AX 窗口下的所有子元素(role/subrole/title/size)dump 出来。
    /// 用来确认那个"鬼窗"到底装了什么控件。
    nonisolated static func describeChildren(of window: AXUIElement) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let children = value as? [AXUIElement] else {
            return "<no children attr: result=\(result.rawValue)>"
        }
        if children.isEmpty { return "<children=[]>" }
        let lines = children.enumerated().map { idx, child -> String in
            let attrs = SwitcherAxRead.multiAttributes(child, [
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
               let s = SwitcherAxRead.axValueSize(raw)
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
