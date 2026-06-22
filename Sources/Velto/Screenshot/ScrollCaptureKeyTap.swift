import Cocoa
@preconcurrency import CoreFoundation

/// 滚动截图期间全局接管完成快捷键,目标 App 保持前台时仍可结束会话。
final class ScrollCaptureKeyTap: @unchecked Sendable {
  private enum Action: Sendable { case copy, save, cancel }

  var onCopy: (() -> Void)?
  var onSave: (() -> Void)?
  var onCancel: (() -> Void)?

  private let copyKeyCode: UInt16
  private let cancelKeyCode: UInt16
  private let saveKeyCode: UInt16
  private let saveModifierFlags: UInt64

  private let lifecycleLock = NSLock()
  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var tapRunLoop: CFRunLoop?
  /// 运行中的 Thread 由系统保活;这里弱持有以避免 thread 闭包与 self 构成引用环。
  private weak var tapThread: Thread?
  private var threadStopped: DispatchSemaphore?

  init(preferences: ScreenshotPreferences) {
    copyKeyCode = preferences.copyKeyCode
    cancelKeyCode = preferences.cancelKeyCode
    saveKeyCode = preferences.saveShortcut.keyCode
    saveModifierFlags = ModifierFormatter.normalizedRawValue(
      from: CGEventFlags(rawValue: preferences.saveShortcut.modifierFlags)
    )
  }

  /// 创建会话级 event tap。失败通常表示辅助功能权限或系统资源不可用。
  func start() -> Bool {
    lifecycleLock.lock()
    let alreadyStarted = tap != nil
    lifecycleLock.unlock()
    guard !alreadyStarted else { return true }

    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
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
    self.tap = nil
    runLoopSource = nil
    tapRunLoop = nil
    tapThread = nil
    threadStopped = nil
    lifecycleLock.unlock()

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

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      lifecycleLock.lock()
      let tap = tap
      lifecycleLock.unlock()
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
      return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let modifiers = ModifierFormatter.normalizedRawValue(from: event.flags)
    if keyCode == saveKeyCode, modifiers == saveModifierFlags {
      dispatchToMain(.save)
      return nil
    }
    if modifiers == 0, keyCode == copyKeyCode || keyCode == 36 {
      dispatchToMain(.copy)
      return nil
    }
    if modifiers == 0, keyCode == cancelKeyCode {
      dispatchToMain(.cancel)
      return nil
    }
    return Unmanaged.passUnretained(event)
  }

  private func dispatchToMain(_ action: Action) {
    DispatchQueue.main.async { [weak self] in
      switch action {
      case .copy: self?.onCopy?()
      case .save: self?.onSave?()
      case .cancel: self?.onCancel?()
      }
    }
  }
}
