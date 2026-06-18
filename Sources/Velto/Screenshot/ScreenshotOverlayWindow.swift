import AppKit

/// 会话内的确认动作:复制 / 保存 / 滚动长截图(滚动为 Phase 3 占位)。
enum ScreenshotSessionAction { case copy, save, scroll }

@MainActor
protocol ScreenshotOverlayDelegate: AnyObject {
  func overlayDidCancel()
  /// 用户在选区上确认某个动作;globalRect 为 AppKit 全局 rect(左下原点)。
  func overlayDidRequest(_ action: ScreenshotSessionAction, globalRect: CGRect)
}

@MainActor
final class ScreenshotOverlayWindow: NSWindow {
  private let overlayView: ScreenshotOverlayView

  init(screenSnapshot snap: DisplaySnapshot, delegate: ScreenshotOverlayDelegate) {
    overlayView = ScreenshotOverlayView(frame: CGRect(origin: .zero, size: snap.frame.size))
    overlayView.snapshotImage = snap.image
    overlayView.globalFrame = snap.frame   // 本窗口在全局点坐标(左下原点)中的 frame,用于点↔全局换算
    overlayView.scale = snap.scale
    overlayView.delegate = delegate
    super.init(contentRect: snap.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    level = .screenSaver            // 高于普通窗口;实机确认不挡系统授权弹窗
    ignoresMouseEvents = false
    acceptsMouseMovedEvents = true   // 否则收不到 mouseMoved,选窗高亮失效
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
