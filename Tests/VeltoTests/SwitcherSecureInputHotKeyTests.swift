import CoreGraphics
import Testing
@testable import Velto

/// 安全输入兜底:触发键 → 热键的映射必须与 tap 的匹配规则一致(多按 ⇧ = 反向),
/// 带 Fn 时不注册(Carbon 没有 Fn 位,注册了会误吃不带 Fn 的组合)。
@Test func secureInputHotKeysMirrorTapMatching() {
  let cmd = UInt64(CGEventFlags.maskCommand.rawValue)
  let shift = UInt64(CGEventFlags.maskShift.rawValue)
  let opt = UInt64(CGEventFlags.maskAlternate.rawValue)
  let fn = UInt64(CGEventFlags.maskSecondaryFn.rawValue)

  let cmdTab = SwitcherKeyTap.secureInputHotKeys(modifierFlags: cmd)
  #expect(cmdTab.map { $0.modifierFlags } == [cmd, cmd | shift])
  #expect(cmdTab.map { $0.reverse } == [false, true])

  // 触发键自带 ⇧:两种组合都算正向
  let shifted = SwitcherKeyTap.secureInputHotKeys(modifierFlags: opt | shift)
  #expect(shifted.map { $0.modifierFlags } == [opt, opt | shift])
  #expect(shifted.map { $0.reverse } == [false, false])

  #expect(SwitcherKeyTap.secureInputHotKeys(modifierFlags: cmd | fn).isEmpty)
}
