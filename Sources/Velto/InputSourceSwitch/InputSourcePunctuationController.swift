import Carbon
import CoreGraphics
import Foundation

/// 强制英文标点(移植自 Input Source Pro 的 PunctuationService):
/// 启用了该功能的 App 前台时,即便当前是 CJKV 输入法,标点键也直接输出英文字符
/// (, . ; ' [ ] 等),打字选词不受影响。
///
/// 与 ISP 用独立 event tap 不同,这里复用 EventTapManager 常驻 tap 的 keyDown
/// 分支。active 快照由主线程(App 激活 / 偏好变更)经 performOnTapThread 推进来,
/// 热路径全部读 tap 线程独占状态,无锁。
final class InputSourcePunctuationController: @unchecked Sendable {
  /// 当前前台 App 是否启用强制英文标点。tap 线程独占(主线程经 performOnTapThread 写入)。
  private var active = false

  /// CJKV 判定缓存(对齐 ISP:500ms TTL)。快速连打时不必每个键都查一次 TIS。
  private var cachedIsCJKV = false
  private var cacheTime: CFAbsoluteTime = 0
  private static let cacheTimeout: CFAbsoluteTime = 0.5

  /// keycode → (无 Shift, 有 Shift) 的英文字符;nil = 该组合不替换。对齐 ISP 的映射表。
  /// 数字/字母键不在表里 —— 它们参与拼音输入,替换会毁掉打字。
  static let englishMap: [Int64: (normal: String?, shifted: String?)] = [
    Int64(kVK_ANSI_Grave): ("`", "~"),
    Int64(kVK_ANSI_4): (nil, "$"),
    Int64(kVK_ANSI_6): (nil, "^"),
    Int64(kVK_ANSI_Minus): ("-", "_"),
    Int64(kVK_ANSI_Comma): (",", "<"),
    Int64(kVK_ANSI_Period): (".", ">"),
    Int64(kVK_ANSI_Semicolon): (";", ":"),
    Int64(kVK_ANSI_Quote): ("'", "\""),
    Int64(kVK_ANSI_Backslash): ("\\", "|"),
    Int64(kVK_ANSI_LeftBracket): ("[", "{"),
    Int64(kVK_ANSI_RightBracket): ("]", "}"),
  ]

  /// 在 tap 线程调用(主线程经 performOnTapThread 推入)。
  func setActive(_ newValue: Bool) {
    guard active != newValue else { return }
    active = newValue
    // 切换 App 常伴随输入法切换,立刻作废 CJKV 缓存,避免旧值撑满 TTL。
    cacheTime = 0
    InputSourceSwitchDebugLog.log("强制英文标点 active=\(newValue)")
  }

  /// keyDown 热路径。需要替换时返回新事件(调用方 passRetained 返回给系统),
  /// 否则返回 nil 原样透传。
  func replacementEvent(for event: CGEvent) -> CGEvent? {
    guard active else { return nil }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard let replacement = Self.replacementString(keyCode: keyCode, flags: event.flags) else {
      return nil
    }
    // 只在 CJKV 输入法下拦;英文输入法本来就出英文标点。
    guard currentIsCJKV() else { return nil }
    guard let newEvent = Self.makeReplacementEvent(original: event, replacement: replacement) else {
      InputSourceSwitchDebugLog.log("强制英文标点:替换事件创建失败 keyCode=\(keyCode),透传原事件")
      return nil
    }
    InputSourceSwitchDebugLog.log("强制英文标点:keyCode=\(keyCode) → '\(replacement)'")
    return newEvent
  }

  /// 纯决策:该键在该修饰状态下应替换成哪个英文字符;nil = 不动。
  /// 带 ⌘⌃⌥/Fn 的是快捷键必须放行;Shift 参与选字符(如 Shift+, → <),允许。
  static func replacementString(keyCode: Int64, flags: CGEventFlags) -> String? {
    guard let mapping = englishMap[keyCode] else { return nil }
    let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
    guard flags.intersection(shortcutModifiers).isEmpty else { return nil }
    return flags.contains(.maskShift) ? mapping.shifted : mapping.normal
  }

  /// 对齐 ISP:保留原 keyCode 新建事件,塞入英文字符的 unicode string,并清空
  /// flags(privateState source 避免修饰键状态污染)。IME 收到带显式 unicode
  /// 字符串的事件会原样出字,不再走中文标点转换。
  private static func makeReplacementEvent(original: CGEvent, replacement: String) -> CGEvent? {
    let keyCode = CGKeyCode(original.getIntegerValueField(.keyboardEventKeycode))
    guard let source = CGEventSource(stateID: .privateState),
          let newEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    else { return nil }
    let utf16 = Array(replacement.utf16)
    newEvent.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    newEvent.timestamp = original.timestamp
    newEvent.flags = []
    return newEvent
  }

  private func currentIsCJKV() -> Bool {
    let now = CFAbsoluteTimeGetCurrent()
    if now - cacheTime < Self.cacheTimeout {
      return cachedIsCJKV
    }
    cachedIsCJKV = InputSourceCatalog.current()?.isCJKV ?? false
    cacheTime = now
    return cachedIsCJKV
  }
}
