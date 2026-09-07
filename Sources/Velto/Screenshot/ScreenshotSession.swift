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
  private var scrollHUD: ScrollCaptureHUD?
  private var scrollActionBar: ScrollCaptureActionBar?
  private var scrollEdgeHandle: ScrollCaptureEdgeHandle?
  var scrollController: ScrollCaptureController?
  private var scrollStartTask: Task<Void, Never>?
  private var scrollExtendTask: Task<Void, Never>?
  private var scrollFinishTask: Task<Void, Never>?
  private var hasFinished = false
  /// 输出失败后保留已定稿长图,让用户可直接重试复制/保存。
  private var editedImage: CGImage?
  private var scrollFinalImage: CGImage?
  private var scrollRegion: CGRect?
  private var scrollSnapshot: DisplaySnapshot?
  private var scrollKeyTap: ScrollCaptureKeyTap?
  /// 滚动捕获期间用 beginActivity 抑制 App Nap,避免后台节流影响帧流。
  private var scrollActivity: NSObjectProtocol?

  init(snapshots: [DisplaySnapshot], preferences: ScreenshotPreferences, onFinish: @escaping () -> Void) {
    self.snapshots = snapshots
    self.preferences = preferences
    self.onFinish = onFinish
  }

  func start() {
    // present 内部 NSApp.activate() 会抢前台,先记下原前台 app 以便结束时还原。
    previousApp = NSWorkspace.shared.frontmostApplication
    // 保留触发前的目标 app,滚动时恢复其前台状态。
    let activeAppPID = previousApp?.processIdentifier ?? 0
    let windowCandidates = WindowFrameDetector.snapshot()
    ScreenshotHotCornerGuard.shared.activate(displayIDs: snapshots.map(\.displayID))
    windows = ScreenshotOverlayWindow.present(
      for: snapshots, delegate: self, activeAppPID: activeAppPID, preferences: preferences)
    windows.forEach { $0.screenshotOverlayView.windowCandidates = windowCandidates }
    ScreenshotDebugLog.log("session start: presented \(windows.count) overlay window(s), "
      + "previousApp=\(previousApp?.bundleIdentifier ?? "nil") activeAppPID=\(activeAppPID) "
      + "overlayWindowNumbers=\(windows.map { $0.windowNumber })")
    // 一个覆盖层都没建出来 = 没人能收 Esc,teardown 永远不会被触发,controller 的
    // session 会一直非 nil,之后按快捷键全部静默丢弃。这里主动收尾,别留死会话。
    guard !windows.isEmpty else {
      ScreenshotDebugLog.log("session start: 覆盖层为空,直接收尾")
      NSSound.beep()
      teardown()
      return
    }
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
    case .editScrollResult: return
    case .scroll:
      beginScrollCapture(globalRect: globalRect)
      return
    case .copy, .save:
      guard let snap = snapshots.first(where: { $0.frame.intersects(globalRect) }),
            let base = editedImage ?? ScreenshotCapturer.crop(snap, toPointRect: globalRect) else {
        presentOutputFailure("无法裁剪选区", screenFrame: nil, near: globalRect)
        return
      }
      // 同一渲染器处理标注和裁剪;空元素列表也可能有有效裁剪。
      let image: CGImage
      if let document {
        switch AnnotationRenderer.render(baseImage: base, document: document,
          scale: CGFloat(base.width) / document.canvasSize.width) {
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
      case .scroll, .editScrollResult:
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

  // MARK: - 滚动截图

  private func beginScrollCapture(globalRect: CGRect) {
    guard scrollController == nil,
          scrollStartTask == nil,
          let overlay = activeOverlay,
          let overlayWindow = overlay.window,
          let snapshot = snapshots.first(where: { $0.frame == overlay.globalFrame }) else {
      ScreenshotDebugLog.log("滚动截图启动失败:缺少活动选区或对应屏幕快照")
      NSSound.beep()
      return
    }

    scrollRegion = globalRect
    scrollSnapshot = snapshot
    scrollFinalImage = nil
    scrollActivity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .latencyCritical],
      reason: "滚动长截图捕获")

    // 覆盖层透传;会话级 tap 只允许选区内的竖向滚动及截图控件操作。
    overlayWindow.ignoresMouseEvents = true
    overlay.scrollCaptureActive = true
    overlay.setAnnotationUIHidden(true)

    let hud = ScrollCaptureHUD(onScreen: snapshot.frame, selection: globalRect)
    hud.configureShortcuts(using: preferences)
    hud.orderFrontRegardless()
    hud.update(thumbnail: nil, heightPx: 0,
               hint: "正在准备稳定首帧,请稍候…")
    scrollHUD = hud

    let actionBar = ScrollCaptureActionBar(selectionRect: globalRect, screenFrame: snapshot.frame)
    actionBar.onFinish = { [weak self] in self?.finishScrollCapture(.editScrollResult) }
    actionBar.onCopy = { [weak self] in self?.finishScrollCapture(.copy) }
    actionBar.onSave = { [weak self] in self?.finishScrollCapture(.save) }
    actionBar.onCancel = { [weak self] in self?.cancelScrollCapture() }
    actionBar.orderFrontRegardless()
    scrollActionBar = actionBar

    // 底边下拽手柄:滚到底还差一点没框进来时,把底边拖下来补进长图。
    let edgeHandle = ScrollCaptureEdgeHandle(selectionRect: globalRect, screenFrame: snapshot.frame)
    edgeHandle.onPreview = { [weak self] delta in
      guard let self, let region = self.scrollRegion else { return }
      self.activeOverlay?.setSelectionGlobalRect(CGRect(
        x: region.minX, y: region.minY - delta,
        width: region.width, height: region.height + delta))
      self.updateScrollInputLock()
    }
    edgeHandle.onCommit = { [weak self] delta in
      self?.commitScrollRegionExtension(byPoints: delta)
    }
    edgeHandle.orderFrontRegardless()
    scrollEdgeHandle = edgeHandle

    let controller = ScrollCaptureController(snapshot: snapshot, captureRect: globalRect)
    scrollController = controller
    controller.onProgress = { [weak self, weak controller] thumbnail, height in
      guard let self, let controller, self.scrollController === controller else { return }
      self.scrollHUD?.update(
        thumbnail: thumbnail,
        heightPx: height,
        hint: self.scrollHint(for: controller)
      )
    }
    controller.onIssue = { [weak self, weak controller] _ in
      guard let self, let controller, self.scrollController === controller else { return }
      self.scrollHUD?.update(thumbnail: nil, heightPx: Int(controller.stitchedPixelSize.height),
                            hint: self.scrollHint(for: controller))
      self.updateScrollInputLock()
    }

    let keyTap = ScrollCaptureKeyTap(preferences: preferences, captureRect: scrollEventRect(globalRect))
    keyTap.onCopy = { [weak self] in self?.finishScrollCapture(.copy) }     // Enter/空格/双击 = 完成
    keyTap.onSave = { [weak self] in self?.finishScrollCapture(.save) }     // ⌘S = 保存
    keyTap.onCancel = { [weak self] in self?.cancelScrollCapture() }        // Esc = 结束整个截图
    keyTap.onExit = { [weak self] in self?.cancelScrollCapture() }            // 右键 = 退出整个截图
    keyTap.onScrollActivity = { [weak controller] in controller?.noteManualScroll() }
    scrollKeyTap = keyTap
    updateScrollInputLock()
    if keyTap.start() {
      previousApp?.activate(from: .current)
      ScreenshotDebugLog.log("滚动截图快捷键接管成功:已激活目标 App")
    } else {
      ScreenshotDebugLog.log("滚动截图输入锁定失败,结束会话")
      NSSound.beep()
      cancelScrollCapture()
      showFailureToast("无法锁定滚动输入,请检查辅助功能权限", near: globalRect, within: snapshot.frame)
      return
    }

    ScreenshotDebugLog.log("滚动截图开始(手动滚动): displayID=\(snapshot.displayID) region="
      + "\(Int(globalRect.minX)),\(Int(globalRect.minY)) "
      + "\(Int(globalRect.width))x\(Int(globalRect.height))")

    scrollStartTask = Task { @MainActor [weak self, weak controller] in
      guard let self, let controller else { return }
      let started = await controller.startSession()
      guard !Task.isCancelled, self.scrollController === controller else {
        controller.cancelSession()
        return
      }
      self.scrollStartTask = nil
      guard started else {
        self.scrollController = nil
        ScreenshotDebugLog.log("滚动截图启动失败:无法取得稳定首帧")
        NSSound.beep()
        self.cancelScrollCapture()
        return
      }
      self.updateScrollInputLock()
      self.scrollHUD?.update(thumbnail: nil, heightPx: Int(controller.stitchedPixelSize.height),
                            hint: self.scrollHint(for: controller))
      ScreenshotDebugLog.log("滚动截图控制器已启动: source=SCScreenshotManager core=pixel-overlap manual=true")
    }
  }

  private func scrollEventRect(_ rect: CGRect) -> CGRect {
    ScrollCaptureKeyTap.eventRect(from: rect, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
  }

  private func updateScrollInputLock() {
    guard let region = scrollRegion else { return }
    scrollKeyTap?.update(captureRect: scrollEventRect(region),
      controlRects: [scrollActionBar?.frame, scrollEdgeHandle?.frame, scrollHUD?.frame].compactMap { $0 }.map(scrollEventRect),
      allowsScrolling: scrollController?.isActive == true && scrollStartTask == nil
        && scrollExtendTask == nil && scrollFinishTask == nil && scrollFinalImage == nil
        && scrollController?.issue != .limit)
  }

  private func scrollHint(for controller: ScrollCaptureController) -> String {
    switch controller.issue {
    case .alignment: return "未接上,可向上回滚后继续\n完成将输出预览中已接好的内容"
    case .capture: return "画面尚未稳定,可停稳后继续\n完成将输出预览中已接好的内容"
    case .limit: return "已达长图大小上限,可完成或保存"
    case nil: return "范围已锁定,仅可上下滚动\n\(scrollHUD?.configuredHint ?? "空格复制 · Esc 取消")"
    }
  }

  /// 手柄松手提交底边扩展:控制器把新露出的条带追加进长图,成功则选区/操作条/手柄都落到新位,
  /// 失败(超高度上限、抓帧失败)则边框与手柄弹回原位。忙碌或已定稿时忽略并回弹。
  private func commitScrollRegionExtension(byPoints delta: CGFloat) {
    guard let controller = scrollController,
          let region = scrollRegion,
          let snapshot = scrollSnapshot,
          scrollFinalImage == nil,
          scrollExtendTask == nil,
          scrollFinishTask == nil,
          delta >= 1 else {
      if let region = scrollRegion {
        activeOverlay?.setSelectionGlobalRect(region)
        scrollEdgeHandle?.position(selectionRect: region)
      }
      return
    }
    scrollExtendTask = Task { @MainActor [weak self, weak controller] in
      defer {
        self?.scrollExtendTask = nil
        self?.updateScrollInputLock()
      }
      guard let controller else { return }
      let extended = await controller.extendBottom(byPoints: delta)
      guard let self, self.scrollController === controller else { return }
      let newRegion = extended
        ? CGRect(x: region.minX, y: region.minY - delta,
                 width: region.width, height: region.height + delta)
        : region
      if extended {
        self.scrollRegion = newRegion
        self.scrollActionBar?.reposition(selectionRect: newRegion, screenFrame: snapshot.frame)
        ScreenshotDebugLog.log("滚动截图:底边扩展 +\(Int(delta))pt region="
          + "\(Int(newRegion.minX)),\(Int(newRegion.minY)) "
          + "\(Int(newRegion.width))x\(Int(newRegion.height))")
      } else {
        NSSound.beep()
        ScreenshotDebugLog.log("滚动截图:底边扩展失败,选区回退")
      }
      self.activeOverlay?.setSelectionGlobalRect(newRegion)
      self.scrollEdgeHandle?.position(selectionRect: newRegion)
    }
    updateScrollInputLock()
  }

  func finishScrollCapture(_ action: ScreenshotSessionAction) {
    guard scrollFinishTask == nil else { return }
    scrollFinishTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.scrollFinishTask = nil
        self.updateScrollInputLock()
      }
      await self.scrollStartTask?.value
      await self.scrollExtendTask?.value
      guard !Task.isCancelled else { return }
      await self.finalizeScrollCapture(action)
    }
    updateScrollInputLock()
  }

  private func finalizeScrollCapture(_ action: ScreenshotSessionAction) async {
    ScreenshotDebugLog.log("滚动截图:完成键 action=\(action)")
    let image: CGImage?
    if let scrollFinalImage {
      image = scrollFinalImage
    } else if let controller = scrollController {
      image = await controller.finishSession()
      guard !Task.isCancelled, self.scrollController === controller else { return }
      scrollFinalImage = image
    } else {
      image = nil
    }
    guard let image else {
      ScreenshotDebugLog.log("滚动截图完成失败:没有可输出的长图")
      NSSound.beep()
      if let controller = scrollController {
        scrollHUD?.update(thumbnail: nil, heightPx: Int(controller.stitchedPixelSize.height),
                          hint: scrollHint(for: controller))
      }
      return
    }
    if action == .editScrollResult {
      editedImage = image
      teardownScrollUI()
      activeOverlay?.presentImageForEditing(image)
      NSApp.activate()
      activeOverlay?.window?.makeKeyAndOrderFront(nil)
      return
    }
    let outcome: Result<Void, ScreenshotWriteError>
    switch action {
    case .copy:
      outcome = ScreenshotImageWriter.copyToClipboard(image)
    case .save:
      outcome = ScreenshotImageWriter.save(
        image,
        toDirectory: preferences.saveDirectoryPath,
        format: preferences.imageFormat,
        alsoCopy: preferences.saveAlsoCopiesToClipboard
      ).map { _ in () }
    case .scroll, .editScrollResult:
      return
    }
    switch outcome {
    case .success:
      ScreenshotDebugLog.log("滚动截图输出成功: action=\(action) image="
        + "\(image.width)x\(image.height)")
      teardown()
    case .failure(let error):
      ScreenshotDebugLog.log("滚动截图输出失败: action=\(action) error=\(describe(error))")
      presentOutputFailure(describe(error), screenFrame: scrollSnapshot?.frame, near: scrollRegion ?? .zero)
    }
  }

  /// Esc、取消按钮和右键都结束整个截图会话。
  func cancelScrollCapture() {
    ScreenshotDebugLog.log("滚动截图取消:结束整个会话")
    teardown()
  }

  private func teardownScrollUI() {
    scrollStartTask?.cancel()
    scrollStartTask = nil
    scrollExtendTask?.cancel()
    scrollExtendTask = nil
    scrollFinishTask?.cancel()
    scrollFinishTask = nil
    scrollController?.cancelSession()
    scrollController = nil
    scrollFinalImage = nil
    scrollKeyTap?.stop()
    scrollKeyTap = nil
    scrollHUD?.orderOut(nil)
    scrollHUD = nil
    scrollActionBar?.orderOut(nil)
    scrollActionBar?.onFinish = nil
    scrollActionBar?.onCopy = nil
    scrollActionBar?.onSave = nil
    scrollActionBar?.onCancel = nil
    scrollActionBar = nil
    scrollEdgeHandle?.orderOut(nil)
    scrollEdgeHandle?.onPreview = nil
    scrollEdgeHandle?.onCommit = nil
    scrollEdgeHandle = nil
    scrollSnapshot = nil
    scrollRegion = nil
    activeOverlay?.window?.ignoresMouseEvents = false
    activeOverlay?.scrollCaptureActive = false
    if let scrollActivity {
      ProcessInfo.processInfo.endActivity(scrollActivity)
      self.scrollActivity = nil
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
    guard !hasFinished else { return }
    hasFinished = true
    editedImage = nil
    teardownScrollUI()
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
