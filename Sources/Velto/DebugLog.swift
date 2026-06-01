import Foundation

/// 轻量调试日志设施 —— 受设置里"调试模式"总开关控制(默认关)。
///
/// 开启后,代码各处可调用 `DebugLog.event(_:_:)` 把结构化事件追加到
/// `~/Library/Logs/Velto/velto-debug.jsonl`(每行一条 JSON,JSONL 格式),
/// 方便排查问题与迭代功能;关闭时 `event` 直接返回,开销可忽略。
///
/// 线程安全:开关状态用串行队列保护,可从任意线程读写(引擎在 tap 线程读,
/// 设置在主线程写);文件写入单独串行化到 `writeQueue`,互不阻塞。
enum DebugLog {
    private static let stateQueue = DispatchQueue(label: "com.velto.debuglog.state")
    private static let writeQueue = DispatchQueue(label: "com.velto.debuglog.write")
    // 仅在 stateQueue 内触碰,nonisolated(unsafe) 是经过串行化保证的安全例外。
    private nonisolated(unsafe) static var _enabled = false

    /// 日志文件路径:`~/Library/Logs/Velto/velto-debug.jsonl`。
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Velto", isDirectory: true)
            .appendingPathComponent("velto-debug.jsonl")
    }

    /// 调试模式是否开启。引擎在每次手势开始时读一次,据此决定本次是否记录。
    static var isEnabled: Bool {
        stateQueue.sync { _enabled }
    }

    /// 由 `GestureStore` 在启动加载 / 偏好变更 / 配置导入时调用,保持与开关同步。
    static func setEnabled(_ enabled: Bool) {
        let changed = stateQueue.sync { () -> Bool in
            guard _enabled != enabled else { return false }
            _enabled = enabled
            return true
        }
        if changed, enabled {
            event("debug", ["msg": "调试模式开启"])
        }
    }

    /// 追加一条结构化事件。`category` 标识来源(如 "gesture"),`fields` 为附加键值。
    /// 关闭时直接返回。JSON 序列化在调用线程完成(传 Sendable 的 `Data` 过队列,
    /// 规避把 `[String: Any]` 跨线程),仅文件写入排到 `writeQueue`。
    static func event(_ category: String, _ fields: [String: Any]) {
        guard isEnabled else { return }
        var obj: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "category": category
        ]
        obj.merge(fields) { _, new in new }
        guard JSONSerialization.isValidJSONObject(obj),
              var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)  // '\n'
        let line = data  // 捕获不可变副本,满足 @Sendable 闭包要求
        writeQueue.async { appendLine(line) }
    }

    /// 清空日志文件。
    static func clear() {
        writeQueue.async { try? FileManager.default.removeItem(at: fileURL) }
    }

    private static func appendLine(_ line: Data) {
        let url = fileURL
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }
}
