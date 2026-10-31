import Foundation
import Testing

@testable import Velto

/// 旧配置里的 appRules 和动态分组在解码时并入固定两组,之后只有分组一种结构。
@Suite("输入法旧规则迁移")
struct InputSourceLegacyRulesTests {
  private func decode(_ json: String) throws -> InputSourceSwitchPreferences {
    try JSONDecoder().decode(InputSourceSwitchPreferences.self, from: Data(json.utf8))
  }

  @Test("启用的旧规则并入中文组,输入法取第一个非空的")
  func legacyRulesMoveIntoChineseGroup() throws {
    let prefs = try decode(#"""
    {"appRules": [
      {"bundleIdentifier": "com.a", "inputSourceID": "pinyin", "isEnabled": true},
      {"bundleIdentifier": "com.b", "isEnabled": true},
      {"bundleIdentifier": "com.off", "inputSourceID": "other", "isEnabled": false}
    ]}
    """#)

    let chinese = try #require(prefs.appGroups.first { $0.role == .chinese })
    #expect(chinese.bundleIdentifiers == ["com.a", "com.b"])
    #expect(chinese.inputSourceID == "pinyin")
    #expect(prefs.appGroups.count == 2)
  }

  @Test("重新编码后不再有 appRules")
  func encodedConfigDropsLegacyKey() throws {
    let prefs = try decode(#"{"appRules": [{"bundleIdentifier": "com.a", "isEnabled": true}]}"#)
    let json = try #require(String(data: JSONEncoder().encode(prefs), encoding: .utf8))
    #expect(!json.contains("appRules"))
  }

  @Test("没有旧数据时解码结果和默认值一样")
  func plainConfigStaysDefault() throws {
    let prefs = try decode("{}")
    #expect(prefs == .defaults)
  }

  @Test("规整是幂等的")
  func ensureFixedGroupsIsIdempotent() {
    var prefs = InputSourceSwitchPreferences.defaults
    prefs.ensureFixedGroups()
    let once = prefs
    prefs.ensureFixedGroups()
    #expect(prefs == once)
  }
}
