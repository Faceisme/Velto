import AppKit

@MainActor
final class ScreenshotController {
  static let shared = ScreenshotController()
  private var session: ScreenshotSession?
  private var isStarting = false
  private init() {}

  /// 全局触发键命中后切到主线程调用。已有会话/正在启动/权限缺失则忽略/引导。
  func beginSession() {
    guard session == nil, !isStarting else { return }
    guard GestureStore.shared.preferences.screenshot.enabled else { return }
    guard PermissionManager.isScreenRecordingTrusted else {
      PermissionManager.requestScreenRecordingPrompt()
      return
    }
    let prefs = GestureStore.shared.preferences.screenshot
    // 按偏好开关调试日志(环境变量 VELTO_SCREENSHOT_DEBUG=1 仍可强制开)。
    ScreenshotDebugLog.setEnabled(prefs.debugLoggingEnabled)
    ScreenshotDebugLog.log("=== beginSession === trigger=\(prefs.triggerShortcut?.displayName ?? "nil")")
    isStarting = true
    Task { @MainActor in
      defer { isStarting = false }
      guard let snaps = try? await ScreenshotCapturer.captureAllDisplays(), !snaps.isEmpty else {
        ScreenshotDebugLog.log("capture failed or no displays")
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
