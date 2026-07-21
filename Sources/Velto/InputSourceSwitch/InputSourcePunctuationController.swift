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

  /// IME 组字状态推演(候选窗是否可见的近似)。tap 线程拿不到输入法真实组字
  /// 状态,只能按键流估计缓冲长度:字母 +1、退格 -1、提交/取消键归零。
  /// 宁可误判"在组字"(标点透传一次,最多出一个中文标点)也不能误判"没组字"
  /// (吞掉 [ ] - 会让候选窗翻不了页)。
  struct CompositionTracker {
    private(set) var bufferedKeyCount = 0
    var isComposing: Bool { bufferedKeyCount > 0 }

    /// 组字缓冲上限估计。IME 缓冲不会无限长,封顶防状态漂移后卡死在"组字中"。
    private static let maxBufferedKeys = 64

    private static let letterKeyCodes: Set<Int64> = Set(
      [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
        kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
        kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
        kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
      ].map(Int64.init))

    /// 这些键要么提交要么取消组字:空格/回车选字、Esc 撤销、Tab 补全、数字选候选。
    private static let commitKeyCodes: Set<Int64> = Set(
      [
        kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape, kVK_Tab,
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0,
      ].map(Int64.init))

    mutating func noteKeyDown(keyCode: Int64, flags: CGEventFlags) {
      // ⌘⌃ 快捷键基本都会提交/取消组字(⌘A、⌘Tab 切 App 等),保守归零。
      guard flags.intersection([.maskCommand, .maskControl]).isEmpty else {
        bufferedKeyCount = 0
        return
      }
      if Self.letterKeyCodes.contains(keyCode) {
        // ⌥/Fn+字母出的是特殊符号,不进拼音缓冲。
        guard flags.intersection([.maskAlternate, .maskSecondaryFn]).isEmpty else { return }
        bufferedKeyCount = min(bufferedKeyCount + 1, Self.maxBufferedKeys)
      } else if keyCode == Int64(kVK_Delete) || keyCode == Int64(kVK_ForwardDelete) {
        bufferedKeyCount = max(0, bufferedKeyCount - 1)
      } else if Self.commitKeyCodes.contains(keyCode) {
        bufferedKeyCount = 0
      }
      // 其余键(方向键/PgUp/PgDn/=/F 区)组字中都在导航候选,状态不变。
    }

    mutating func reset() { bufferedKeyCount = 0 }
  }

  /// 组字期间的候选导航键:Apple 拼音/双拼里 [ ] 翻页、- 翻页(= 不在替换表,天然放行)。
  /// 这些键组字中必须透传原事件 —— 换成 keyCode 0 的合成事件后输入法认不出翻页键,
  /// 候选窗会彻底翻不了页(2026-07 实测双拼 [ ] 翻页失灵的根因)。
  static let candidateNavigationKeyCodes: Set<Int64> = Set(
    [kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Minus].map(Int64.init))

  /// 功能全局开关快照。tap 线程独占(主线程经 performOnTapThread 写入)。
  private var active = false
  /// 当前输入法是否 CJKV 的快照。tap 线程独占,主线程监听系统输入法变更通知后推入。
  private var inputSourceIsCJKV = false
  /// 当前输入法宿主进程 PID(nil=键盘布局或解析失败)。tap 线程独占,主线程推入。
  private var imeProcessID: pid_t?
  /// 组字状态推演。仅在 imeProcessID 解析不到时兜底用。tap 线程独占。
  private var compositionTracker = CompositionTracker()
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
    compositionTracker.reset()
    InputSourceSwitchDebugLog.log("强制英文标点 active=\(newValue)")
  }

  /// 在 tap 线程调用(主线程经 performOnTapThread 推入)。
  func setCurrentInputSourceIsCJKV(_ newValue: Bool) {
    guard inputSourceIsCJKV != newValue else { return }
    inputSourceIsCJKV = newValue
    compositionTracker.reset()
    InputSourceSwitchDebugLog.log("强制英文标点 currentIsCJKV=\(newValue)")
  }

  /// 在 tap 线程调用(主线程解析后经 performOnTapThread 推入)。
  func setCurrentInputSourceProcessID(_ pid: pid_t?) {
    guard imeProcessID != pid else { return }
    imeProcessID = pid
    InputSourceSwitchDebugLog.log("强制英文标点 imePID=\(pid.map(String.init) ?? "nil")")
  }

  /// 在 tap 线程调用:鼠标按下会提交/取消 IME 组字,推演状态跟着归零。
  func noteMouseDown() {
    compositionTracker.reset()
  }

  /// 组字判定。两路信号取「或」,缺一不可:
  /// 1. 首选真值 —— IME 宿主进程有在屏候选窗 = 正在组字。豆包等**进程外**输入法候选窗
  ///    归自己 PID,这一路能覆盖「数字/空格选字后候选窗还开着」(选字后翻页失灵的根因)。
  /// 2. 兜底 —— 按键流推演缓冲。Apple **自带**输入法(SCIM 拼音/双拼)候选窗**不进**
  ///    CGWindowList、也不归属 SCIM_Extension 进程(2026-07-21 实测:组字时 sawSCIMWindow=false),
  ///    真值那一路对它恒为 false;只能靠推演:敲了字母(缓冲>0)即判为组字中,让 [ ] - 翻页键透传。
  /// 只留真值 → 自带输入法翻页全废(本次修复的 Bug);只留推演 → 进程外输入法选字后翻页失灵。
  /// ponytail: 自带输入法「选字后候选窗仍开、缓冲已归零」这一 case 推演漏判,仍会吞一次翻页 ——
  ///           拿不到自带输入法候选窗真值,无解,待 Apple 暴露可查组字状态再补;当前已优于「全废」。
  private func isComposingNow() -> (composing: Bool, via: String) {
    if let pid = imeProcessID, Self.processOwnsOnScreenWindow(pid: pid) {
      return (true, "候选窗在屏 imePID=\(pid)")
    }
    if compositionTracker.isComposing {
      return (true, "按键流推演(缓冲=\(compositionTracker.bufferedKeyCount))")
    }
    return (false, imeProcessID.map { "候选窗不在屏 imePID=\($0) 且推演缓冲=0" } ?? "按键流推演(缓冲=0)")
  }

  /// WindowServer 一次 IPC(实测远低于 1ms),只发生在标点导航键按下时,热路径无感。
  private static func processOwnsOnScreenWindow(pid: pid_t) -> Bool {
    guard let list = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return false }
    return list.contains { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
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
    guard Self.englishMap[keyCode] != nil else {
      // 非标点键只喂组字推演(字母/退格/提交键),零日志零额外开销。
      if active, inputSourceIsCJKV {
        compositionTracker.noteKeyDown(keyCode: keyCode, flags: event.flags)
      }
      return false
    }
    guard active else {
      InputSourceSwitchDebugLog.log("强制英文标点:keyCode=\(keyCode) 放行 —— 功能未启用(active=false)")
      return false
    }
    guard let replacement = Self.replacementString(keyCode: keyCode, flags: event.flags) else {
      // ⌘[ 这类快捷键多半会打断组字,同样喂给推演(内部只对 ⌘⌃ 归零)。
      if inputSourceIsCJKV {
        compositionTracker.noteKeyDown(keyCode: keyCode, flags: event.flags)
      }
      InputSourceSwitchDebugLog.log(
        "强制英文标点:keyCode=\(keyCode) 放行 —— 带快捷键修饰或该组合无映射 flags=\(event.flags.rawValue)")
      return false
    }
    // 只在 CJKV 输入法下拦;英文输入法本来就出英文标点。
    guard inputSourceIsCJKV else {
      InputSourceSwitchDebugLog.log("强制英文标点:keyCode=\(keyCode) 放行 —— 当前非 CJKV 输入法")
      return false
    }
    // 组字中(候选窗可见)的 [ ] - 是翻页键,必须把原事件透传给输入法。
    if Self.candidateNavigationKeyCodes.contains(keyCode) {
      let verdict = isComposingNow()
      if verdict.composing {
        InputSourceSwitchDebugLog.log(
          "强制英文标点:keyCode=\(keyCode) 放行 —— 组字中候选导航键(\(verdict.via))")
        return false
      }
    }
    guard postReplacementTap(replacement: replacement, originalTimestamp: event.timestamp) else {
      InputSourceSwitchDebugLog.log("强制英文标点:合成事件创建失败 keyCode=\(keyCode),透传原事件")
      return false
    }
    // 合成标点会让 IME 提交当前组字,推演状态跟着归零。
    compositionTracker.reset()
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
