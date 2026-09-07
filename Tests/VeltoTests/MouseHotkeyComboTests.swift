import CoreGraphics
import Foundation
import Testing

@testable import Velto

/// 滚动加速热键改成 ⌃⌥ 后的回归防护。
///
/// 老写法按 trigger.code 那一颗键的 flagsChanged 匹配、完全无视 trigger.modifierFlags,
/// 组合键会废掉:先按 ⌃ 再按 ⌥ 能亮,反过来永远亮不了,松开 ⌃ 也不灭。
/// 现在改成"看当前 flags 有没有按齐",按下顺序与松开就都天然正确。
private let control: UInt64 = 262144
private let option: UInt64 = 524288
private let shift: UInt64 = 131072

/// 造一个 flagsChanged 事件:keyCode 是这一下动的那颗键,flags 是按下后的全集。
private func flagsChanged(key: UInt16, held: UInt64) throws -> MouseTriggerEvent {
  let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
  event.flags = CGEventFlags(rawValue: held)
  return try #require(
    MouseTriggerEvent(type: .flagsChanged, event: event, normalizedFlags: held))
}

/// ⌃⌥ 触发器:code 存 ⌥ 那颗键,modifierFlags 存并集。
private let comboOption = MouseInputTrigger(
  kind: .keyboard, code: MouseKeyCodes.leftOption,
  modifierFlags: control | option, displayName: "⌃⌥")

@Test func comboHotkeyIgnoresPressOrder() throws {
  // 无论最后动的是 ⌃ 还是 ⌥,只要两颗都按齐就算激活。
  #expect(try flagsChanged(key: MouseKeyCodes.leftOption, held: control | option)
    .modifierTriggerActive(comboOption) == true)
  #expect(try flagsChanged(key: MouseKeyCodes.leftControl, held: control | option)
    .modifierTriggerActive(comboOption) == true)
}

@Test func comboHotkeyNeedsEveryModifier() throws {
  // 只按 ⌥(旧配置的老习惯)不能再触发 —— 这正是它不再撞窗口缩放修饰键的原因。
  #expect(try flagsChanged(key: MouseKeyCodes.leftOption, held: option)
    .modifierTriggerActive(comboOption) == false)
  #expect(try flagsChanged(key: MouseKeyCodes.leftControl, held: control)
    .modifierTriggerActive(comboOption) == false)
  // 松开 ⌃ 必须立刻灭。
  #expect(try flagsChanged(key: MouseKeyCodes.leftControl, held: option)
    .modifierTriggerActive(comboOption) == false)
}

@Test func comboHotkeyAllowsExtraModifiers() throws {
  // 多按一颗 ⇧ 不该把加速掐掉。
  #expect(try flagsChanged(key: MouseKeyCodes.leftShift, held: control | option | shift)
    .modifierTriggerActive(comboOption) == true)
}

@Test func nonModifierTriggerFallsBackToMatches() throws {
  // 非修饰键触发器返回 nil,交回原来的 matches + isDown 路径。
  let letterTrigger = MouseInputTrigger(kind: .keyboard, code: 0, modifierFlags: 0, displayName: "A")
  #expect(try flagsChanged(key: 0, held: 0).modifierTriggerActive(letterTrigger) == nil)
}

/// 目标定位失败必须进冷却,否则 Telegram/富途这类零 AX 窗口的 App 会被每个
/// mouseMoved 各一轮跨进程命中测试烧到主线程假死。
@Test func windowDragLookupHasFailureBackoff() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let source = try String(
    contentsOf: root.appendingPathComponent(
      "Sources/Velto/WindowManagement/WindowDragController.swift"), encoding: .utf8)
  #expect(source.contains("private static let lookupBackoff"))
  // applyUpdate 与 prewarm 两条入口都必须过闸,并在失败时记账。
  #expect(source.contains("guard lookupAllowed() else { return false }"))
  #expect(source.contains("self.lookupAllowed()"))
  #expect(source.components(separatedBy: "noteLookupFailure()").count - 1 == 2)
}
