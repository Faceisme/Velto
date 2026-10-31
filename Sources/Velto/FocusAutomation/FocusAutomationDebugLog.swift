import Foundation

/// 专注自动化调试通道 —— 写 ~/Library/Logs/Velto/focus-automation.log。
///
/// 默认关闭。开启途径:
///   1. 设置页「调试日志」开关 -> FocusAutomationDebugLog.setEnabled
///   2. 环境变量 VELTO_FOCUS_DEBUG=1(开发期强制开)
enum FocusAutomationDebugLog {
  private static let file = DebugLogFile(
    name: "focus-automation", fileName: "focus-automation.log", environmentKey: "VELTO_FOCUS_DEBUG")

  static var fileURL: URL { file.fileURL }
  static var isEnabled: Bool { file.isEnabled }
  static func setEnabled(_ enabled: Bool) { file.setEnabled(enabled) }
  static func log(_ message: @autoclosure () -> String) { file.log(message()) }
}
