import AppKit
import CoreGraphics
import Foundation

// 预编译后的 manipulator，热路径零额外枚举转换。
private struct CompiledManipulator {
  let fromKeyCode: UInt16
  let fromIsModifier: Bool
  let mandatoryCodes: Set<UInt16>     // Mode B 必须同时压下的修饰键 keyCode
  let toActions: [CompiledToAction]
}

private enum CompiledToAction {
  case key(keyCode: UInt16, flags: CGEventFlags)       // 合成 keyDown/keyUp
  case modifierFlags(keyCode: UInt16, onFlags: CGEventFlags)  // 合成 flagsChanged（hyper）
  case disable                                          // vk_none
}

private let kCapsLockKeyCode: UInt16 = 57

final class KeyRemapController: @unchecked Sendable {
  // tap 线程独占，无需 lock
  private var normalKeyTable: [UInt16: [CompiledManipulator]] = [:]    // from 普通键
  private var modifierKeyTable: [UInt16: [CompiledManipulator]] = [:]  // from 修饰键
  private var modeB_mandatoryCodes: Set<UInt16> = []                   // 所有 Mode B mandatory

  private var suppressedModifiers: Set<UInt16> = []   // 已吞掉的修饰键 keyCode（Mode B）
  private var activeRemaps: [UInt16: CompiledManipulator] = [:]        // 已按下待 keyUp
  private var previousFlags: CGEventFlags = []
  private var hyperActive: Bool = false               // hyper key 是否激活中

  // 合成事件用的 event source 建一次复用。每次按键重建要走 IOKit + 查 HID 状态，
  // 是热路径里最重的一步；这里只在 tap 线程访问，无需加锁。
  private let eventSource = CGEventSource(stateID: .hidSystemState)

  // MARK: - 更新查找表（在 tap 线程调用）

  func update(rules: [KeyRemapRule]) {
    var normal: [UInt16: [CompiledManipulator]] = [:]
    var modifier: [UInt16: [CompiledManipulator]] = [:]
    var modeCodes: Set<UInt16> = []

    let logging = KeyRemapDebugLog.isEnabled
    let enabledRules = rules.filter { $0.enabled }
    let disabledCount = rules.count - enabledRules.count
    let totalManipulators = enabledRules.reduce(0) { $0 + $1.manipulators.count }
    if logging {
      KeyRemapDebugLog.log("update(rules:) 进入 — 收到 \(rules.count) 条规则" +
        "(启用 \(enabledRules.count) / 禁用 \(disabledCount)),共 \(totalManipulators) 条 manipulator")
      if rules.isEmpty {
        KeyRemapDebugLog.log("  ⚠️ 规则列表为空 —— 若是手动关闭了总开关属正常;否则规则没传进来,所有按键将原样透传")
      }
    }

    for rule in rules where rule.enabled {
      for m in rule.manipulators {
        let compiled = compile(m)
        if m.from.isModifier {
          modifier[m.from.keyCode, default: []].append(compiled)
        } else {
          normal[m.from.keyCode, default: []].append(compiled)
          modeCodes.formUnion(compiled.mandatoryCodes)
        }
        if logging {
          KeyRemapDebugLog.log("  编译 [\(rule.title)] " +
            "from=\(Self.describeFrom(m.from)) (\(m.from.isModifier ? "修饰键→modifierTable" : "普通键→normalTable")) " +
            "to=\(Self.describeActions(compiled.toActions))")
        }
      }
    }

    normalKeyTable = normal
    modifierKeyTable = modifier
    modeB_mandatoryCodes = modeCodes

    // 规则更新时清空运行状态，避免悬挂
    suppressedModifiers = []
    activeRemaps = [:]
    hyperActive = false
    previousFlags = []

    if logging {
      let normalKeys = normal.keys.sorted().map { Self.label($0) }.joined(separator: ", ")
      let modKeys = modifier.keys.sorted().map { Self.label($0) }.joined(separator: ", ")
      let modeBKeys = modeCodes.sorted().map { Self.label($0) }.joined(separator: ", ")
      KeyRemapDebugLog.log("查找表已构建 — normalKeyTable: [\(normalKeys.isEmpty ? "空" : normalKeys)] " +
        "| modifierKeyTable: [\(modKeys.isEmpty ? "空" : modKeys)] " +
        "| Mode B mandatory: [\(modeBKeys.isEmpty ? "无" : modeBKeys)]")
    }
  }

  // MARK: - Event handlers（返回 true = 事件已消费，EventTapManager 应 return nil）

  func handleFlagsChanged(event: CGEvent) -> Bool {
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let currentFlags = event.flags
    let logging = KeyRemapDebugLog.isEnabled

    if logging {
      KeyRemapDebugLog.log("flagsChanged keyCode=\(Self.label(keyCode)) " +
        "flags=\(Self.describeFlags(currentFlags)) prevFlags=\(Self.describeFlags(previousFlags)) " +
        "suppressed=[\(Self.describeCodes(suppressedModifiers))]")
    }

    defer { previousFlags = currentFlags }

    // Mode B：修饰键进入 suppress 逻辑
    if modeB_mandatoryCodes.contains(keyCode) {
      let wasHeld = suppressedModifiers.contains(keyCode)
      let isNowPressed = isModifierPressed(keyCode: keyCode, current: currentFlags,
                                           previous: previousFlags)
      if isNowPressed && !wasHeld {
        suppressedModifiers.insert(keyCode)
        if logging { KeyRemapDebugLog.log("  Mode B: \(Self.label(keyCode)) 压下 → 加入 suppressed,吞掉本次 press") }
        return true   // 吞掉 press
      } else if !isNowPressed && wasHeld {
        suppressedModifiers.remove(keyCode)
        if logging { KeyRemapDebugLog.log("  Mode B: \(Self.label(keyCode)) 松开 → 移出 suppressed,吞掉本次 release") }
        return true   // 吞掉 release
      } else if logging {
        KeyRemapDebugLog.log("  Mode B: \(Self.label(keyCode)) 状态未变(pressed=\(isNowPressed), wasHeld=\(wasHeld)),继续走 Mode A")
      }
    }

    // Mode A：修饰键本身作为 from
    guard let candidates = modifierKeyTable[keyCode], !candidates.isEmpty else {
      if logging { KeyRemapDebugLog.log("  Mode A: modifierKeyTable 无 \(Self.label(keyCode)) 的映射 → 透传(return false)") }
      return false
    }
    let manipulator = candidates[0]   // 同一 from 键取第一条规则（同 Karabiner）

    // Caps Lock(57) 是 toggle 键:物理上只在亮灯/灭灯瞬间各发一个 flagsChanged,
    // 没有干净的按下/抬起,tap 也消费不了它的物理 toggle。这里把它当「单击源」:
    //   - 亮灯瞬间(maskAlphaShift 出现)= 一次完整敲击 → 用 IOKit 把 caps 按回灭灯
    //     (不再当 caps 用),并把目标合成成一次完整的「按下 + 抬起」。
    //   - 灭灯方向(含我们强制灭灯回灌的那个事件)直接吞掉,不二次触发。
    // 因为每次都把 caps 按回关,所以之后的每次物理敲击都表现为「亮灯瞬间」,
    // 稳定地一击对一击。注意:toggle 键拿不到「按住」,故不支持长按当 hyper。
    if keyCode == kCapsLockKeyCode {
      let turningOn = currentFlags.contains(.maskAlphaShift)
      if turningOn {
        let off = KeyRemapCapsLock.forceOff()
        if logging {
          KeyRemapDebugLog.log("  Caps Lock 源:亮灯瞬间 → 强制灭灯\(off ? "成功" : "失败") + 合成 \(manipulator.toActions.count) 个动作(完整一击)")
        }
        for action in manipulator.toActions { synthesizeTap(action: action) }
      } else if logging {
        KeyRemapDebugLog.log("  Caps Lock 源:灭灯方向,吞掉不二次触发")
      }
      return true
    }

    let pressed = isModifierPressed(keyCode: keyCode, current: currentFlags, previous: previousFlags)
    if logging {
      KeyRemapDebugLog.log("  Mode A 命中: \(Self.label(keyCode)) pressed=\(pressed) → 合成 \(manipulator.toActions.count) 个动作")
    }
    for action in manipulator.toActions {
      synthesize(action: action, press: pressed)
    }
    return true
  }

  func handleKeyDown(event: CGEvent) -> Bool {
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let logging = KeyRemapDebugLog.isEnabled

    guard let candidates = normalKeyTable[keyCode] else {
      if logging { KeyRemapDebugLog.log("keyDown keyCode=\(Self.label(keyCode)) → normalKeyTable 无映射,透传") }
      return false
    }

    if logging {
      KeyRemapDebugLog.log("keyDown keyCode=\(Self.label(keyCode)) → 命中 \(candidates.count) 条候选,当前 suppressed=[\(Self.describeCodes(suppressedModifiers))]")
    }

    // 找第一条 mandatory ⊆ suppressedModifiers 的规则
    guard let m = candidates.first(where: { $0.mandatoryCodes.isSubset(of: suppressedModifiers) }) else {
      if logging {
        let need = candidates.map { "[\(Self.describeCodes($0.mandatoryCodes))]" }.joined(separator: " 或 ")
        KeyRemapDebugLog.log("  ✗ 无候选的 mandatory ⊆ suppressed —— 候选要求 \(need),实际 suppressed=[\(Self.describeCodes(suppressedModifiers))] → 透传")
      }
      return false
    }
    activeRemaps[keyCode] = m
    if logging {
      KeyRemapDebugLog.log("  ✓ 命中规则 mandatory=[\(Self.describeCodes(m.mandatoryCodes))] → 合成 \(m.toActions.count) 个动作(press)")
    }
    for action in m.toActions { synthesize(action: action, press: true) }
    return true
  }

  func handleKeyUp(event: CGEvent) -> Bool {
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let logging = KeyRemapDebugLog.isEnabled
    guard let m = activeRemaps.removeValue(forKey: keyCode) else {
      if logging { KeyRemapDebugLog.log("keyUp keyCode=\(Self.label(keyCode)) → 无对应 activeRemap,透传") }
      return false
    }
    if logging {
      KeyRemapDebugLog.log("keyUp keyCode=\(Self.label(keyCode)) → 命中 activeRemap,合成 \(m.toActions.count) 个动作(release)")
    }
    for action in m.toActions { synthesize(action: action, press: false) }
    return true
  }

  // MARK: - 私有：编译

  private func compile(_ m: KeyRemapManipulator) -> CompiledManipulator {
    let actions: [CompiledToAction] = m.to.map { to in
      if to.keyCode == 0xFFFF { return .disable }
      if to.isModifier {
        // hyper key 场景：合成 flagsChanged
        var onFlags = modifierFlags(for: to.keyCode)
        for code in to.additionalModifierCodes {
          onFlags.formUnion(modifierFlags(for: code))
        }
        return .modifierFlags(keyCode: to.keyCode, onFlags: onFlags)
      } else {
        // 普通键：合成 keyDown/keyUp，携带 additionalModifiers 的 flags
        var flags: CGEventFlags = []
        for code in to.additionalModifierCodes {
          flags.formUnion(modifierFlags(for: code))
        }
        return .key(keyCode: to.keyCode, flags: flags)
      }
    }
    return CompiledManipulator(
      fromKeyCode: m.from.keyCode,
      fromIsModifier: m.from.isModifier,
      mandatoryCodes: Set(m.from.mandatory),
      toActions: actions
    )
  }

  // MARK: - 私有：合成事件

  /// 合成一次完整敲击(按下紧跟抬起)。用于 toggle 源(Caps Lock):物理上拿不到
  /// 按住语义,只能把每次触发翻译成目标键的一次完整单击。
  private func synthesizeTap(action: CompiledToAction) {
    synthesize(action: action, press: true)
    synthesize(action: action, press: false)
  }

  private func synthesize(action: CompiledToAction, press: Bool) {
    let marker = ShortcutSynthesizer.syntheticEventMarker
    let logging = KeyRemapDebugLog.isEnabled
    guard let src = eventSource else {
      if logging { KeyRemapDebugLog.log("    ⚠️ synthesize 失败:eventSource 为 nil(IOKit/HID 初始化失败),无法合成任何事件") }
      return
    }

    switch action {
    case .disable:
      if logging { KeyRemapDebugLog.log("    动作=disable(vk_none),不发任何事件") }
      break   // 什么都不发

    case .key(let keyCode, let flags):
      guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: press) else {
        if logging { KeyRemapDebugLog.log("    ⚠️ synthesize 失败:CGEvent(key \(Self.label(keyCode))) 创建返回 nil") }
        return
      }
      e.flags = flags
      e.setIntegerValueField(.eventSourceUserData, value: marker)
      e.post(tap: .cghidEventTap)
      if logging {
        KeyRemapDebugLog.log("    ✓ 已合成 key \(Self.label(keyCode)) \(press ? "Down" : "Up") flags=\(Self.describeFlags(flags)) → post(.cghidEventTap)")
      }

    case .modifierFlags(let keyCode, let onFlags):
      // 按下时发 onFlags，松开时清零
      let newFlags: CGEventFlags = press ? onFlags : []
      guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: press) else {
        if logging { KeyRemapDebugLog.log("    ⚠️ synthesize 失败:CGEvent(flagsChanged \(Self.label(keyCode))) 创建返回 nil") }
        return
      }
      e.type = .flagsChanged
      e.flags = newFlags
      e.setIntegerValueField(.eventSourceUserData, value: marker)
      e.post(tap: .cghidEventTap)
      if logging {
        KeyRemapDebugLog.log("    ✓ 已合成 flagsChanged \(Self.label(keyCode)) \(press ? "on" : "off") flags=\(Self.describeFlags(newFlags)) → post(.cghidEventTap)")
      }
    }
  }

  // MARK: - 私有：辅助

  // 根据 modifier keyCode 返回对应的 CGEventFlags bit
  private func modifierFlags(for keyCode: UInt16) -> CGEventFlags {
    switch keyCode {
    case 56, 60: return .maskShift        // left/right shift
    case 59, 62: return .maskControl      // left/right control
    case 58, 61: return .maskAlternate    // left/right option
    case 55, 54: return .maskCommand      // left/right command
    case 63:     return .maskSecondaryFn  // fn
    case 57:     return .maskAlphaShift   // caps_lock
    default:     return []
    }
  }

  // 判断该修饰键在 current flags 里是否"按下"（相对于 previous）
  private func isModifierPressed(keyCode: UInt16, current: CGEventFlags, previous: CGEventFlags) -> Bool {
    let bit = modifierFlags(for: keyCode)
    if keyCode == 57 {
      // caps_lock：toggle 语义，当前 bit 存在即为 on（pressed）
      return current.contains(.maskAlphaShift)
    }
    // 其他修饰键：bit 从无到有 = pressed
    return current.contains(bit) && !previous.contains(bit)
  }

  // MARK: - 私有：调试格式化

  /// keyCode → "Caps Lock(57)" 形式;查不到名字就只给编号。
  private static func label(_ keyCode: UInt16) -> String {
    if keyCode == 0xFFFF { return "vk_none(禁用)" }
    if let name = KeyCodeMap.byKeyCode[keyCode]?.displayLabel {
      return "\(name)(\(keyCode))"
    }
    return "#\(keyCode)"
  }

  private static func describeCodes(_ codes: Set<UInt16>) -> String {
    codes.sorted().map { label($0) }.joined(separator: ", ")
  }

  private static func describeFrom(_ from: KeyRemapFrom) -> String {
    let base = label(from.keyCode)
    guard !from.mandatory.isEmpty else { return base }
    let mods = from.mandatory.map { label($0) }.joined(separator: "+")
    return "\(mods)+\(base)"
  }

  private static func describeActions(_ actions: [CompiledToAction]) -> String {
    guard !actions.isEmpty else { return "(空)" }
    return actions.map { action in
      switch action {
      case .disable: return "disable"
      case .key(let kc, let flags):
        let f = describeFlags(flags)
        return f == "∅" ? "key \(label(kc))" : "key \(label(kc))+\(f)"
      case .modifierFlags(let kc, let onFlags):
        return "mod \(label(kc))[\(describeFlags(onFlags))]"
      }
    }.joined(separator: " , ")
  }

  /// CGEventFlags → 紧凑可读串,如 "⌘⌥" 或 "∅"。
  private static func describeFlags(_ flags: CGEventFlags) -> String {
    var parts: [String] = []
    if flags.contains(.maskCommand)      { parts.append("⌘") }
    if flags.contains(.maskAlternate)    { parts.append("⌥") }
    if flags.contains(.maskControl)      { parts.append("⌃") }
    if flags.contains(.maskShift)        { parts.append("⇧") }
    if flags.contains(.maskSecondaryFn)  { parts.append("fn") }
    if flags.contains(.maskAlphaShift)   { parts.append("⇪") }
    return parts.isEmpty ? "∅" : parts.joined()
  }
}
