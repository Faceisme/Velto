import Foundation
import Testing

@testable import Velto

/// 鼠标侧键翻页:按键号 → 按键的映射、按下/抬起的吞事件记账、偏好的持久化兼容。

@Test func sideButtonDefaultsMapToPageKeys() {
  let prefs = GestureSideButtonPreferences.defaults
  #expect(GestureSideButtonController.shortcut(forButton: 3, preferences: prefs)?.keyCode == VirtualKeyCode.pageUp)
  #expect(GestureSideButtonController.shortcut(forButton: 4, preferences: prefs)?.keyCode == VirtualKeyCode.pageDown)
  // 中键等其它按键不接管。
  #expect(GestureSideButtonController.shortcut(forButton: 2, preferences: prefs) == nil)
  #expect(GestureSideButtonController.shortcut(forButton: 5, preferences: prefs) == nil)
}

@Test func sideButtonDisabledOrClearedPassesThrough() {
  var prefs = GestureSideButtonPreferences.defaults
  prefs.back = nil
  #expect(GestureSideButtonController.shortcut(forButton: 3, preferences: prefs) == nil)
  #expect(GestureSideButtonController.shortcut(forButton: 4, preferences: prefs) != nil)
  prefs.enabled = false
  #expect(GestureSideButtonController.shortcut(forButton: 4, preferences: prefs) == nil)
}

@Test func sideButtonSwallowsOnlyItsOwnRelease() {
  let controller = GestureSideButtonController()
  // 没按下过的键,抬起原样透传。
  #expect(controller.release(button: 3) == false)

  #expect(controller.press(button: 3) != nil)
  #expect(controller.isHolding(button: 3))
  #expect(controller.isHolding(button: 4) == false)

  // 按住期间关掉功能,抬起仍要吞掉,不能给 App 留一个没有按下的抬起。
  var disabled = GestureSideButtonPreferences.defaults
  disabled.enabled = false
  controller.updatePreferences(disabled)
  #expect(controller.release(button: 3))
  #expect(controller.isHolding(button: 3) == false)
  #expect(controller.release(button: 3) == false)

  // 关掉后按下不接管。
  #expect(controller.press(button: 3) == nil)
  #expect(controller.release(button: 3) == false)
}

@Test func sideButtonResetDropsHeldButtons() {
  let controller = GestureSideButtonController()
  _ = controller.press(button: 4)
  controller.reset()
  #expect(controller.release(button: 4) == false)
}

@Test func sideButtonPreferencesSurviveRoundTrip() throws {
  // 旧配置没有这个字段 → 回退默认(开启,PageUp / PageDown)。
  var legacy = try JSONSerialization.jsonObject(
    with: JSONEncoder().encode(AppPreferences.defaults)) as! [String: Any]
  legacy.removeValue(forKey: "gestureSideButtons")
  let decodedLegacy = try JSONDecoder().decode(
    AppPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
  #expect(decodedLegacy.gestureSideButtons == .defaults)

  // 用户清空的键存下来再读回仍是 nil,不会被默认值顶回去。
  var prefs = AppPreferences.defaults
  prefs.gestureSideButtons.forward = nil
  let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs))
  #expect(decoded.gestureSideButtons.forward == nil)
  #expect(decoded.gestureSideButtons.back == GestureSideButtonPreferences.defaults.back)
}
