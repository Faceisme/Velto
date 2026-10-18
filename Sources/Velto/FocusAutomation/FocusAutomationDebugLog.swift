import Foundation

/// 专注自动化调试通道 —— 写 ~/Library/Logs/Velto/focus-automation.log。
///
/// 默认关闭。开启途径:
///   1. 设置页「调试日志」开关 -> FocusAutomationDebugLog.setEnabled
///   2. 环境变量 VELTO_FOCUS_DEBUG=1(开发期强制开)
enum FocusAutomationDebugLog {
  private static let stateQueue = DispatchQueue(label: "com.velto.focus.debuglog.state")
  private static let envForced = ProcessInfo.processInfo.environment["VELTO_FOCUS_DEBUG"] == "1"
  private nonisolated(unsafe) static var _enabled = envForced
  private nonisolated(unsafe) static var _handle: FileHandle?
  private nonisolated(unsafe) static var _handleOpened = false

  static let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Logs/Velto/focus-automation.log")

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
  }()

  static var isEnabled: Bool {
    stateQueue.sync { _enabled }
  }

  static func setEnabled(_ enabled: Bool) {
    stateQueue.sync { _enabled = enabled || envForced }
  }

  private static func fileHandle() -> FileHandle? {
    stateQueue.sync {
      if !_handleOpened {
        _handleOpened = true
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
          fm.createFile(atPath: fileURL.path, contents: nil)
        }
        _handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? _handle?.seekToEnd()
        let banner = "\n=== Velto focus-automation log started \(dateFormatter.string(from: Date())) ===\n"
        try? _handle?.write(contentsOf: Data(banner.utf8))
      }
      return _handle
    }
  }

  static func log(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    let line = "[\(dateFormatter.string(from: Date()))] \(message())\n"
    FileHandle.standardError.write(Data(line.utf8))
    try? fileHandle()?.write(contentsOf: Data(line.utf8))
  }
}
