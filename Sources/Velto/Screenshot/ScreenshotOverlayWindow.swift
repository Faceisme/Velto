import AppKit

@MainActor
protocol ScreenshotOverlayDelegate: AnyObject {
  func overlayDidCancel()
}

@MainActor
final class ScreenshotOverlayWindow: NSWindow {
  private let overlayView: ScreenshotOverlayView

  init(screenSnapshot snap: DisplaySnapshot, delegate: ScreenshotOverlayDelegate) {
    overlayView = ScreenshotOverlayView(frame: CGRect(origin: .zero, size: snap.frame.size))
    overlayView.snapshotImage = snap.image
    overlayView.delegate = delegate
    super.init(contentRect: snap.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    level = .screenSaver            // 高于普通窗口;实机确认不挡系统授权弹窗
    ignoresMouseEvents = false
    hasShadow = false
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    contentView = overlayView
  }

  override var canBecomeKey: Bool { true }

  func dismiss() { orderOut(nil) }

  /// 为每块屏建一个覆盖窗口并显示;第一个设为 key 以接键盘。
  static func present(
    for snapshots: [DisplaySnapshot],
    delegate: ScreenshotOverlayDelegate
  ) -> [ScreenshotOverlayWindow] {
    let windows = snapshots.map { ScreenshotOverlayWindow(screenSnapshot: $0, delegate: delegate) }
    for w in windows { w.orderFrontRegardless() }
    windows.first?.makeKey()
    return windows
  }
}
