import Foundation
import Testing

@testable import Velto

/// 备份导出 → 导入往返:近期新增的配置(按 App 手势、手势鼠标按钮、最大化鼠标按钮及
/// 例外 App)都要带上,导入后与导出前一致。
@Test @MainActor func backupRoundTripCoversNewFeatures() throws {
  let store = GestureStore.shared
  let middle = MouseButtonTrigger(button: 2, modifierFlags: 0)
  let gesture = GestureCommand(
    name: "最大化", templates: [], buttonTrigger: middle,
    shortcut: Shortcut(keyCode: 19, modifierFlags: 1179648, displayName: "⇧⌘2"))
  let profile = GestureAppProfile(
    bundleIdentifier: "com.movist.MovistPro", displayName: "Movist Pro", path: "/Applications/Movist Pro.app",
    includesGlobalGestures: false,
    gestures: [GestureCommand(name: "播放", templates: [], buttonTrigger: middle,
      shortcut: Shortcut(keyCode: 49, modifierFlags: 0, displayName: "空格"))])
  store.saveGestureSets(global: [gesture], appProfiles: [profile])
  store.updatePreferences {
    $0.windowMaximizeButton = middle
    $0.windowMaximizeButtonExcludedApps = ["com.movist.MovistPro"]
  }
  let backup = try store.exportBackupData()
  let exported = (store.gestures, store.appProfiles, store.preferences)

  // 清掉再导入,应完整恢复。
  store.saveGestureSets(global: [GestureCommand(name: "x", templates: [], shortcut: nil)], appProfiles: [])
  store.updatePreferences { $0.windowMaximizeButton = nil; $0.windowMaximizeButtonExcludedApps = [] }
  try store.importBackupData(backup)

  #expect(store.gestures == exported.0)
  #expect(store.appProfiles == exported.1)
  #expect(store.preferences == exported.2)
  #expect(store.preferences.windowMaximizeButtonExcludedApps == ["com.movist.MovistPro"])
  #expect(store.appProfiles.first?.gestures.first?.buttonTrigger == middle)
}

@Test @MainActor func importingOldBackupKeepsKeyRemapRules() throws {
  let store = GestureStore.shared
  let remaps = KeyRemapStore.shared
  let saved = (remaps.rules, remaps.masterEnabled)
  defer { remaps.replaceAll(rules: saved.0, masterEnabled: saved.1) }
  let rule = KeyRemapRule(title: "Caps", isManual: true, manipulators: [])
  remaps.replaceAll(rules: [rule], masterEnabled: false)

  // 旧备份没有这两个字段。
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  try store.importBackupData(encoder.encode(
    VeltoBackupFile(gestures: store.gestures, preferences: store.preferences)))

  #expect(remaps.rules == [rule])
  #expect(!remaps.masterEnabled)
}

@Test @MainActor func importingBackupRestoresKeyRemapRules() throws {
  let store = GestureStore.shared
  let remaps = KeyRemapStore.shared
  let saved = (remaps.rules, remaps.masterEnabled)
  defer { remaps.replaceAll(rules: saved.0, masterEnabled: saved.1) }
  let rule = KeyRemapRule(title: "Caps", isManual: true, manipulators: [])
  remaps.replaceAll(rules: [rule], masterEnabled: true)
  let backup = try store.exportBackupData()

  remaps.replaceAll(rules: [], masterEnabled: false)
  try store.importBackupData(backup)

  #expect(remaps.rules == [rule])
  #expect(remaps.masterEnabled)
}
