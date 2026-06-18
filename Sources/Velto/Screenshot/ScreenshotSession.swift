import AppKit

@MainActor
final class ScreenshotSession: ScreenshotOverlayDelegate {
  private let snapshots: [DisplaySnapshot]
  private let preferences: ScreenshotPreferences
  private let onFinish: () -> Void
  private var windows: [ScreenshotOverlayWindow] = []

  init(snapshots: [DisplaySnapshot], preferences: ScreenshotPreferences, onFinish: @escaping () -> Void) {
    self.snapshots = snapshots
    self.preferences = preferences
    self.onFinish = onFinish
  }

  func start() {
    windows = ScreenshotOverlayWindow.present(for: snapshots, delegate: self)
  }

  /// 外部(如热键)取消会话:dismiss 所有覆盖窗口并回收。
  func cancel() { teardown() }

  func overlayDidCancel() { teardown() }

  func overlayDidRequest(_ action: ScreenshotSessionAction, globalRect: CGRect) {
    switch action {
    case .scroll:
      // Phase 3 占位:本期不实现滚动拼接,轻提示后留在会话。
      ScreenshotDebugLog.log("scroll capture not implemented yet")
      NSSound.beep()
      return
    case .copy, .save:
      guard let snap = snapshots.first(where: { $0.frame.intersects(globalRect) }),
            let image = ScreenshotCapturer.crop(snap, toPointRect: globalRect) else {
        NSSound.beep()
        teardown()
        return
      }
      if action == .copy {
        ScreenshotImageWriter.copyToClipboard(image)
      } else {
        ScreenshotImageWriter.save(image, toDirectory: preferences.saveDirectoryPath,
                                   format: preferences.imageFormat,
                                   alsoCopy: preferences.saveAlsoCopiesToClipboard)
      }
      teardown()
    }
  }

  private func teardown() {
    windows.forEach { $0.dismiss() }
    windows = []
    onFinish()
  }
}
