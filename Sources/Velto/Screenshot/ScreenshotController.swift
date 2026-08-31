import AppKit

@MainActor
final class ScreenshotController {
  static let shared = ScreenshotController()
  private var session: ScreenshotSession?
  private var isStarting = false
  private init() {}

  /// 全局触发键命中后切到主线程调用。已有会话/正在启动则忽略;权限判定挪到抓屏失败之后。
  func beginSession() {
    guard session == nil, !isStarting else { return }
    guard GestureStore.shared.preferences.screenshot.enabled else { return }
    let prefs = GestureStore.shared.preferences.screenshot
    // 按偏好开关调试日志(环境变量 VELTO_SCREENSHOT_DEBUG=1 仍可强制开)。
    ScreenshotDebugLog.setEnabled(prefs.debugLoggingEnabled)
    ScreenshotDebugLog.log("=== beginSession === trigger=\(prefs.triggerShortcut?.displayName ?? "nil")")
    isStarting = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isStarting = false }
      guard let snaps = try? await ScreenshotCapturer.captureAllDisplays(), !snaps.isEmpty else {
        // 抓不到才是真没权限。`CGPreflightScreenCaptureAccess()` 在 app 冷启动后
        // 的几十秒里会假阴性(权限有,却返回 false),当年拿它做前置门禁的结果是
        // 开机后按快捷键静默无反应。现在只在抓屏真失败后用它来判断是不是要引导授权。
        let trusted = PermissionManager.isScreenRecordingTrusted
        ScreenshotDebugLog.log("capture failed or no displays; screenRecordingTrusted=\(trusted)")
        NSSound.beep()
        if !trusted { PermissionManager.requestScreenRecordingPrompt() }
        return
      }
      ScreenshotDebugLog.log("captured \(snaps.count) display(s): "
        + snaps.map { "id=\($0.displayID) frame=\(Int($0.frame.minX)),\(Int($0.frame.minY)) "
          + "\(Int($0.frame.width))x\(Int($0.frame.height)) scale=\($0.scale)" }.joined(separator: " | "))
      let s = ScreenshotSession(snapshots: snaps, preferences: prefs) { [weak self] in self?.session = nil }
      self.session = s
      s.start()
    }
  }

  func cancelSession() { session?.cancel() }
}
