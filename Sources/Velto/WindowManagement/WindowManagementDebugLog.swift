import Foundation

/// 窗口管理调试通道 —— 独立写 ~/Library/Logs/Velto/window-management.log,
/// 与按键映射 / 切换器 / 手势 / 输入法各写各的,互不污染。
///
/// 默认关闭。开启途径:
///   1. 设置页「窗口管理 → 调试日志」开关 -> WindowManagementDebugLog.setEnabled
///   2. 环境变量 VELTO_WINDOW_DEBUG=1(开发期强制开)
///
enum WindowManagementDebugLog {
  private static let file = DebugLogFile(
    name: "window-management", fileName: "window-management.log", environmentKey: "VELTO_WINDOW_DEBUG")

  static var fileURL: URL { file.fileURL }
  static var isEnabled: Bool { file.isEnabled }

  static func setEnabled(_ enabled: Bool) {
    if file.setEnabled(enabled) {
      log("=== 调试日志开启 ===")
    }
    // 不看是否变化 —— VELTO_WINDOW_DEBUG=1 时开关出生就是开的,
    // 启动那次 setEnabled 不算"变化",不无条件调心跳就永远起不来。
    setHeartbeat(isEnabled)
  }

  /// 主线程心跳 —— 只写时间戳,不做任何 AX 调用,不碰任何别的进程。
  ///
  /// 手势日志只在用户划手势时才有行,而冻结时用户往往根本不划:2026-08-27 那次
  /// Telegram 冻结,三个日志一起空了 6 分 24 秒,事后完全分不清是 Velto 主线程被
  /// 堵死、还是压根没人操作。心跳把这两种情况拆开 —— 定时器挂在**主 runloop**
  /// 上,主线程一被堵,tick 就迟到,迟到多少毫秒直接写进日志。
  ///
  /// 用 `.common` 模式:默认模式在拖窗口 / 菜单弹出的 tracking loop 里不触发,
  /// 那会报出一堆假迟到。
  private static let heartbeatInterval: TimeInterval = 5
  // 全部只在主线程读写(timer 挂在主 runloop 上),Swift 6 的并发检查看不出来,
  // 所以标 nonisolated(unsafe)。
  private nonisolated(unsafe) static var heartbeat: Timer?
  private nonisolated(unsafe) static var heartbeatExpected = Date()
  private nonisolated(unsafe) static var heartbeatWorstJitter: TimeInterval = 0
  private nonisolated(unsafe) static var heartbeatLastReport = Date()

  private static func setHeartbeat(_ on: Bool) {
    DispatchQueue.main.async {
      heartbeat?.invalidate()
      heartbeat = nil
      guard on else { return }

      heartbeatExpected = Date().addingTimeInterval(heartbeatInterval)
      heartbeatWorstJitter = 0
      heartbeatLastReport = Date()

      let timer = Timer(timeInterval: heartbeatInterval, repeats: true) { _ in
        let now = Date()
        let late = now.timeIntervalSince(heartbeatExpected)
        heartbeatExpected = now.addingTimeInterval(heartbeatInterval)
        heartbeatWorstJitter = max(heartbeatWorstJitter, late)
        // 迟到就立刻报;正常时每分钟才留一行,不然心跳能把日志淹了
        // (5s 一行 = 每小时 720 行,grep 起来全是噪音)。
        if late > heartbeatInterval / 2 {
          log("💓 心跳迟到 \(Int(late * 1000))ms —— 这段时间主线程被堵住了")
          heartbeatLastReport = now
          heartbeatWorstJitter = 0
        } else if now.timeIntervalSince(heartbeatLastReport) >= 60 {
          log("💓 心跳正常(过去 60s 最大抖动 \(Int(heartbeatWorstJitter * 1000))ms)")
          heartbeatLastReport = now
          heartbeatWorstJitter = 0
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      heartbeat = timer
    }
  }

  static func log(_ message: @autoclosure () -> String) { file.log(message()) }
}
