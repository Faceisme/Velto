import Cocoa
import Synchronization
@preconcurrency import CoreFoundation

/// 滚动截图期间全局接管完成快捷键,目标 App 保持前台时仍可结束会话。
final class ScrollCaptureKeyTap: @unchecked Sendable {
  static let active = Mutex<ScrollCaptureKeyTap?>(nil)
  static var current: ScrollCaptureKeyTap? { active.withLock { $0 } }
  static var isCapturing: Bool { current != nil }
  static func eventRect(from rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
  }
  private enum Action: Sendable { case copy, save, cancel, exit, scroll }

  var onCopy: (() -> Void)?
  var onSave: (() -> Void)?
  var onCancel: (() -> Void)?
  var onExit: (() -> Void)?
  /// 与其它动作一样切回主线程,供 MainActor 滚动控制器安全处理。
  var onScrollActivity: (() -> Void)?

  private let copyKeyCode: UInt16
  private let cancelKeyCode: UInt16
  private let saveKeyCode: UInt16
  private let saveModifierFlags: UInt64

  private let lifecycleLock = NSLock()
  /// 坐标使用 CGEvent 的主屏左上原点,由主线程在选区/手柄变化时更新。
  private var captureRect: CGRect
  private var controlRects: [CGRect] = []
  private var allowsScrolling = false
  private var draggingControl = false
  private var verticalGesture = false
  private var callbackGeneration = 0
  private var hasStopped = false
  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var tapRunLoop: CFRunLoop?
  /// 运行中的 Thread 由系统保活;这里弱持有以避免 thread 闭包与 self 构成引用环。
  private weak var tapThread: Thread?
  private var threadStopped: DispatchSemaphore?

  init(preferences: ScreenshotPreferences, captureRect: CGRect) {
    self.captureRect = captureRect
    copyKeyCode = preferences.copyKeyCode
    cancelKeyCode = preferences.cancelKeyCode
    saveKeyCode = preferences.saveShortcut.keyCode
    saveModifierFlags = ModifierFormatter.normalizedRawValue(
      from: CGEventFlags(rawValue: preferences.saveShortcut.modifierFlags)
    )
  }

  func update(captureRect: CGRect, controlRects: [CGRect], allowsScrolling: Bool) {
    lifecycleLock.lock()
    self.captureRect = captureRect
    self.controlRects = controlRects
    self.allowsScrolling = allowsScrolling
    lifecycleLock.unlock()
  }

  var scrollInputEnabled: Bool {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    return allowsScrolling && !draggingControl
  }

  /// 创建会话级 event tap。失败通常表示辅助功能权限或系统资源不可用。
  func start() -> Bool {
    lifecycleLock.lock()
    let alreadyStarted = tap != nil
    lifecycleLock.unlock()
    guard !alreadyStarted else { return true }

    // 监听完成快捷键、鼠标完成/退出,并观察滚轮活动以便只在滚动静止后接纳稳定帧。
    let types: [CGEventType] = [.keyDown, .keyUp, .scrollWheel,
      .leftMouseDown, .leftMouseDragged, .leftMouseUp,
      .rightMouseDown, .rightMouseDragged, .rightMouseUp,
      .otherMouseDown, .otherMouseDragged, .otherMouseUp]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard let tap = CGEvent.tapCreate(
      tap: .cghidEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: Self.tapCallback,
      userInfo: refcon
    ) else { return false }

    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      return false
    }

    let ready = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    let thread = Thread { [self] in
      defer {
        clearTapRunLoop(for: Thread.current)
        stopped.signal()
      }
      guard let runLoop = CFRunLoopGetCurrent() else {
        ready.signal()
        return
      }
      guard installTapRunLoop(runLoop, for: Thread.current) else {
        ready.signal()
        return
      }
      CFRunLoopAddSource(runLoop, source, .commonModes)
      ready.signal()
      CFRunLoopRun()
      CFRunLoopRemoveSource(runLoop, source, .commonModes)
    }
    thread.name = "com.face.velto.screenshot.scroll-keytap"
    thread.qualityOfService = .userInteractive

    lifecycleLock.lock()
    hasStopped = false
    self.tap = tap
    runLoopSource = source
    tapThread = thread
    threadStopped = stopped
    lifecycleLock.unlock()

    thread.start()
    ready.wait()
    lifecycleLock.lock()
    let didStart = self.tap === tap && tapRunLoop != nil
    lifecycleLock.unlock()
    guard didStart else {
      stop()
      return false
    }
    CGEvent.tapEnable(tap: tap, enable: true)
    Self.active.withLock { $0 = self }
    return true
  }

  /// 完整回收 tap、source 与专用 runloop,避免会话结束后继续吞键。
  func stop() {
    lifecycleLock.lock()
    let tap = tap
    let source = runLoopSource
    let runLoop = tapRunLoop
    let thread = tapThread
    let stopped = threadStopped
    callbackGeneration &+= 1
    hasStopped = true
    allowsScrolling = false
    draggingControl = false
    verticalGesture = false
    self.tap = nil
    runLoopSource = nil
    tapRunLoop = nil
    tapThread = nil
    threadStopped = nil
    lifecycleLock.unlock()

    Self.active.withLock { if $0 === self { $0 = nil } }
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    if let source {
      CFRunLoopSourceInvalidate(source)
    }
    if let runLoop {
      CFRunLoopStop(runLoop)
    }
    if let thread, let stopped {
      if Thread.current !== thread {
        stopped.wait()
      }
    }
  }

  deinit { stop() }

  private func installTapRunLoop(_ runLoop: CFRunLoop, for thread: Thread) -> Bool {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    guard tap != nil, tapThread === thread else { return false }
    tapRunLoop = runLoop
    return true
  }

  private func clearTapRunLoop(for thread: Thread) {
    lifecycleLock.lock()
    if tapThread === thread { tapRunLoop = nil }
    lifecycleLock.unlock()
  }

  private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let keyTap = Unmanaged<ScrollCaptureKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return keyTap.handle(type: type, event: event)
  }

  func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      lifecycleLock.lock()
      let tap = tap
      lifecycleLock.unlock()
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    guard !hasStopped else { return nil }
    if type == .scrollWheel {
      // The preview owns its own scrolling; it never drives the page or capture activity.
      if controlRects.contains(where: { $0.contains(event.location) }) {
        return Unmanaged.passUnretained(event)
      }
      let allowed = allowsScrolling && !draggingControl && captureRect.contains(event.location)
        && !controlRects.contains(where: { $0.contains(event.location) })
      guard allowed else { return nil }
      // 三套单位必须一起清除,否则触控板精细滚动和惯性仍会横移。
      for field in [CGEventField.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2,
                    .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventDeltaAxis3,
                    .scrollWheelEventPointDeltaAxis3, .scrollWheelEventFixedPtDeltaAxis3] {
        event.setDoubleValueField(field, value: 0)
      }
      // Shift+滚轮在浏览器里会再次映射为横向;其余修饰组合可能触发缩放。
      event.flags.remove(.maskShift)
      guard ModifierFormatter.normalizedRawValue(from: event.flags) == 0 else { return nil }
      let hasVertical = [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1,
                         .scrollWheelEventFixedPtDeltaAxis1].contains {
        event.getDoubleValueField($0) != 0
      }
      let hasPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
        || event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
      guard hasVertical || (verticalGesture && hasPhase) else { return nil }
      verticalGesture = hasVertical
      dispatchToMain(.scroll)
      return Unmanaged.passUnretained(event)
    }
    if type == .rightMouseDown {
      // 右键:退出整个截图会话;吞掉事件,避免目标 App 弹出上下文菜单。
      dispatchToMain(.exit)
      return nil
    }
    if type == .leftMouseDown {
      draggingControl = controlRects.contains { $0.contains(event.location) }
      if draggingControl { return Unmanaged.passUnretained(event) }
      // 目标页面不接受点击/拖拽,防止链接跳转、窗口移动或横向滚动条拖动。
      if event.getIntegerValueField(.mouseEventClickState) >= 2 {
        dispatchToMain(.copy)
        return nil
      }
      return nil
    }
    if type == .leftMouseDragged || type == .leftMouseUp {
      let allowed = draggingControl
      if type == .leftMouseUp { draggingControl = false }
      return allowed ? Unmanaged.passUnretained(event) : nil
    }
    if [.rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged].contains(type) {
      return nil
    }
    guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let modifiers = ModifierFormatter.normalizedRawValue(from: event.flags)
    let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    // 键盘只放行无修饰的上下箭头。左右/Home/End/翻页和编辑键都会改变捕获内容。
    if modifiers == 0, keyCode == 125 || keyCode == 126 {
      let allowed = allowsScrolling && captureRect.contains(event.location)
      guard allowed else { return nil }
      if type == .keyDown { dispatchToMain(.scroll) }
      return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return nil }
    let action: Action
    if keyCode == saveKeyCode, modifiers == saveModifierFlags {
      action = .save
    } else if modifiers == 0, keyCode == copyKeyCode || keyCode == 36 {
      action = .copy
    } else if modifiers == 0, keyCode == cancelKeyCode {
      action = .cancel
    } else {
      return nil
    }
    if !isAutorepeat {
      dispatchToMain(action)
    }
    return nil
  }

  // 调用方持有 lifecycleLock;stop 使已入队的旧会话动作失效。
  private func dispatchToMain(_ action: Action) {
    let generation = callbackGeneration
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.lifecycleLock.lock()
      let running = self.callbackGeneration == generation
      self.lifecycleLock.unlock()
      guard running else { return }
      switch action {
      case .copy: self.onCopy?()
      case .save: self.onSave?()
      case .cancel: self.onCancel?()
      case .exit: self.onExit?()
      case .scroll: self.onScrollActivity?()
      }
    }
  }
}
