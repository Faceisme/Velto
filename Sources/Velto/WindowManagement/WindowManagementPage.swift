import AppKit
import SwiftUI

// 页头总开关 +「快捷操作」5 行 +(设了最大化鼠标按钮时)例外 App + 调试。
// 改动即时保存,没有草稿和保存栏。
struct WindowManagementPage: View {
  private let store = ConfigStore.shared

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
        SettingsRow(title: "最大化鼠标按钮", subtitle: maximizeButtonSubtitle) {
          ShortcutField(buttonTrigger: pref(\.windowMaximizeButton))
        }
      }

      if let trigger = store.preferences.windowMaximizeButton {
        maximizeButtonExceptions(trigger)
      }

      DebugSection(
        isOn: pref(\.windowManagementDebugLoggingEnabled),
        logURL: WindowManagementDebugLog.fileURL,
        help: "把移动/缩放时的窗口识别决策写入日志文件,排查「移动了错误窗口」这类问题时开启;反馈问题时附上日志更精准。"
      )
    }
  }

  /// 例外 App:光标在这些 App 上时最大化鼠标按钮不接管,按钮原样交给 App 自己
  /// (Velto 不知道 App 内部把这个按钮配成了什么,只能由用户点名)。
  private func maximizeButtonExceptions(_ trigger: MouseButtonTrigger) -> some View {
    let apps = store.preferences.windowMaximizeButtonExcludedApps
    return SettingsSection("最大化鼠标按钮 · 例外 App") {
      if apps.isEmpty {
        EmptyRow("没有例外。App 自己要用\(trigger.displayName)时(如 Movist Pro 中键全屏)加进来,在它上面按\(trigger.displayName)就不会最大化。")
      }
      ForEach(apps, id: \.self) { bundleID in
        BundleAppRow(bundleID: bundleID, title: InstalledApp.displayName(forBundleID: bundleID)) {
          DeleteIconButton {
            store.updatePreferences { $0.windowMaximizeButtonExcludedApps.removeAll { $0 == bundleID } }
          }
        }
      }
    } accessory: {
      AddAppMenu(
        excludedBundleIDs: Set(apps),
        panelTitle: "选择不接管\(trigger.displayName)的 App",
        onPick: addMaximizeButtonException
      )
    }
  }

  private func addMaximizeButtonException(appURL url: URL) {
    guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
    store.updatePreferences { prefs in
      if !prefs.windowMaximizeButtonExcludedApps.contains(bundleID) {
        prefs.windowMaximizeButtonExcludedApps.append(bundleID)
      }
    }
  }

  /// 按钮先经鼠标控制、再经手势,最后才轮到这里;被前两者的全局配置占用时提示一下,
  /// 免得配了按不出来。App 专属手势占用只影响那个 App,不提示。
  private var maximizeButtonSubtitle: String {
    let normal = "按下中键 / 侧键等 → 光标下的窗口最大化"
    guard let trigger = store.preferences.windowMaximizeButton else { return normal }
    let mouse = store.preferences.mouseControl
    if mouse.enabled, mouse.buttonBindings.contains(where: {
      $0.isEnabled && $0.trigger.kind == .mouse
        && Int($0.trigger.code) == trigger.button && $0.trigger.modifierFlags == trigger.modifierFlags
    }) {
      return "\(trigger.displayName)已被鼠标控制占用,不会触发"
    }
    if store.preferences.gesturesEnabled,
       let gesture = store.gestures.first(where: { $0.buttonTrigger == trigger && $0.shortcut != nil }) {
      return "\(trigger.displayName)已被手势「\(gesture.name)」使用,手势优先"
    }
    return normal
  }

  /// 直接读写 store;updatePreferences 会顺带同步调试日志开关。
  private func pref<V>(_ keyPath: WritableKeyPath<AppPreferences, V>) -> Binding<V> {
    Binding(
      get: { store.preferences[keyPath: keyPath] },
      set: { v in store.updatePreferences { $0[keyPath: keyPath] = v } }
    )
  }
}
