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

final class KeyRemapController: @unchecked Sendable {
  // tap 线程独占，无需 lock
  private var normalKeyTable: [UInt16: [CompiledManipulator]] = [:]    // from 普通键
  private var modifierKeyTable: [UInt16: [CompiledManipulator]] = [:]  // from 修饰键
  private var modeB_mandatoryCodes: Set<UInt16> = []                   // 所有 Mode B mandatory

  private var suppressedModifiers: Set<UInt16> = []   // 已吞掉的修饰键 keyCode（Mode B）
  private var activeRemaps: [UInt16: CompiledManipulator] = [:]        // 已按下待 keyUp
  private var previousFlags: CGEventFlags = []
  private var hyperActive: Bool = false               // hyper key 是否激活中

  // MARK: - 更新查找表（在 tap 线程调用）

  func update(rules: [KeyRemapRule]) {
    var normal: [UInt16: [CompiledManipulator]] = [:]
    var modifier: [UInt16: [CompiledManipulator]] = [:]
    var modeCodes: Set<UInt16> = []

    for rule in rules where rule.enabled {
      for m in rule.manipulators {
        let compiled = compile(m)
        if m.from.isModifier {
          modifier[m.from.keyCode, default: []].append(compiled)
        } else {
          normal[m.from.keyCode, default: []].append(compiled)
          modeCodes.formUnion(compiled.mandatoryCodes)
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
  }

  // MARK: - Event handlers（返回 true = 事件已消费，EventTapManager 应 return nil）

  func handleFlagsChanged(event: CGEvent) -> Bool {
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let currentFlags = event.flags

    defer { previousFlags = currentFlags }

    // Mode B：修饰键进入 suppress 逻辑
    if modeB_mandatoryCodes.contains(keyCode) {
      let wasHeld = suppressedModifiers.contains(keyCode)
      let isNowPressed = isModifierPressed(keyCode: keyCode, current: currentFlags,
                                           previous: previousFlags)
      if isNowPressed && !wasHeld {
        suppressedModifiers.insert(keyCode)
        return true   // 吞掉 press
      } else if !isNowPressed && wasHeld {
        suppressedModifiers.remove(keyCode)
        return true   // 吞掉 release
      }
    }

    // Mode A：修饰键本身作为 from
    guard let candidates = modifierKeyTable[keyCode], !candidates.isEmpty else {
      return false
    }
    let manipulator = candidates[0]   // 同一 from 键取第一条规则（同 Karabiner）

    let pressed = isModifierPressed(keyCode: keyCode, current: currentFlags, previous: previousFlags)
    for action in manipulator.toActions {
      synthesize(action: action, press: pressed)
    }
    return true
  }

  func handleKeyDown(event: CGEvent) -> Bool {
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    guard let candidates = normalKeyTable[keyCode] else { return false }

    // 找第一条 mandatory ⊆ suppressedModifiers 的规则
    guard let m = candidates.first(where: { $0.mandatoryCodes.isSubset(of: suppressedModifiers) }) else {
      return false
    }
    activeRemaps[keyCode] = m
    for action in m.toActions { synthesize(action: action, press: true) }
    return true
  }

  func handleKeyUp(event: CGEvent) -> Bool {
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    guard let m = activeRemaps.removeValue(forKey: keyCode) else { return false }
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

  private func synthesize(action: CompiledToAction, press: Bool) {
    let marker = ShortcutSynthesizer.syntheticEventMarker
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }

    switch action {
    case .disable:
      break   // 什么都不发

    case .key(let keyCode, let flags):
      guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: press) else { return }
      e.flags = flags
      e.setIntegerValueField(.eventSourceUserData, value: marker)
      e.post(tap: .cghidEventTap)

    case .modifierFlags(let keyCode, let onFlags):
      // 按下时发 onFlags，松开时清零
      let newFlags: CGEventFlags = press ? onFlags : []
      guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: press) else { return }
      e.type = .flagsChanged
      e.flags = newFlags
      e.setIntegerValueField(.eventSourceUserData, value: marker)
      e.post(tap: .cghidEventTap)
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
}
