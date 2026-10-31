import Foundation
import Testing

@testable import Velto

@Suite("配置变化通知")
@MainActor
struct PreferencesChangeTests {
  @Test("只有这一部分变了才算变")
  func comparesOnlyTheSlice() {
    var current = AppPreferences.defaults
    current.showTrail.toggle()
    let change = PreferencesChange(previous: .defaults, current: current)

    #expect(change.changed(\.showTrail))
    #expect(!change.changed(\.switcher))
    #expect(!change.changed(\.inputSourceSwitch))
    #expect(!change.changed(\.focusAutomation))
  }

  @Test("子字段变化能穿透到上层比较")
  func nestedKeyPath() {
    var current = AppPreferences.defaults
    current.switcher.enabled.toggle()
    let change = PreferencesChange(previous: .defaults, current: current)

    #expect(change.changed(\.switcher))
    #expect(change.changed(\.switcher.enabled))
    #expect(!change.changed(\.screenshot))
  }

  @Test("写回同一个值不发通知,改了才发,并带前后快照")
  func storeNotifiesOnlyOnRealChange() {
    let store = ConfigStore.shared
    let original = store.preferences
    defer { store.updatePreferences { $0 = original } }

    var notes: [Notification] = []
    let observer = NotificationCenter.default.addObserver(
      forName: .configStoreDidChange, object: store, queue: nil
    ) { notes.append($0) }
    defer { NotificationCenter.default.removeObserver(observer) }

    store.updatePreferences { $0.showTrail = original.showTrail }
    #expect(notes.isEmpty)

    store.updatePreferences { $0.showTrail.toggle() }
    #expect(notes.count == 1)
    #expect(notes.first?.configStoreChangeReason == .preferences)
    #expect(notes.first?.preferencesChange?.changed(\.showTrail) == true)
    #expect(notes.first?.preferencesChange?.previous == original)
  }
}
