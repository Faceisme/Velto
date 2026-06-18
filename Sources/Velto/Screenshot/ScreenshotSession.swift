import AppKit
import VeltoAnnotationCore

@MainActor
final class ScreenshotSession: ScreenshotOverlayDelegate {
  private let snapshots: [DisplaySnapshot]
  private let preferences: ScreenshotPreferences
  private let onFinish: () -> Void
  private var windows: [ScreenshotOverlayWindow] = []
  /// 多屏下唯一允许编辑的活动 overlay;其余屏被禁用框选。
  private weak var activeOverlay: ScreenshotOverlayView?

  init(snapshots: [DisplaySnapshot], preferences: ScreenshotPreferences, onFinish: @escaping () -> Void) {
    self.snapshots = snapshots
    self.preferences = preferences
    self.onFinish = onFinish
  }

  func start() {
    ScreenshotHotCornerGuard.shared.activate(displayIDs: snapshots.map(\.displayID))
    windows = ScreenshotOverlayWindow.present(for: snapshots, delegate: self)
  }

  /// 外部(如热键)取消会话:dismiss 所有覆盖窗口并回收。
  func cancel() { teardown() }

  func overlayDidCancel() { teardown() }

  /// 锁定唯一活动 overlay:只有它能继续编辑,其余屏禁用框选。
  func overlayDidActivateSelection(_ overlay: ScreenshotOverlayView) {
    activeOverlay = overlay
    for window in windows {
      window.setSelectionEnabled(window.screenshotOverlayView === overlay)
    }
  }

  func overlayDidRequest(
    _ action: ScreenshotSessionAction,
    globalRect: CGRect,
    document: AnnotationDocument?
  ) {
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
    // 先收尾标注 UI(结束文字编辑、释放 history 与马赛克缓存),再撤窗。
    windows.forEach { $0.screenshotOverlayView.tearDownAnnotationUI() }
    windows.forEach { $0.dismiss() }
    windows = []
    activeOverlay = nil
    ScreenshotHotCornerGuard.shared.deactivate()
    onFinish()
  }
}
