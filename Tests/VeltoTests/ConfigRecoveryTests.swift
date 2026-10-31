import Foundation
import Testing
import betterfinder

@testable import Velto

/// 不落盘的 UserDefaults。真 suite 用完会在 ~/Library/Preferences 留下空 plist,
/// cfprefsd 又是异步写的,测试结束时删不掉。
private final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
  private var values: [String: Any] = [:]

  override func set(_ value: Any?, forKey key: String) { values[key] = value }
  override func data(forKey key: String) -> Data? { values[key] as? Data }
}

/// 配置读不出来时不能静默清零:能保住的字段保住,原始数据留底,用户知道发生了什么。
@Suite("配置恢复")
@MainActor
struct ConfigRecoveryTests {
  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("velto-config-\(UUID().uuidString)")
  }

  private func backups(in directory: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
  }

  /// 拿默认配置改出一份 JSON,模拟旧版本读到新版本写的配置。
  private func preferencesJSON(_ edit: (inout [String: Any]) -> Void) throws -> Data {
    let data = try JSONEncoder().encode(AppPreferences.defaults)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    edit(&object)
    return try JSONSerialization.data(withJSONObject: object)
  }

  private func futureSortOrder(_ object: inout [String: Any]) {
    var switcher = object["switcher"] as? [String: Any] ?? [:]
    switcher["sortBy"] = "valueFromTheFuture"
    object["switcher"] = switcher
  }

  @Test("完好的配置读取结果不变,也不留备份")
  func intactPreferencesRoundTrip() throws {
    var preferences = AppPreferences.defaults
    preferences.showTrail.toggle()
    preferences.gestureTargetPolicy = .activeWindow
    preferences.switcher.sortBy = .alphabetical
    preferences.mouseControl.scroll.duration = 3.2
    preferences.screenshot.showMagnifier.toggle()
    preferences.focusAutomation.apps = [FocusAutomationApp(bundleID: "a.b", trigger: .window)]
    preferences.macAssistant.screenCleanUnlockShortcut = Shortcut(keyCode: 1, modifierFlags: 0, displayName: "S")
    let directory = temporaryDirectory()

    let decoded = ConfigRecovery.decode(
      AppPreferences.self, from: try JSONEncoder().encode(preferences), key: "intact",
      decoder: JSONDecoder(), directory: directory)

    #expect(decoded == preferences)
    #expect(backups(in: directory).isEmpty)
  }

  @Test("一个字段读不出来只影响它自己")
  func badFieldKeepsTheRest() throws {
    let data = try preferencesJSON {
      $0["showTrail"] = !AppPreferences.defaults.showTrail
      $0["gestureTargetPolicy"] = "valueFromTheFuture"
      futureSortOrder(&$0)
    }
    let directory = temporaryDirectory()

    let decoded = try #require(ConfigRecovery.decode(
      AppPreferences.self, from: data, key: "partial", decoder: JSONDecoder(), directory: directory))

    #expect(decoded.showTrail != AppPreferences.defaults.showTrail)
    #expect(decoded.gestureTargetPolicy == AppPreferences.defaults.gestureTargetPolicy)
    #expect(decoded.switcher.sortBy == AppPreferences.defaults.switcher.sortBy)
    let notice = try #require(ConfigRecovery.notices.last { $0.key == "partial" })
    #expect(Set(notice.fields) == ["gestureTargetPolicy", "switcher.sortBy"])
    #expect(try Data(contentsOf: notice.backupURL) == data)
  }

  @Test("整份读不出来时返回 nil 并保住原始数据")
  func undecodableDataIsPreserved() throws {
    let data = Data("not json".utf8)
    let directory = temporaryDirectory()

    let decoded = ConfigRecovery.decode(
      [GestureCommand].self, from: data, key: "whole", decoder: JSONDecoder(), directory: directory)

    #expect(decoded == nil)
    let notice = try #require(ConfigRecovery.notices.last { $0.key == "whole" })
    #expect(notice.fields == ["whole"])
    #expect(try Data(contentsOf: notice.backupURL) == data)
  }

  /// 不改配置时每次启动都读到同一份坏数据,不能反复弹窗。
  @Test("同一份数据只备份一次")
  func sameDataPreservedOnce() throws {
    let data = Data("not json".utf8)
    let directory = temporaryDirectory()
    for _ in 0..<2 {
      _ = ConfigRecovery.decode(
        [GestureCommand].self, from: data, key: "once", decoder: JSONDecoder(), directory: directory)
    }
    #expect(backups(in: directory).count == 1)
    #expect(ConfigRecovery.notices.filter { $0.key == "once" }.count == 1)
  }

  /// 导入备份走普通解码:坏备份要报错,不能静默导入成默认值。
  @Test("没走配置恢复的解码仍然严格")
  func plainDecodingStaysStrict() throws {
    let data = try preferencesJSON { futureSortOrder(&$0) }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(AppPreferences.self, from: data)
    }
  }

  @Test("用完的解码器不再宽松")
  func decoderIsLeftStrict() throws {
    let decoder = JSONDecoder()
    let data = try preferencesJSON { futureSortOrder(&$0) }
    _ = ConfigRecovery.decode(
      AppPreferences.self, from: data, key: "reuse", decoder: decoder, directory: temporaryDirectory())
    #expect(throws: DecodingError.self) {
      try decoder.decode(AppPreferences.self, from: data)
    }
  }

  @Test("增强Finder配置读不懂时留底,不覆盖")
  func betterFinderKeepsUndecodableFile() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("preferences.json")
    let damaged = Data("{ damaged".utf8)
    try damaged.write(to: file)

    let store = BetterFinderPreferencesStore(defaults: InMemoryDefaults(), fileURL: file)

    #expect(store.preferences == .defaults)
    let aside = try #require(backups(in: directory).first { $0.lastPathComponent.contains("undecodable") })
    #expect(try Data(contentsOf: aside) == damaged)
    #expect(try JSONDecoder().decode(BetterFinderPreferences.self, from: Data(contentsOf: file)) == .defaults)
  }
}
