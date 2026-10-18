import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import Velto

/// 窗口管理的「最大化鼠标按钮」:按钮 + 修饰键完全匹配才接管,按下时吞掉的按钮
/// 抬起也一并吞掉,偏好兼容旧配置。

/// 造一个鼠标按钮按下事件。坐标放在屏幕外,真走到最大化也找不到窗口。
private func otherMouseDown(button: Int64) throws -> CGEvent {
  let event = try #require(CGEvent(
    mouseEventSource: nil, mouseType: .otherMouseDown,
    mouseCursorPosition: CGPoint(x: -30000, y: -30000), mouseButton: .center))
  event.setIntegerValueField(.mouseEventButtonNumber, value: button)
  return event
}

private let command: UInt64 = 1 << 20

@Test func maximizeButtonIgnoredUntilConfigured() throws {
  let controller = WindowShortcutController()
  #expect(controller.handleMouseDown(event: try otherMouseDown(button: 2), normalizedFlags: 0) == false)
  #expect(controller.handleMouseUp(button: 2) == false)
}

@Test func maximizeButtonMatchesButtonAndModifiersExactly() throws {
  let controller = WindowShortcutController()
  controller.updateMaximizeButton(MouseButtonTrigger(button: 2, modifierFlags: 0))

  // 别的按钮、多按了修饰键:都不接管。
  #expect(controller.handleMouseDown(event: try otherMouseDown(button: 3), normalizedFlags: 0) == false)
  #expect(controller.handleMouseDown(event: try otherMouseDown(button: 2), normalizedFlags: command) == false)
  #expect(controller.isHoldingButton(2) == false)

  // 中键:接管,抬起一并吞掉,只吞一次。
  #expect(controller.handleMouseDown(event: try otherMouseDown(button: 2), normalizedFlags: 0))
  #expect(controller.isHoldingButton(2))
  #expect(controller.handleMouseUp(button: 2))
  #expect(controller.handleMouseUp(button: 2) == false)
}

@Test func maximizeButtonReleaseSurvivesDisableAndReset() throws {
  let controller = WindowShortcutController()
  controller.updateMaximizeButton(MouseButtonTrigger(button: 4, modifierFlags: command))
  #expect(controller.handleMouseDown(event: try otherMouseDown(button: 4), normalizedFlags: command))
  // 按住期间清掉配置,抬起仍要吞掉,不能给 App 留一个没有按下的抬起。
  controller.updateMaximizeButton(nil)
  #expect(controller.handleMouseUp(button: 4))

  controller.updateMaximizeButton(MouseButtonTrigger(button: 4, modifierFlags: command))
  #expect(controller.handleMouseDown(event: try otherMouseDown(button: 4), normalizedFlags: command))
  // tap 被系统禁用后重启:记账清零,之后那颗按钮的抬起照常放行。
  controller.resetTransientState()
  #expect(controller.handleMouseUp(button: 4) == false)
}

@Test func maximizeButtonPreferenceDecodesFromLegacyConfig() throws {
  var prefs = AppPreferences.defaults
  #expect(prefs.windowMaximizeButton == nil)
  prefs.windowMaximizeButton = MouseButtonTrigger(button: 2, modifierFlags: 0)
  let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs))
  #expect(decoded.windowMaximizeButton == MouseButtonTrigger(button: 2, modifierFlags: 0))

  // 旧配置没有这个字段:解码为 nil,其它字段照常。
  var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs)) as! [String: Any]
  legacy.removeValue(forKey: "windowMaximizeButton")
  let decodedLegacy = try JSONDecoder().decode(
    AppPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
  #expect(decodedLegacy.windowMaximizeButton == nil)
  #expect(decodedLegacy.windowManagementEnabled == prefs.windowManagementEnabled)
}

@Test func maximizeButtonPassesThroughExcludedApps() throws {
  // 造出来的事件不带窗口号 / 目标进程,按「光标下的 App」判定会退到前台 App ——
  // 把前台 App 设成例外,按钮就该原样放行(Movist Pro 自己用中键全屏的场景)。
  let front = try #require(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
  let controller = WindowShortcutController()
  let middle = MouseButtonTrigger(button: 2, modifierFlags: 0)
  controller.updateMaximizeButton(middle, excludedApps: [front])
  #expect(controller.handleMouseDown(event: try otherMouseDown(button: 2), normalizedFlags: 0) == false)
  #expect(controller.isHoldingButton(2) == false)
  #expect(controller.handleMouseUp(button: 2) == false)

  // 别的 App 是例外不影响这里:照常接管。
  controller.updateMaximizeButton(middle, excludedApps: ["com.example.other"])
  #expect(controller.handleMouseDown(event: try otherMouseDown(button: 2), normalizedFlags: 0))
  #expect(controller.handleMouseUp(button: 2))
}

@Test func maximizeButtonExceptionsRoundTrip() throws {
  var prefs = AppPreferences.defaults
  #expect(prefs.windowMaximizeButtonExcludedApps.isEmpty)
  prefs.windowMaximizeButtonExcludedApps = ["com.movist.MovistPro"]
  let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs))
  #expect(decoded.windowMaximizeButtonExcludedApps == ["com.movist.MovistPro"])

  var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs)) as! [String: Any]
  legacy.removeValue(forKey: "windowMaximizeButtonExcludedApps")
  let decodedLegacy = try JSONDecoder().decode(
    AppPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
  #expect(decodedLegacy.windowMaximizeButtonExcludedApps.isEmpty)
}
