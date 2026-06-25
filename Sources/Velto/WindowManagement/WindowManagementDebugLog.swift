import Foundation

/// 窗口管理调试通道 —— 独立写 ~/Library/Logs/Velto/window-management.log,
/// 与按键映射 / 切换器 / 手势 / 输入法各写各的,互不污染。
///
/// 默认关闭。开启途径:
///   1. 设置页「窗口管理 → 调试日志」开关 -> WindowManagementDebugLog.setEnabled
///   2. 环境变量 VELTO_WINDOW_DEBUG=1(开发期强制开)
///
/// 线程安全:开关状态用串行队列保护,可从任意线程读写(目标定位在 window-drag
/// 后台队列读 / 写日志,设置在主线程改开关)。move/resize 按鼠标事件触发,日志
/// 在 began / 目标定位等关键节点打点,`log` 内直接同步写文件即可。
enum WindowManagementDebugLog {
  private static let stateQueue = DispatchQueue(label: "com.velto.windowmgmt.debuglog.state")
  private nonisolated(unsafe) static var _enabled =
    ProcessInfo.processInfo.environment["VELTO_WINDOW_DEBUG"] == "1"
  private nonisolated(unsafe) static var _handle: FileHandle?
  private nonisolated(unsafe) static var _handleOpened = false

  private static let envForced = ProcessInfo.processInfo.environment["VELTO_WINDOW_DEBUG"] == "1"

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
  }()

  static var isEnabled: Bool {
    stateQueue.sync { _enabled }
  }

  static func setEnabled(_ enabled: Bool) {
    let nowOn = stateQueue.sync { () -> Bool in
      let next = enabled || envForced
      let changed = _enabled != next
      _enabled = next
      return changed && next
    }
    if nowOn {
      log("=== 调试日志开启 ===")
    }
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
    guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Logs", isDirectory: true)
      .appendingPathComponent("Velto", isDirectory: true)
    else { return nil }
    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let url = logsDir.appendingPathComponent("window-management.log")
    if !fm.fileExists(atPath: url.path) {
      fm.createFile(atPath: url.path, contents: nil)
    }
    let handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
    let banner = "\n=== Velto window-management log started \(dateFormatter.string(from: Date())) ===\n"
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
