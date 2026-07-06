import Carbon
import CoreGraphics
import Foundation

/// 强制英文标点(源自 Input Source Pro 的 PunctuationService,简化为全局开关):
/// 开启后,任何 App 里即便当前是 CJKV 输入法,标点键也直接输出英文字符
/// (, . ; ' [ ] 等),打字选词不受影响。
///
/// 与 ISP 用独立 event tap 不同,这里复用 EventTapManager 常驻 tap 的 keyDown
/// 分支。active / CJKV 两个快照都由主线程经 performOnTapThread 推进来,
/// 热路径全部读 tap 线程独占状态,无锁、零 TIS 调用。
///
/// 两条用血换来的实现约束(2026-07 实测,别回退):
/// 1. **绝不能在 tap 线程查 TIS**:macOS 26 起 TISGetInputSourceProperty 内部
///    dispatch_assert_queue 断言主队列,tap 线程调用直接 SIGTRAP 崩进程。
///    CJKV 状态只能主线程监听 kTISNotifySelectedKeyboardInputSourceChanged 推快照。
/// 2. **ISP 的「改事件 unicode 载荷」手法对微信输入法无效**:WeType 按键码查自家
///    标点表重转中文(实测句号载荷 '.' 仍出「。」)。正解是吞掉原事件,另发
///    「键码 0(字母 a 位)+ unicode 载荷」的合成对 —— 字母键码不在 IME 标点表里,
///    IME 按字符处理原样放行(实测微信输入法下出英文)。0xFFFF / F13 会被系统丢弃。
final class InputSourcePunctuationController: @unchecked Sendable {
  /// 合成事件标记(eventSourceUserData):防止发出的键码 0 事件被本 tap 的
  /// 按键映射等分支再加工。
  static let syntheticEventMarker: Int64 = 0x56_45_4C_50 // "VELP"

  /// 功能全局开关快照。tap 线程独占(主线程经 performOnTapThread 写入)。
  private var active = false
  /// 当前输入法是否 CJKV 的快照。tap 线程独占,主线程监听系统输入法变更通知后推入。
  private var inputSourceIsCJKV = false
  /// 原标点 keyDown 被吞掉后,对应的物理 keyUp 也必须吞掉,避免目标 App 看到不成对按键。
  private var suppressedKeyUpCounts: [Int64: Int] = [:]

  /// 合成事件源建一次复用(每次重建要走 IOKit,是热路径里最重的一步)。tap 线程独占。
  private let eventSource = CGEventSource(stateID: .privateState)

  /// keycode → (无 Shift, 有 Shift) 的英文字符;nil = 该组合不替换。
  /// 底表对齐 ISP 的映射表,另补上 ISP 原表漏掉、但中文输入法确实会转全角的四个:
  /// ?(Shift+/ → ？)、!(Shift+1 → ！)、((Shift+9 → （)、)(Shift+0 → ））。
  /// 数字/字母键的无 Shift 位必须是 nil —— 它们参与拼音输入/候选选词,替换会毁掉打字;
  /// @#%&*=+ 中文输入法本就出半角,无需入表。
  static let englishMap: [Int64: (normal: String?, shifted: String?)] = [
    Int64(kVK_ANSI_Grave): ("`", "~"),
    Int64(kVK_ANSI_1): (nil, "!"),
    Int64(kVK_ANSI_4): (nil, "$"),
    Int64(kVK_ANSI_6): (nil, "^"),
    Int64(kVK_ANSI_9): (nil, "("),
    Int64(kVK_ANSI_0): (nil, ")"),
    Int64(kVK_ANSI_Minus): ("-", "_"),
    Int64(kVK_ANSI_Comma): (",", "<"),
    Int64(kVK_ANSI_Period): (".", ">"),
    Int64(kVK_ANSI_Semicolon): (";", ":"),
    Int64(kVK_ANSI_Quote): ("'", "\""),
    Int64(kVK_ANSI_Slash): ("/", "?"),
    Int64(kVK_ANSI_Backslash): ("\\", "|"),
    Int64(kVK_ANSI_LeftBracket): ("[", "{"),
    Int64(kVK_ANSI_RightBracket): ("]", "}"),
  ]

  /// 在 tap 线程调用(主线程经 performOnTapThread 推入)。
  func setActive(_ newValue: Bool) {
    guard active != newValue else { return }
    active = newValue
    InputSourceSwitchDebugLog.log("强制英文标点 active=\(newValue)")
  }

  /// 在 tap 线程调用(主线程经 performOnTapThread 推入)。
  func setCurrentInputSourceIsCJKV(_ newValue: Bool) {
    guard inputSourceIsCJKV != newValue else { return }
    inputSourceIsCJKV = newValue
    InputSourceSwitchDebugLog.log("强制英文标点 currentIsCJKV=\(newValue)")
  }

  /// 合成事件标记判断。EventTapManager 先放行这些事件,避免被按键映射或本控制器二次处理。
  static func isSyntheticEvent(_ event: CGEvent) -> Bool {
    event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
  }

  /// keyDown 热路径。命中时吞掉原事件并自行 post 一组 keyCode=0 + unicode 的合成按键。
  ///
  /// 先查映射表再看 active:非标点键零日志零额外开销;标点键则把每个放行原因
  /// 落调试日志 —— "开了却没效果"全靠这几行定位。
  func handleKeyDown(event: CGEvent) -> Bool {
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard Self.englishMap[keyCode] != nil else { return false }
    guard active else {
      InputSourceSwitchDebugLog.log("强制英文标点:keyCode=\(keyCode) 放行 —— 功能未启用(active=false)")
      return false
    }
    guard let replacement = Self.replacementString(keyCode: keyCode, flags: event.flags) else {
      InputSourceSwitchDebugLog.log(
        "强制英文标点:keyCode=\(keyCode) 放行 —— 带快捷键修饰或该组合无映射 flags=\(event.flags.rawValue)")
      return false
    }
    // 只在 CJKV 输入法下拦;英文输入法本来就出英文标点。
    guard inputSourceIsCJKV else {
      InputSourceSwitchDebugLog.log("强制英文标点:keyCode=\(keyCode) 放行 —— 当前非 CJKV 输入法")
      return false
    }
    guard postReplacementTap(replacement: replacement, originalTimestamp: event.timestamp) else {
      InputSourceSwitchDebugLog.log("强制英文标点:合成事件创建失败 keyCode=\(keyCode),透传原事件")
      return false
    }
    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
      suppressedKeyUpCounts[keyCode, default: 0] += 1
    }
    InputSourceSwitchDebugLog.log("强制英文标点:keyCode=\(keyCode) → '\(replacement)' syntheticKeyCode=0")
    return true
  }

  /// keyUp 热路径。若对应 keyDown 已被替换,吞掉原始 keyUp。
  func shouldConsumeKeyUp(event: CGEvent) -> Bool {
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard let count = suppressedKeyUpCounts[keyCode], count > 0 else { return false }
    if count == 1 {
      suppressedKeyUpCounts.removeValue(forKey: keyCode)
    } else {
      suppressedKeyUpCounts[keyCode] = count - 1
    }
    return true
  }

  /// 纯决策:该键在该修饰状态下应替换成哪个英文字符;nil = 不动。
  /// 带 ⌘⌃⌥/Fn 的是快捷键必须放行;Shift 参与选字符(如 Shift+, → <),允许。
  static func replacementString(keyCode: Int64, flags: CGEventFlags) -> String? {
    guard let mapping = englishMap[keyCode] else { return nil }
    let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
    guard flags.intersection(shortcutModifiers).isEmpty else { return nil }
    return flags.contains(.maskShift) ? mapping.shifted : mapping.normal
  }

  /// 对齐 ISP 的可用路径:吞掉原标点事件,改发 keyCode 0(字母 a 位)承载 unicode。
  /// 继续用原标点 keyCode 时,WeType 会按自己的标点表把 unicode 再转回中文。
  private func postReplacementTap(replacement: String, originalTimestamp: CGEventTimestamp) -> Bool {
    guard let source = eventSource,
          let down = makeSyntheticEvent(source: source, replacement: replacement, keyDown: true, timestamp: originalTimestamp),
          let up = makeSyntheticEvent(source: source, replacement: replacement, keyDown: false, timestamp: originalTimestamp)
    else { return false }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }

  private func makeSyntheticEvent(
    source: CGEventSource,
    replacement: String,
    keyDown: Bool,
    timestamp: CGEventTimestamp
  ) -> CGEvent? {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: keyDown) else {
      return nil
    }
    if keyDown {
      let utf16 = Array(replacement.utf16)
      event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    }
    event.timestamp = timestamp
    event.flags = []
    event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
    return event
  }
}
