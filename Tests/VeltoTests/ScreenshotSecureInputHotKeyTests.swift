import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import Velto

/// 截图触发键的安全输入兜底:修饰位映射到 Carbon 要与 tap 的匹配一致,带 Fn 不注册
/// (Carbon 没有 Fn 位,注册了会误吃不带 Fn 的组合)。
@Test func screenshotHotKeyCarbonModifiers() {
  let cmd = UInt64(CGEventFlags.maskCommand.rawValue)
  let shift = UInt64(CGEventFlags.maskShift.rawValue)
  let opt = UInt64(CGEventFlags.maskAlternate.rawValue)
  let ctrl = UInt64(CGEventFlags.maskControl.rawValue)
  let fn = UInt64(CGEventFlags.maskSecondaryFn.rawValue)

  // ⇧⌘D 的真实偏好值 1179648
  #expect(cmd | shift == 1_179_648)
  #expect(ScreenshotShortcutController.carbonModifiers(cmd | shift) == UInt32(cmdKey | shiftKey))
  #expect(ScreenshotShortcutController.carbonModifiers(opt | ctrl) == UInt32(optionKey | controlKey))
  #expect(ScreenshotShortcutController.carbonModifiers(cmd | fn) == nil)
}
