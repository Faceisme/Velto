import Foundation

enum ScreenshotDebugLog {
  private static let stateQueue = DispatchQueue(label: "com.velto.screenshot.debuglog.state")
  private static let envForced = ProcessInfo.processInfo.environment["VELTO_SCREENSHOT_DEBUG"] == "1"
  private nonisolated(unsafe) static var _enabled = ProcessInfo.processInfo.environment["VELTO_SCREENSHOT_DEBUG"] == "1"
  private nonisolated(unsafe) static var _handle: FileHandle?
  private nonisolated(unsafe) static var _handleOpened = false

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
  }()

  static var isEnabled: Bool { stateQueue.sync { _enabled } }
  static func setEnabled(_ enabled: Bool) { stateQueue.sync { _enabled = enabled || envForced } }

  static let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Logs/Velto/screenshot-debug.log")

  static func log(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    let line = "[\(dateFormatter.string(from: Date()))] \(message())\n"
    FileHandle.standardError.write(Data(line.utf8))
    if let handle = fileHandle() { try? handle.write(contentsOf: Data(line.utf8)) }
  }

  private static func fileHandle() -> FileHandle? {
    stateQueue.sync {
      if !_handleOpened { _handleOpened = true; _handle = openLogFile() }
      return _handle
    }
  }

  private static func openLogFile() -> FileHandle? {
    let fm = FileManager.default
    let url = fileURL
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
    let handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
    return handle
  }
}
