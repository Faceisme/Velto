import ApplicationServices
import Cocoa
import Foundation
import Synchronization

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
    // 开关用 Atomic 镜像(与 MouseScrollDebugLogger 同款):`shouldTrace` 在
    // Cmd+Tab 召唤路径被 snapshot 按窗口逐个调用,dispatch sync 会给召唤延迟
    // 加 N 倍常数项;原子 load 让关闭态读取零等待。文件句柄仍由 stateQueue 串行化。
    private static let stateQueue = DispatchQueue(label: "com.velto.switcher.debuglog.state")
    private static let enabledFlag = Atomic<Bool>(
        ProcessInfo.processInfo.environment["VELTO_SWITCHER_DEBUG"] == "1"
    )
    private nonisolated(unsafe) static var _handle: FileHandle?
    private nonisolated(unsafe) static var _handleOpened = false

    private static let envForced = ProcessInfo.processInfo.environment["VELTO_SWITCHER_DEBUG"] == "1"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var isEnabled: Bool {
        enabledFlag.load(ordering: .relaxed)
    }

    /// 由 `SwitcherController` 在启动 / 偏好变更时调用。环境变量为真时强制保持开启。
    static func setEnabled(_ enabled: Bool) {
        enabledFlag.store(enabled || envForced, ordering: .relaxed)
    }

    /// 首次需要写入时才打开文件句柄(关闭状态下零文件开销;运行时打开也支持)。
    /// **只能在 `stateQueue` 上调** —— `_handle` / `_handleOpened` 全靠它串行化,
    /// 而唯一的调用点 `log` 已经整个跑在 stateQueue 里(在那儿再 sync 回来是死锁)。
    private static func fileHandleOnStateQueue() -> FileHandle? {
        if !_handleOpened {
            _handleOpened = true
            _handle = Self.openLogFile()
        }
        return _handle
    }

    private static func openLogFile() -> FileHandle? {
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
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        // autoclosure 捕获调用点的局部状态,必须在派发**之前**求值;时间戳同理
        // (要的是调用时刻,不是落盘时刻)。
        let text = message()
        let now = Date()
        // 格式化和写入都挪进 stateQueue:`DateFormatter` 不是线程安全的,
        // `FileHandle.write` 并发调用也会把日志行撕开交错。后台 AX 队列改成
        // 有界并发后,抢这里的线程从"主线程 + 一条扫描线"变成五条,必须串行化。
        stateQueue.async {
            let line = "[\(dateFormatter.string(from: now))] \(text)\n"
            FileHandle.standardError.write(Data(line.utf8))
            if let handle = fileHandleOnStateQueue(), let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
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
