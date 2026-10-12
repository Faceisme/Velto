import Foundation

/// 输入法切换调试通道 —— 独立写 ~/Library/Logs/Velto/input-source-switch.log,
/// 与切换器/手势各写各的,互不污染。
///
/// 默认关闭。开启途径:
///   1. 设置页「调试日志」开关 -> InputSourceSwitchDebugLog.setEnabled
///   2. 环境变量 VELTO_INPUT_SOURCE_DEBUG=1(开发期强制开)
enum InputSourceSwitchDebugLog {
  private static let stateQueue = DispatchQueue(label: "com.velto.inputsource.debuglog.state")
  private nonisolated(unsafe) static var _enabled =
    ProcessInfo.processInfo.environment["VELTO_INPUT_SOURCE_DEBUG"] == "1"
  private nonisolated(unsafe) static var _handle: FileHandle?
  private nonisolated(unsafe) static var _handleOpened = false

  private static let envForced = ProcessInfo.processInfo.environment["VELTO_INPUT_SOURCE_DEBUG"] == "1"

  static let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Logs/Velto/input-source-switch.log")

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
        _handle = Self.openLogFile()
      }
      return _handle
    }
  }

  private static func openLogFile() -> FileHandle? {
    let fm = FileManager.default
    let url = fileURL
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !fm.fileExists(atPath: url.path) {
      fm.createFile(atPath: url.path, contents: nil)
    }
    let handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
    let banner = "\n=== Velto input-source-switch log started \(dateFormatter.string(from: Date())) ===\n"
    if let data = banner.data(using: .utf8) {
      try? handle?.write(contentsOf: data)
    }
    return handle
  }

  static func log(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    let line = "[\(dateFormatter.string(from: Date()))] \(message())\n"
    FileHandle.standardError.write(Data(line.utf8))
    if let handle = fileHandle(), let data = line.data(using: .utf8) {
      try? handle.write(contentsOf: data)
    }
  }
}
