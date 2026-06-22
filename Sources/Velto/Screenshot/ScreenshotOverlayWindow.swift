import AppKit
import VeltoAnnotationCore

/// 会话内的确认动作:复制 / 保存 / 滚动长截图(滚动为 Phase 3 占位)。
enum ScreenshotSessionAction { case copy, save, scroll }

@MainActor
protocol ScreenshotOverlayDelegate: AnyObject {
  /// 某块屏幕的选区刚被激活并挂上标注 UI;会话据此锁定唯一活动 overlay。
  func overlayDidActivateSelection(_ overlay: ScreenshotOverlayView)
  func overlayDidCancel()
  /// 用户在选区上确认某个动作;globalRect 为 AppKit 全局 rect(左下原点)。
  /// document 为该选区的标注文档(无标注时可能为 nil),供输出阶段合成。
  func overlayDidRequest(
    _ action: ScreenshotSessionAction,
    globalRect: CGRect,
    document: AnnotationDocument?
  )
}

@MainActor
final class ScreenshotOverlayWindow: NSWindow {
  private let overlayView: ScreenshotOverlayView

  init(screenSnapshot snap: DisplaySnapshot, delegate: ScreenshotOverlayDelegate, activeAppPID: pid_t) {
    overlayView = ScreenshotOverlayView(frame: CGRect(origin: .zero, size: snap.frame.size))
    overlayView.snapshotImage = snap.image
    overlayView.globalFrame = snap.frame   // 本窗口在全局点坐标(左下原点)中的 frame,用于点↔全局换算
    overlayView.scale = snap.scale
    overlayView.activeAppPID = activeAppPID
    overlayView.delegate = delegate
    super.init(contentRect: snap.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    level = .screenSaver            // 高于普通窗口;实机确认不挡系统授权弹窗
    ignoresMouseEvents = false
    acceptsMouseMovedEvents = true   // 否则收不到 mouseMoved,选窗高亮失效
    hasShadow = false
    animationBehavior = .none       // 关闭出现/消失的缩放动画,避免整屏“duang”地弹一下
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    contentView = overlayView
  }

  override var canBecomeKey: Bool { true }

  /// 暴露内部覆盖层视图,供会话锁定活动屏与拆除标注 UI。
  var screenshotOverlayView: ScreenshotOverlayView { overlayView }

  /// 非活动屏在另一块屏激活选区后被禁用框选,只剩压暗的快照。
  func setSelectionEnabled(_ enabled: Bool) {
    overlayView.selectionEnabled = enabled
  }

  func dismiss() { orderOut(nil) }

  /// 为每块屏建一个覆盖窗口并显示;第一个设为 key 以接键盘。
  static func present(
    for snapshots: [DisplaySnapshot],
    delegate: ScreenshotOverlayDelegate,
    activeAppPID: pid_t
  ) -> [ScreenshotOverlayWindow] {
    // 菜单栏 agent 应用默认非前台;先激活,覆盖层才能立即接收键盘与“首次”鼠标拖拽。
    NSApp.activate()
    let windows = snapshots.map {
      ScreenshotOverlayWindow(screenSnapshot: $0, delegate: delegate, activeAppPID: activeAppPID)
    }
    for w in windows { w.orderFrontRegardless() }
    windows.first?.makeKey()
    return windows
  }
}
