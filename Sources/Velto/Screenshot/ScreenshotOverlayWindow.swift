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
    let frame = CGRect(origin: .zero, size: snap.frame.size)
    overlayView = ScreenshotOverlayView(frame: frame)
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
    animationBehavior = .none       // 关闭出现/消失的缩放动画,避免整屏“duang”地弹一下
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

    // 分层渲染(解决拖拽卡顿):下层是“静态快照背景”——全屏快照只画一次、由 GPU 合成;
    // 上层 overlayView 每帧只铺半透明暗罩并把选区/悬停区 clear 成透明,露出下层背景。
    // 两层必须都 layer-backed(由容器 wantsLayer 向下传递),上层 clear 才能正确露出下层。
    let container = NSView(frame: frame)
    container.wantsLayer = true
    let background = ScreenshotSnapshotBackgroundView(frame: frame)
    background.image = snap.image
    background.autoresizingMask = [.width, .height]
    overlayView.autoresizingMask = [.width, .height]
    container.addSubview(background)
    container.addSubview(overlayView)
    contentView = container
    initialFirstResponder = overlayView   // 保证键盘 空格/⌘S/Esc 落到覆盖视图
  }

  override var canBecomeKey: Bool { true }

  func dismiss() { orderOut(nil) }

  /// 为每块屏建一个覆盖窗口并显示;第一个设为 key 以接键盘。
  static func present(
    for snapshots: [DisplaySnapshot],
    delegate: ScreenshotOverlayDelegate
  ) -> [ScreenshotOverlayWindow] {
    // 菜单栏 agent 应用默认非前台;先激活,覆盖层才能立即接收键盘与“首次”鼠标拖拽。
    NSApp.activate()
    let windows = snapshots.map { ScreenshotOverlayWindow(screenSnapshot: $0, delegate: delegate) }
    for w in windows { w.orderFrontRegardless() }
    if let key = windows.first {
      key.makeKey()
      key.makeFirstResponder(key.overlayView)   // 覆盖视图现在是子视图,显式设为第一响应者保证键盘
    }
    return windows
  }
}

/// 截图覆盖层的静态快照背景:全屏快照只在显示时画一次,之后由 GPU 合成,
/// 拖拽期间不重绘;上层交互视图通过 clear “挖洞”露出本视图,从而避免每帧重绘全屏快照。
final class ScreenshotSnapshotBackgroundView: NSView {
  var image: CGImage? { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext, let image else { return }
    ctx.draw(image, in: bounds)   // 与原覆盖层同样的非 flipped 绘制,方向一致
  }
}
