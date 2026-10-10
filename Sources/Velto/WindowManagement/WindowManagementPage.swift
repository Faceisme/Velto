import SwiftUI

// 页头总开关 +「快捷操作」4 行 + 调试。改动即时保存,没有草稿和保存栏。
struct WindowManagementPage: View {
  private let store = GestureStore.shared

  var body: some View {
    SettingsPage {
      PageHeader(
        page: .window,
        subtitle: "按住修饰键 + 拖动鼠标即可移动或缩放当前窗口。",
        isOn: pref(\.windowManagementEnabled)
      )
      .help("关闭后,移动/缩放窗口、滚轮缩放、窗口快捷键全部停用,不影响手势与鼠标控制。")

      SettingsSection("快捷操作") {
        SettingsRow(title: "移动窗口", subtitle: "按住此键 + 移动鼠标 → 拖动当前窗口") {
          ShortcutField(modifiers: pref(\.windowMoveModifierFlags))
        }
        SettingsRow(title: "缩放窗口", subtitle: "按住此键 + 移动鼠标 → 按光标所在边角缩放") {
          ShortcutField(modifiers: pref(\.windowResizeModifierFlags))
        }
        SettingsRow(title: "滚轮缩放修饰键", subtitle: "按住此键 + 滚动滚轮 → 缩放页面内容") {
          ShortcutField(modifiers: pref(\.contentZoomModifierFlags))
        }
        SettingsRow(title: "最大化快捷键", subtitle: "按下此快捷键 → 光标下的窗口最大化") {
          ShortcutField(shortcut: pref(\.windowMaximizeShortcut))
        }
      }

      DebugSection(
        isOn: pref(\.windowManagementDebugLoggingEnabled),
        logURL: WindowManagementDebugLog.fileURL,
        help: "把移动/缩放时的窗口识别决策写入日志文件,排查「移动了错误窗口」这类问题时开启;反馈问题时附上日志更精准。"
      )
    }
  }

  /// 直接读写 store;updatePreferences 会顺带同步调试日志开关。
  private func pref<V>(_ keyPath: WritableKeyPath<AppPreferences, V>) -> Binding<V> {
    Binding(
      get: { store.preferences[keyPath: keyPath] },
      set: { v in store.updatePreferences { $0[keyPath: keyPath] = v } }
    )
  }
}
