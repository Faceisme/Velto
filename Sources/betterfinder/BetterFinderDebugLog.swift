import Darwin
import Foundation

public enum BetterFinderDebugLog {
    private static let stateQueue = DispatchQueue(label: "com.velto.betterfinder.debuglog.state")
    private static let envForced = ProcessInfo.processInfo.environment["VELTO_BETTERFINDER_DEBUG"] == "1"
    private nonisolated(unsafe) static var _enabled = ProcessInfo.processInfo.environment["VELTO_BETTERFINDER_DEBUG"] == "1"
    private nonisolated(unsafe) static var _handle: FileHandle?
    private nonisolated(unsafe) static var _handleOpened = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    public static var fileURL: URL {
        BetterFinderConstants.sharedDebugLogFileURL()
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Logs")
                .appendingPathComponent("Velto")
                .appendingPathComponent("betterfinder-debug.log")
    }

    public static var isEnabled: Bool {
        stateQueue.sync { _enabled }
    }

    public static func setEnabled(_ enabled: Bool) {
        let changed = stateQueue.sync { () -> Bool in
            let next = enabled || envForced
            guard _enabled != next else { return false }
            _enabled = next
            return true
        }
        if changed, isEnabled {
            log("debug enabled file=\(fileURL.path)")
        }
    }

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "[\(dateFormatter.string(from: Date()))] pid=\(getpid()) bundle=\(Bundle.main.bundleIdentifier ?? "-") \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let handle = fileHandle(), let data = line.data(using: .utf8) {
            writeLocked(data, to: handle)
        }
    }

    public static func clear() {
        stateQueue.sync {
            try? _handle?.close()
            _handle = nil
            _handleOpened = false
        }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func fileHandle() -> FileHandle? {
        stateQueue.sync {
            if !_handleOpened {
                _handleOpened = true
                _handle = openLogFile()
            }
            return _handle
        }
    }

    private static func openLogFile() -> FileHandle? {
        let url = fileURL
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        let banner = "\n=== Velto betterfinder debug log started \(dateFormatter.string(from: Date())) ===\n"
        if let handle, let data = banner.data(using: .utf8) {
            writeLocked(data, to: handle)
        }
        return handle
    }

    private static func writeLocked(_ data: Data, to handle: FileHandle) {
        let fd = handle.fileDescriptor
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
