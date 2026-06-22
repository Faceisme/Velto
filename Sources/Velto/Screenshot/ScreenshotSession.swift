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
  /// 输出失败时工具栏附近的非阻塞提示窗口;3 秒后自动消失。
  private var failureToast: NSWindow?
  /// 触发截图前的前台 app;结束时恢复,避免 NSApp.activate 抢占后系统乱提其它窗口。
  private var previousApp: NSRunningApplication?

  init(snapshots: [DisplaySnapshot], preferences: ScreenshotPreferences, onFinish: @escaping () -> Void) {
    self.snapshots = snapshots
    self.preferences = preferences
    self.onFinish = onFinish
  }

  func start() {
    // present 内部 NSApp.activate() 会抢前台,先记下原前台 app 以便结束时还原。
    previousApp = NSWorkspace.shared.frontmostApplication
    // 触发瞬间的前台 app = 用户眼中的"活动窗口"所属 app;窗口自动识别据此只认它的窗口。
    let activeAppPID = previousApp?.processIdentifier ?? 0
    ScreenshotHotCornerGuard.shared.activate(displayIDs: snapshots.map(\.displayID))
    windows = ScreenshotOverlayWindow.present(for: snapshots, delegate: self, activeAppPID: activeAppPID)
    ScreenshotDebugLog.log("session start: presented \(windows.count) overlay window(s), "
      + "previousApp=\(previousApp?.bundleIdentifier ?? "nil") activeAppPID=\(activeAppPID) "
      + "overlayWindowNumbers=\(windows.map { $0.windowNumber })")
  }

  /// 外部(如热键)取消会话:dismiss 所有覆盖窗口并回收。
  func cancel() { teardown() }

  func overlayDidCancel() { teardown() }

  /// 锁定唯一活动 overlay:只有它能继续编辑,其余屏禁用框选。
  func overlayDidActivateSelection(_ overlay: ScreenshotOverlayView) {
    activeOverlay = overlay
    ScreenshotDebugLog.log("selection activated on overlay globalFrame="
      + "\(Int(overlay.globalFrame.minX)),\(Int(overlay.globalFrame.minY))")
    for window in windows {
      window.setSelectionEnabled(window.screenshotOverlayView === overlay)
    }
  }

  func overlayDidRequest(
    _ action: ScreenshotSessionAction,
    globalRect: CGRect,
    document: AnnotationDocument?
  ) {
    ScreenshotDebugLog.log("request action=\(action) globalRect="
      + "\(Int(globalRect.minX)),\(Int(globalRect.minY)) \(Int(globalRect.width))x\(Int(globalRect.height)) "
      + "annotations=\(document?.elements.count ?? 0)")
    switch action {
    case .scroll:
      // Phase 3 占位:本期不实现滚动拼接,轻提示后留在会话。
      ScreenshotDebugLog.log("scroll capture not implemented yet")
      NSSound.beep()
      return
    case .copy, .save:
      guard let snap = snapshots.first(where: { $0.frame.intersects(globalRect) }),
            let base = ScreenshotCapturer.crop(snap, toPointRect: globalRect) else {
        presentOutputFailure("无法裁剪选区", screenFrame: nil, near: globalRect)
        return
      }
      // 有标注:用与编辑预览同一台渲染器合成,保证导出像素 == 屏上所见;无标注直接用裁剪原图。
      let image: CGImage
      if let document, !document.elements.isEmpty {
        switch AnnotationRenderer.render(baseImage: base, document: document, scale: snap.scale) {
        case .success(let composited):
          image = composited
        case .failure(let error):
          presentOutputFailure("合成标注失败:\(error)", screenFrame: snap.frame, near: globalRect)
          return
        }
      } else {
        image = base
      }
      // 复制 / 保存任一失败都保留会话(overlay、document、history 不动),只有成功才撤窗。
      let outcome: Result<Void, ScreenshotWriteError>
      switch action {
      case .copy:
        outcome = ScreenshotImageWriter.copyToClipboard(image)
      case .save:
        outcome = ScreenshotImageWriter.save(
          image, toDirectory: preferences.saveDirectoryPath,
          format: preferences.imageFormat,
          alsoCopy: preferences.saveAlsoCopiesToClipboard
        ).map { _ in () }
      case .scroll:
        return  // 不可达:scroll 已在上面分支处理。
      }
      switch outcome {
      case .success:
        ScreenshotDebugLog.log("action=\(action) success")
        teardown()
      case .failure(let error):
        presentOutputFailure(describe(error), screenFrame: snap.frame, near: globalRect)
      }
    }
  }

  // MARK: - 失败保留

  /// 输出失败统一入口:记录日志、蜂鸣、工具栏附近 3 秒非阻塞提示,并**保留**整个标注会话,
  /// 让用户可重试或调整(不 teardown,document 与 history 原样保留)。
  private func presentOutputFailure(_ reason: String, screenFrame: CGRect?, near globalRect: CGRect) {
    ScreenshotDebugLog.log("output failed: \(reason)")
    NSSound.beep()
    let clampFrame = screenFrame
      ?? snapshots.first(where: { $0.frame.intersects(globalRect) })?.frame
      ?? activeOverlay?.globalFrame
    showFailureToast("截图输出失败,已保留标注", near: globalRect, within: clampFrame)
  }

  /// 把失败原因转成给用户看的简短中文。
  private func describe(_ error: ScreenshotWriteError) -> String {
    switch error {
    case .encodingFailed: return "图片编码失败"
    case .clipboardRejected: return "系统剪贴板拒绝写入"
    case .fileWriteFailed(let detail): return "写入文件失败:\(detail)"
    }
  }

  /// 选区下方(工具栏一侧)弹一个圆角提示窗,3 秒后自动隐去;不抢键盘、不阻塞编辑。
  private func showFailureToast(_ message: String, near globalRect: CGRect, within screenFrame: CGRect?) {
    failureToast?.orderOut(nil)

    let label = NSTextField(labelWithString: message)
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = .white
    label.alignment = .center
    label.sizeToFit()

    let padX: CGFloat = 16, padY: CGFloat = 10
    let size = NSSize(width: label.frame.width + padX * 2, height: label.frame.height + padY * 2)

    var origin = CGPoint(x: globalRect.midX - size.width / 2, y: globalRect.minY - size.height - 12)
    if let bounds = screenFrame {
      // 选区贴底时翻到选区上方,再把整窗夹回屏内。
      if origin.y < bounds.minY + 8 { origin.y = globalRect.maxY + 12 }
      origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
      origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - size.height - 8)
    }

    let toast = NSWindow(
      contentRect: CGRect(origin: origin, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    toast.isOpaque = false
    toast.backgroundColor = .clear
    toast.level = .screenSaver
    toast.ignoresMouseEvents = true
    toast.hasShadow = false
    toast.animationBehavior = .none
    toast.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

    let container = NSView(frame: CGRect(origin: .zero, size: size))
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
    container.layer?.cornerRadius = 8
    label.frame = CGRect(x: padX, y: padY, width: label.frame.width, height: label.frame.height)
    container.addSubview(label)
    toast.contentView = container
    toast.orderFrontRegardless()
    failureToast = toast

    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak toast] in
      toast?.orderOut(nil)
      if self?.failureToast === toast { self?.failureToast = nil }
    }
  }

  private func teardown() {
    failureToast?.orderOut(nil)
    failureToast = nil
    // 先收尾标注 UI(结束文字编辑、释放 history 与马赛克缓存),再撤窗。
    windows.forEach { $0.screenshotOverlayView.tearDownAnnotationUI() }
    windows.forEach { $0.dismiss() }
    windows = []
    activeOverlay = nil
    ScreenshotHotCornerGuard.shared.deactivate()
    // 把前台还给截图前的 app(取消/完成皆然),否则 macOS 会把某个后台窗口提到最前。
    if let previousApp, previousApp != .current {
      previousApp.activate(from: .current)
    }
    previousApp = nil
    onFinish()
  }
}
