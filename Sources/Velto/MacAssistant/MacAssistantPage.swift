import SwiftUI

/// Mac小助手:零碎的小工具,一个工具一个分组。改动即时保存。
struct MacAssistantPage: View {
  private let store = GestureStore.shared
  private let cleaner = ScreenCleanController.shared

  var body: some View {
    SettingsPage {
      PageHeader(page: .macAssistant, subtitle: "顺手的系统小工具。")

      SettingsSection("擦屏助手") {
        SettingsRow(
          "擦屏模式",
          subtitle: "打开后所有屏幕变黑、键盘锁定,按解锁快捷键才恢复。",
          isOn: Binding(get: { cleaner.isActive }, set: { cleaner.setActive($0) })
        )
        SettingsRow(title: "解锁快捷键", subtitle: "必须包含 ⌘ / ⌃ / ⌥ 之一,免得擦键盘时误触。") {
          // 不给清除:没有解锁键就出不来了。
          ShortcutField(hasValue: false, clear: {}) {
            ShortcutRecorderField(
              shortcut: Binding(
                get: { store.preferences.macAssistant.screenCleanUnlockShortcut },
                set: { newValue in
                  // 裸键 / 仅 ⇧ 的录入直接忽略,保留旧值。
                  guard let s = newValue, s.hasRealModifier else { return }
                  store.updatePreferences { $0.macAssistant.screenCleanUnlockShortcut = s }
                }
              ),
              placeholder: "点击录制"
            )
          }
        }
      }
    }
  }
}
