import Darwin
import Foundation
import Synchronization

/// 往日志文件追加内容,文件大小有上限。
///
/// 用 O_APPEND 打开,每次写入都落在文件末尾:测试进程和运行中的 Velto 会写同一份日志,
/// 各记各的位置的话,后写的把对方的内容盖掉,切口落在中文字符中间就成了非法 UTF-8。
/// 超过上限时把当前文件改名成 `.1`(覆盖上一份),从空文件继续写。
final class LogFileWriter: @unchecked Sendable {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Velto", isDirectory: true)
    static let defaultMaximumSize: UInt64 = 5 * 1024 * 1024

    let url: URL
    private let maximumSize: UInt64
    private let lock = NSLock()
    private var handle: FileHandle?
    private var size: UInt64 = 0

    init(url: URL, maximumSize: UInt64 = LogFileWriter.defaultMaximumSize) {
        self.url = url
        self.maximumSize = maximumSize
    }

    convenience init(fileName: String) {
        self.init(url: Self.directory.appendingPathComponent(fileName))
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = currentHandle() else { return }
        try? handle.write(contentsOf: data)
        size += UInt64(data.count)
        if size >= maximumSize {
            rotate()
        }
    }

    /// 清空日志。
    func remove() {
        lock.lock()
        defer { lock.unlock() }
        closeHandle()
        try? FileManager.default.removeItem(at: url)
    }

    /// 文件被删掉(用户清理日志)后旧句柄写的是没人看得见的 inode,要重新打开。
    private func currentHandle() -> FileHandle? {
        if let handle {
            var status = stat()
            if fstat(handle.fileDescriptor, &status) == 0, status.st_nlink > 0 {
                return handle
            }
            closeHandle()
        }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return nil }
        let opened = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        size = (try? opened.seekToEnd()) ?? 0
        handle = opened
        return opened
    }

    private func rotate() {
        closeHandle()
        let archive = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: archive)
        try? FileManager.default.moveItem(at: url, to: archive)
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
        size = 0
    }
}

/// 一个模块的调试日志:开关、时间戳、写文件,写到 `~/Library/Logs/Velto/`。
///
/// 默认关闭,关闭时 `log` 只有一次原子读取,消息也不求值。开启途径是设置页开关,
/// 或者环境变量 `environmentKey=1`(开发期强制开)。可以从任意线程调用。
final class DebugLogFile: @unchecked Sendable {
    private let name: String
    private let writer: LogFileWriter
    private let forcedByEnvironment: Bool
    private let enabledFlag: Atomic<Bool>
    private let lock = NSLock()
    private var bannerWritten = false
    // DateFormatter 不是线程安全的,只在 lock 里用。
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(name: String, fileName: String, environmentKey: String) {
        self.name = name
        writer = LogFileWriter(fileName: fileName)
        forcedByEnvironment = ProcessInfo.processInfo.environment[environmentKey] == "1"
        enabledFlag = Atomic(forcedByEnvironment)
    }

    var fileURL: URL { writer.url }

    var isEnabled: Bool {
        enabledFlag.load(ordering: .relaxed)
    }

    /// 环境变量为真时强制保持开启。返回这次是否从关变成开。
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        let next = enabled || forcedByEnvironment
        let previous = enabledFlag.exchange(next, ordering: .relaxed)
        return next && !previous
    }

    func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        // 时间戳要调用时刻,不是拿到锁的时刻。
        let now = Date()
        let text = message()

        lock.lock()
        let timestamp = dateFormatter.string(from: now)
        var line = "[\(timestamp)] \(text)\n"
        if !bannerWritten {
            bannerWritten = true
            line = "\n=== Velto \(name) log started \(timestamp) ===\n" + line
        }
        lock.unlock()

        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        writer.append(data)
    }
}
