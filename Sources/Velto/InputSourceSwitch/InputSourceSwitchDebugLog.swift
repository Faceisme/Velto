import Foundation

/// 输入法切换调试通道 —— 独立写 ~/Library/Logs/Velto/input-source-switch.log,
/// 与切换器/手势各写各的,互不污染。
///
/// 默认关闭。开启途径:
///   1. 设置页「调试日志」开关 -> InputSourceSwitchDebugLog.setEnabled
///   2. 环境变量 VELTO_INPUT_SOURCE_DEBUG=1(开发期强制开)
enum InputSourceSwitchDebugLog {
  private static let file = DebugLogFile(
    name: "input-source-switch", fileName: "input-source-switch.log", environmentKey: "VELTO_INPUT_SOURCE_DEBUG")

  static var fileURL: URL { file.fileURL }
  static var isEnabled: Bool { file.isEnabled }
  static func setEnabled(_ enabled: Bool) { file.setEnabled(enabled) }
  static func log(_ message: @autoclosure () -> String) { file.log(message()) }
}
