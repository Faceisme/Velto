import AppKit

@MainActor
final class ScreenshotController {
  static let shared = ScreenshotController()
  private var session: ScreenshotSession?
  private init() {}

  /// 全局触发键命中后切到主线程调用。已有会话或权限缺失则忽略/引导。
  func beginSession() {
    guard session == nil else { return }
    guard GestureStore.shared.preferences.screenshot.enabled else { return }
    guard PermissionManager.isScreenRecordingTrusted else {
      PermissionManager.requestScreenRecordingPrompt()
      return
    }
    let prefs = GestureStore.shared.preferences.screenshot
    Task { @MainActor in
      guard let snaps = try? await ScreenshotCapturer.captureAllDisplays(), !snaps.isEmpty else { return }
      let s = ScreenshotSession(snapshots: snaps, preferences: prefs) { [weak self] in self?.session = nil }
      self.session = s
      s.start()
    }
  }

  func cancelSession() { session = nil }
}
