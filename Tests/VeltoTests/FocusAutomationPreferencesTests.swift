import Foundation
import Testing

@testable import Velto

/// 旧配置没有 focusAutomation 字段 → 解码成默认值(关闭、带 Movist Pro);
/// 改过的配置编码再解码保持不变。
@Test func focusAutomationPreferencesDecodeAndRoundTrip() throws {
  let legacy = try JSONEncoder().encode(AppPreferences.defaults)
  var object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
  object.removeValue(forKey: "focusAutomation")
  let decoded = try JSONDecoder().decode(
    AppPreferences.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(decoded.focusAutomation == .defaults)
  #expect(decoded.focusAutomation.enabled == false)
  #expect(decoded.focusAutomation.apps.map(\.bundleID) == ["com.movist.MovistPro"])
  #expect(decoded.focusAutomation.apps.first?.trigger == .playing)

  var prefs = AppPreferences.defaults
  prefs.focusAutomation.enabled = true
  prefs.focusAutomation.apps.append(FocusAutomationApp(bundleID: "com.colliderli.iina", trigger: .window))
  prefs.focusAutomation.onShortcutName = "专注开"
  let roundTripped = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs))
  #expect(roundTripped.focusAutomation == prefs.focusAutomation)

  // 子结构缺字段也逐个兜底。
  let partial = try JSONDecoder().decode(
    FocusAutomationPreferences.self, from: Data(#"{"enabled":true}"#.utf8))
  #expect(partial.enabled)
  #expect(partial.offShortcutName == "勿扰关")
}
