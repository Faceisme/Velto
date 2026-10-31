import Foundation
import Synchronization

final class MouseScrollDebugLogger: @unchecked Sendable {
    static let shared = MouseScrollDebugLogger()
    static var fileURL: URL { shared.writer.url }

    private let writer = LogFileWriter(fileName: "mouse-scroll-debug.log")
    private let queue = DispatchQueue(label: "com.face.velto.mouse-scroll.debug-log", qos: .utility)
    private let stateLock = NSLock()
    /// `enabled` 的无锁镜像。生产态(日志关闭)下,每事件的 nextEventID/log 只做一次
    /// 原子 load 即返回,不再加锁。开启日志时才走 stateLock 路径。
    private let enabledFlag = Atomic<Bool>(false)
    private var enabled = false
    private var eventCounter: UInt64 = 0

    private init() {}

    func setEnabled(_ shouldEnable: Bool) {
        enabledFlag.store(shouldEnable, ordering: .relaxed)
        stateLock.lock()
        let didChange = enabled != shouldEnable
        enabled = shouldEnable
        if shouldEnable {
            eventCounter = 0
        }
        stateLock.unlock()

        guard didChange, shouldEnable else { return }
        // 每次开启都从空文件开始:这份日志量大,只看这一轮。
        queue.async { [writer] in
            writer.remove()
            writer.append(Self.line("session start pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "-")"))
        }
    }

    func nextEventID() -> UInt64 {
        guard enabledFlag.load(ordering: .relaxed) else { return 0 }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard enabled else { return 0 }
        eventCounter &+= 1
        return eventCounter
    }

    func log(_ message: @autoclosure () -> String) {
        guard enabledFlag.load(ordering: .relaxed) else { return }
        stateLock.lock()
        let isEnabled = enabled
        stateLock.unlock()
        guard isEnabled else { return }
        let line = Self.line(message())
        queue.async { [writer] in writer.append(line) }
    }

    private static func line(_ message: String) -> Data {
        Data("\(timestamp()) \(message)\n".utf8)
    }

    private static func timestamp() -> String {
        String(format: "%.6f", CFAbsoluteTimeGetCurrent())
    }
}

func mouseDebugNumber(_ value: Double) -> String {
    String(format: "%.4f", value)
}

func mouseDebugOptionalNumber(_ value: Double?) -> String {
    guard let value else { return "-" }
    return mouseDebugNumber(value)
}

func mouseDebugPair(_ value: (y: Double, x: Double)) -> String {
    "y=\(mouseDebugNumber(value.y)) x=\(mouseDebugNumber(value.x))"
}
