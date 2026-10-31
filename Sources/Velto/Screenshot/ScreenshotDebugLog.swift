import Foundation

enum ScreenshotDebugLog {
  private static let file = DebugLogFile(
    name: "screenshot", fileName: "screenshot-debug.log", environmentKey: "VELTO_SCREENSHOT_DEBUG")

  static var fileURL: URL { file.fileURL }
  static var isEnabled: Bool { file.isEnabled }
  static func setEnabled(_ enabled: Bool) { file.setEnabled(enabled) }
  static func log(_ message: @autoclosure () -> String) { file.log(message()) }
}
