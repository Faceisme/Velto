import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// tap 线程匹配截图全局触发键。匹配后切主线程启动会话,返回 true 吞掉事件。
///
/// 安全输入(密码框、终端「安全键盘输入」等)开着时,系统把 keyDown 从所有 event tap 里滤掉,
/// 光靠 tap 按了毫无反应、调试日志也一条不记 —— 触发键另注册成 Carbon 热键兜底。Carbon 热键
/// 在 tap 之后才匹配:平时 tap 已吞掉 keyDown,热键不会响,两条路天然互斥(同 SwitcherKeyTap)。
final class ScreenshotShortcutController: @unchecked Sendable {
  private let lock = NSLock()
  private var triggerShortcut: Shortcut?
  // 热键相关只在主线程读写(偏好同步在 main)。
  private var hotKeyShortcut: Shortcut?
  private var hotKey: EventHotKeyRef?
  private var hotKeyHandler: EventHandlerRef?
  private static let hotKeySignature: OSType = 0x5653_5348  // "VSSH"

  /// 主线程调用。传 nil = 不占触发键(截图关着时别抢别人的组合键)。
  func updateShortcut(_ shortcut: Shortcut?) {
    lock.lock(); triggerShortcut = shortcut; lock.unlock()
    guard shortcut != hotKeyShortcut else { return }
    hotKeyShortcut = shortcut
    registerHotKey(shortcut)
  }

  func handleKeyDown(event: CGEvent, normalizedFlags raw: UInt64) -> Bool {
    lock.lock(); let shortcut = triggerShortcut; lock.unlock()
    guard let shortcut else { return false }
    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    guard keyCode == shortcut.keyCode, raw == shortcut.modifierFlags else { return false }
    DispatchQueue.main.async { ScreenshotController.shared.beginSession() }
    return true
  }

  /// 触发键对应的 Carbon 修饰位。带 Fn 返回 nil:Carbon 没有 Fn 位,注册了会误吃不带 Fn 的组合。
  static func carbonModifiers(_ modifierFlags: UInt64) -> UInt32? {
    let flags = CGEventFlags(rawValue: modifierFlags)
    guard !flags.contains(.maskSecondaryFn) else { return nil }
    var mods = 0
    if flags.contains(.maskCommand) { mods |= cmdKey }
    if flags.contains(.maskShift) { mods |= shiftKey }
    if flags.contains(.maskAlternate) { mods |= optionKey }
    if flags.contains(.maskControl) { mods |= controlKey }
    return UInt32(mods)
  }

  private func registerHotKey(_ shortcut: Shortcut?) {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    hotKey = nil
    guard let shortcut, let modifiers = Self.carbonModifiers(shortcut.modifierFlags) else { return }
    if hotKeyHandler == nil {
      var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(GetEventDispatcherTarget(), Self.hotKeyCallback, 1, &spec, nil, &hotKeyHandler)
    }
    let status = RegisterEventHotKey(
      UInt32(shortcut.keyCode), modifiers, EventHotKeyID(signature: Self.hotKeySignature, id: 0),
      GetEventDispatcherTarget(), 0, &hotKey
    )
    if status != noErr {
      ScreenshotDebugLog.log("安全输入兜底热键注册失败 status=\(status) shortcut=\(shortcut.displayName)")
    }
  }

  /// 只有 tap 没吞到 keyDown(安全输入期间)才会走到这里。在主线程。
  private static let hotKeyCallback: EventHandlerUPP = { _, event, _ in
    var id = EventHotKeyID()
    guard let event,
          GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                            nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
          id.signature == ScreenshotShortcutController.hotKeySignature else { return OSStatus(eventNotHandledErr) }
    DispatchQueue.main.async {
      ScreenshotController.shared.beginSession()
      // 记在 beginSession 之后:日志开关是它按偏好打开的,刚启动时先记会被吞。
      ScreenshotDebugLog.log("↑ 触发键走的 Carbon 兜底(安全输入开着,tap 收不到 keyDown)")
    }
    return noErr
  }
}
