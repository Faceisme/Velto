import SwiftUI

/// 窗口切换器的设置页。改动即时保存。
struct SwitcherSettingsPage: View {
  private let store = ConfigStore.shared

  var body: some View {
    SettingsPage {
      PageHeader(
        page: .switcher,
        subtitle: "类似 Win11 风格的窗口切换器,按快捷键呼出,带实时缩略图。",
        isOn: bind(\.enabled)
      )
      .help("关闭后 ⌘+Tab 会还给 macOS 系统原生切换器。")

      SettingsSection("触发") {
        SettingsRow(title: "触发快捷键", subtitle: "按住不放可循环选择,松开即切换。") {
          // 不给清除:清空会静默回退默认 ⌘+Tab,框里却显示空。
          ShortcutField(hasValue: false, clear: {}) {
            ShortcutRecorderField(
              shortcut: Binding(
                get: { store.preferences.switcher.triggerShortcut },
                set: { newValue in
                  // 触发键必须含真 modifier(⌘/⌃/⌥),裸键 / 仅 Shift 的录入直接忽略(保留旧值)。
                  if let s = newValue, !s.hasRealModifier { return }
                  store.updatePreferences { $0.switcher.triggerShortcut = newValue }
                }
              ),
              placeholder: "点击录制"
            )
          }
        }
        .help("默认 ⌘+Tab,改完立即生效;必须含 ⌘ / ⌥ / ⌃ 之一。")
        SettingsRow(title: "显示于", subtitle: "切换器面板出现在哪块屏幕。") {
          menuPicker(\.showOnScreen)
        }
      }

      SettingsSection("显示哪些窗口") {
        SettingsRow(title: "来自应用") { menuPicker(\.appsToShow) }
        SettingsRow(title: "来自桌面") { menuPicker(\.spacesToShow) }
        SettingsRow(title: "来自屏幕") { menuPicker(\.screensToShow) }
        SettingsRow(title: "最小化窗口") { menuPicker(\.minimizedWindows) }
        SettingsRow(title: "隐藏窗口", subtitle: "用 ⌘H 隐藏的应用的窗口。") { menuPicker(\.hiddenWindows) }
        SettingsRow(title: "全屏窗口") { menuPicker(\.fullscreenWindows) }
        SettingsRow(title: "没有窗口的应用") { menuPicker(\.windowlessApps) }
      }

      SettingsSection("排序与外观") {
        SettingsRow(title: "分组方式", subtitle: "按应用时每个应用只保留一个条目。") {
          menuPicker(\.groupBy)
        }
        .help("按窗口 = 每个窗口/标签一个条目;按应用 = 每个应用只保留一个(MRU 代表),终端/Chrome 标签多时更清爽。")
        SettingsRow(title: "排序", subtitle: "窗口在切换器里的排列顺序。") {
          menuPicker(\.sortBy)
        }
        SettingsRow(title: "外观", subtitle: "缩略图 = Win11 风格;仅图标 = macOS 原生 ⌘+Tab 风格。") {
          menuPicker(\.appearanceStyle)
        }
      }

      DebugSection(
        isOn: bind(\.debugLoggingEnabled),
        logURL: SwitcherDebugLog.fileURL,
        help: "排查切换器问题时打开,只写 switcher-debug.log,不影响其它模块。平时保持关闭。"
      )
    }
  }

  // MARK: - 通用枚举下拉组件

  /// 给一个枚举 KeyPath,自动渲染一个 Menu-style Picker。
  /// 要求枚举 conform `CaseIterable & Equatable & RawRepresentable`,且有
  /// `displayName: String` —— 我们 SwitcherPreferences 里所有枚举都满足。
  private func menuPicker<E>(
    _ keyPath: WritableKeyPath<SwitcherPreferences, E>
  ) -> some View where E: CaseIterable & Hashable & RawRepresentable, E.AllCases: RandomAccessCollection, E.RawValue: Hashable {
    MGMenuPicker(
      selection: bind(keyPath),
      options: Array(E.allCases).map { MGMenuOption($0, displayName(of: $0)) },
      minWidth: 160
    )
  }

  /// 给 menuPicker 用 —— Swift 泛型没法把"任意自带 displayName 的枚举"约束
  /// 成一个 protocol(displayName 是 computed property,反射看不到),所以
  /// 这里手动 switch by type。新增 SwitcherPreferences 字段时记得加一行。
  private func displayName<E>(of value: E) -> String {
    if let v = value as? SwitcherShowMode { return v.displayName }
    if let v = value as? SwitcherAppsScope { return v.displayName }
    if let v = value as? SwitcherSpacesScope { return v.displayName }
    if let v = value as? SwitcherScreensScope { return v.displayName }
    if let v = value as? SwitcherSortOrder { return v.displayName }
    if let v = value as? SwitcherGroupingMode { return v.displayName }
    if let v = value as? SwitcherScreenChoice { return v.displayName }
    if let v = value as? SwitcherAppearanceStyle { return v.displayName }
    return String(describing: value)
  }

  // MARK: - Live binding helper

  /// 把 store.preferences.switcher 上的一个 KeyPath 包成 SwiftUI Binding,
  /// 设值时自动跑 store.updatePreferences(把持久化和通知一并搞定)。
  private func bind<V>(_ keyPath: WritableKeyPath<SwitcherPreferences, V>) -> Binding<V> {
    Binding(
      get: { store.preferences.switcher[keyPath: keyPath] },
      set: { newValue in
        store.updatePreferences { prefs in
          prefs.switcher[keyPath: keyPath] = newValue
        }
      }
    )
  }
}
