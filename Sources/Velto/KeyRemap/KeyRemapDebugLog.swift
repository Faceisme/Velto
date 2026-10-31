import Foundation

/// 按键映射调试通道 —— 独立写 ~/Library/Logs/Velto/key-remap.log,
/// 与切换器 / 手势 / 输入法各写各的,互不污染。
///
/// 默认关闭。开启途径:
///   1. 设置页「调试日志」开关 -> KeyRemapDebugLog.setEnabled
///   2. 环境变量 VELTO_KEYREMAP_DEBUG=1(开发期强制开)
enum KeyRemapDebugLog {
  private static let file = DebugLogFile(
    name: "key-remap", fileName: "key-remap.log", environmentKey: "VELTO_KEYREMAP_DEBUG")

  static var fileURL: URL { file.fileURL }
  static var isEnabled: Bool { file.isEnabled }

  static func setEnabled(_ enabled: Bool) {
    if file.setEnabled(enabled) {
      log("=== 调试日志开启 ===")
    }
  }

  static func log(_ message: @autoclosure () -> String) { file.log(message()) }
}
