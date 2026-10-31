import AppKit
import Observation

/// 擦屏助手:每块屏幕盖一层黑窗,键盘输入全部吞掉,只有解锁快捷键能退出。
///
/// 吞键分三层:
/// - HID 级 event tap 插在最前,吞 keyDown/keyUp/flagsChanged 和媒体键;
/// - 安全输入开着时系统把 keyDown 从所有 tap 里滤掉,解锁靠 `GlobalHotKey` 兜底;
/// - tap 被系统停掉的空当漏出来的键,落到前台的 Velto(开关就在设置窗口里拨),
///   被本地 monitor 吞掉。
@MainActor
@Observable
final class ScreenCleanController {
  static let shared = ScreenCleanController()

  private(set) var isActive = false

  private var windows: [NSWindow] = []
  private var hints: [NSTextField] = []
  private var hintGeneration = 0
  private var tap: EventTapHost?
  private var keyMonitor: Any?
  private var hotKey: GlobalHotKey?
  private var activity: NSObjectProtocol?
  private var unlock = MacAssistantPreferences.defaults.screenCleanUnlockShortcut
  private var unlockModifiers: UInt64 = 0

  private init() {}

  func setActive(_ active: Bool) {
    if active { start() } else { stop() }
  }

  private func start() {
    guard !isActive else { return }
    unlock = GestureStore.shared.preferences.macAssistant.screenCleanUnlockShortcut
    unlockModifiers = ModifierFormatter.normalizedRawValue(from: CGEventFlags(rawValue: unlock.modifierFlags))
    // 建不了 tap 就锁不住键盘,干脆不黑屏。
    guard installTap() else {
      NSSound.beep()
      return
    }
    for screen in NSScreen.screens {
      let hint = NSTextField(labelWithString: "擦屏中 · 按 \(unlock.displayName) 解锁")
      hint.font = .systemFont(ofSize: 15)
      hint.textColor = NSColor(white: 1, alpha: 0.45)
      hint.sizeToFit()
      hint.setFrameOrigin(NSPoint(x: (screen.frame.width - hint.frame.width) / 2, y: 60))
      let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
      window.level = .screenSaver
      window.backgroundColor = .black
      window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
      window.contentView?.addSubview(hint)
      window.orderFrontRegardless()
      windows.append(window)
      hints.append(hint)
    }
    NSCursor.hide()
    // 黑屏期间别让显示器自己睡过去 —— 醒来可能直接掉进锁屏。
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.idleDisplaySleepDisabled, .userInitiated], reason: "擦屏助手"
    )
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handleKeyDown(
        keyCode: event.keyCode, modifiers: ModifierFormatter.normalizedRawValue(from: event.modifierFlags)
      )
      return nil
    }
    registerHotKey()
    isActive = true
    flashHint()
  }

  private func stop() {
    guard isActive else { return }
    isActive = false
    tap?.stop()
    tap = nil
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    hotKey = nil
    windows.forEach { $0.orderOut(nil) }
    windows = []
    hints = []
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    NSCursor.unhide()
  }

  nonisolated static func isUnlock(keyCode: UInt16, modifiers: UInt64, shortcut: Shortcut) -> Bool {
    keyCode == shortcut.keyCode
      && modifiers == ModifierFormatter.normalizedRawValue(from: CGEventFlags(rawValue: shortcut.modifierFlags))
  }

  private func handleKeyDown(keyCode: UInt16, modifiers: UInt64) {
    if Self.isUnlock(keyCode: keyCode, modifiers: modifiers, shortcut: unlock) {
      unlockSoon()
    } else {
      flashHint()
    }
  }

  /// tap / 热键回调里不能拆自己,挪到下一轮主循环再收尾。
  private func unlockSoon() {
    DispatchQueue.main.async { self.stop() }
  }

  /// 按到别的键就把提示亮一下,3 秒后淡出 —— 黑久了容易忘了怎么出来。
  private func flashHint() {
    hintGeneration += 1
    let generation = hintGeneration
    hints.forEach { $0.alphaValue = 1 }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      guard self.hintGeneration == generation else { return }
      self.hints.forEach { $0.animator().alphaValue = 0 }
    }
  }

  private func installTap() -> Bool {
    // 14 = NX_SYSDEFINED:亮度/音量/播放这些媒体键,不吞的话一抹键盘音量就拉满了。
    let mask = [CGEventType.keyDown, .keyUp, .flagsChanged]
      .reduce(CGEventMask(1) << 14) { $0 | (CGEventMask(1) << $1.rawValue) }
    let tap = EventTapHost(
      name: "com.face.velto.screenclean",
      location: .cghidEventTap,
      place: .headInsertEventTap,
      mask: mask
    ) { type, event in
      // 黑屏期间吞掉所有输入,只看 keyDown 里有没有解锁键。
      if type == .keyDown {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = ModifierFormatter.normalizedRawValue(from: event.flags)
        DispatchQueue.main.async {
          ScreenCleanController.shared.handleKeyDown(keyCode: keyCode, modifiers: modifiers)
        }
      }
      return nil
    }
    guard tap.start() else { return false }
    self.tap = tap
    return true
  }

  /// 解锁键注册成热键,只在安全输入把 keyDown 从 tap 里滤掉时才会响。
  /// Carbon 没有 Fn 位,兜底时不认 Fn。
  private func registerHotKey() {
    hotKey = GlobalHotKey(
      keyCode: unlock.keyCode,
      modifierFlags: unlockModifiers & ~CGEventFlags.maskSecondaryFn.rawValue,
      action: { MainActor.assumeIsolated { ScreenCleanController.shared.unlockSoon() } }
    )
  }
}
