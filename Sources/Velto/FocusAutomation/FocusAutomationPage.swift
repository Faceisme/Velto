import AppKit
import SwiftUI

/// 专注自动化设置页。写入走 GestureStore.shared.updatePreferences { $0.focusAutomation.xxx = ... },
/// FocusAutomationController 收到 .gestureStoreDidChange 后重新评估。
struct FocusAutomationPage: View {
  private let store = GestureStore.shared
  private let controller = FocusAutomationController.shared

  @State private var prefs = GestureStore.shared.preferences.focusAutomation
  /// 系统快捷键这条路为什么走不通;nil = 能用。要读文件,不放 body 里每次算。
  @State private var hotkeyUnavailableReason = DoNotDisturbSwitch.keyboardUnavailableReason()

  var body: some View {
    SettingsPage {
      PageHeader(
        page: .focusAutomation,
        subtitle: "指定 App 在用时自动打开勿扰模式,用完自动关闭。",
        isOn: bind(\.enabled)
      )
      .help("关闭后不再自动开关勿扰;若此时勿扰是 Velto 打开的,会顺手关掉。")

      GroupCard {
        SettingsRow(title: "当前状态", subtitle: statusDetail) {
          Text(controller.focusApplied ? "已打开" : "未打开")
            .font(.mgBody)
            .foregroundStyle(controller.focusApplied ? Color.mgAccent : Color.mgText2)
        }
        if let error = controller.lastError {
          SettingsRow(title: "快捷指令运行失败", subtitle: error) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
      }

      SettingsSection("App") {
        if prefs.apps.isEmpty {
          EmptyRow("还没有 App。添加视频播放器等 App,在用时自动开勿扰。")
        }
        ForEach(prefs.apps) { app in
          BundleAppRow(bundleID: app.bundleID, title: InstalledApp.displayName(forBundleID: app.bundleID)) {
            MGMenuPicker(
              selection: Binding(
                get: { app.trigger },
                set: { v in updateApp(app.bundleID) { $0.trigger = v } }
              ),
              options: FocusAutomationTrigger.allCases.map { MGMenuOption($0, $0.displayName) },
              minWidth: 120
            )
            .fixedSize()
            .help("播放视频时:开始播放才算在用,暂停不算结束,窗口全部关掉才结束。\n有窗口时:有窗口就算在用。")
            DeleteIconButton {
              updatePrefs { $0.focusAutomation.apps.removeAll { $0.bundleID == app.bundleID } }
            }
          }
        }
      } accessory: {
        AddAppMenu(
          excludedBundleIDs: Set(prefs.apps.map(\.bundleID)),
          panelTitle: "选择在用时开勿扰的 App",
          onPick: addApp
        )
      }

      SettingsSection("切换方式") {
        SettingsRow(
          "优先用系统快捷键",
          subtitle: hotkeySubtitle,
          isOn: bind(\.preferSystemHotkey)
        )
        .help("模拟按下系统「打开/关闭勿扰模式」快捷键,没有任何提示;用不了或没生效时改用下面的快捷指令(菜单栏会闪一下运行指示)。")
        if prefs.preferSystemHotkey, hotkeyUnavailableReason != nil {
          SettingsRow(title: "去设置") {
            Button("完全磁盘访问权限") { PermissionManager.openPrivacySettings("Privacy_AllFiles") }
              .buttonStyle(.bordered)
            Button("键盘快捷键", action: PermissionManager.openKeyboardSettings)
              .buttonStyle(.bordered)
            Button("重新检查", action: refreshHotkeyStatus)
              .buttonStyle(.bordered)
          }
        }
      }

      SettingsSection(prefs.preferSystemHotkey && hotkeyUnavailableReason == nil ? "快捷指令(备用)" : "快捷指令") {
        SettingsRow(title: "开始时运行", subtitle: shortcutSubtitle(prefs.onShortcutName)) {
          shortcutPicker(bind(\.onShortcutName))
        }
        SettingsRow(title: "结束时运行", subtitle: shortcutSubtitle(prefs.offShortcutName)) {
          shortcutPicker(bind(\.offShortcutName))
        }
        SettingsRow(
          title: "怎么建",
          subtitle: "macOS 没有开关勿扰的接口,要借快捷指令:新建两个快捷指令,各加一个「设定专注模式」动作,分别把勿扰模式设为打开 / 关闭。"
        ) {
          Button("刷新") { controller.refreshShortcutNames() }
            .buttonStyle(.bordered)
          Button("打开快捷指令", action: openShortcutsApp)
            .buttonStyle(.bordered)
        }
      }

      DebugSection(
        isOn: bind(\.debugLoggingEnabled),
        logURL: FocusAutomationDebugLog.fileURL,
        help: "把在用 App 的变化、快捷指令运行结果写入日志文件,排查没自动开关时开启。"
      )
    }
    .onAppear {
      controller.refreshShortcutNames()
      refreshHotkeyStatus()
    }
    // 从「快捷指令」/ 系统设置回来,重新读一遍名字和权限。
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      controller.refreshShortcutNames()
      refreshHotkeyStatus()
    }
    .onReceive(NotificationCenter.default.publisher(for: .gestureStoreDidChange)) { _ in
      prefs = store.preferences.focusAutomation
    }
  }

  private var statusDetail: String {
    guard prefs.enabled else { return "模块已关闭" }
    let names = controller.activeBundleIDs.map(InstalledApp.displayName(forBundleID:))
    let using = names.isEmpty ? "没有 App 在用" : "\(names.joined(separator: "、")) 在用"
    return controller.lastMethod.map { "\(using) · 上次通过\($0)切换" } ?? using
  }

  private var hotkeySubtitle: String {
    guard prefs.preferSystemHotkey else { return "已关闭,一律用快捷指令" }
    return hotkeyUnavailableReason.map { "暂时用不了:\($0)" } ?? "可用,切换时没有任何提示"
  }

  private func refreshHotkeyStatus() {
    hotkeyUnavailableReason = DoNotDisturbSwitch.keyboardUnavailableReason()
  }

  /// 名字在「快捷指令」里找不到时提示一下,免得开关时才发现没反应。
  private func shortcutSubtitle(_ name: String) -> String? {
    guard let names = controller.shortcutNames, !names.contains(name) else { return nil }
    return "找不到快捷指令「\(name)」"
  }

  private func shortcutPicker(_ selection: Binding<String>) -> some View {
    var names = controller.shortcutNames ?? []
    if !names.contains(selection.wrappedValue) { names.insert(selection.wrappedValue, at: 0) }
    return MGMenuPicker(selection: selection, options: names.map { MGMenuOption($0, $0) })
      .fixedSize()
  }

  private func openShortcutsApp() {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
  }

  // MARK: - 辅助

  private func addApp(appURL url: URL) {
    guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
    updatePrefs { p in
      if !p.focusAutomation.apps.contains(where: { $0.bundleID == bundleID }) {
        p.focusAutomation.apps.append(FocusAutomationApp(bundleID: bundleID))
      }
    }
  }

  private func updateApp(_ bundleID: String, _ block: (inout FocusAutomationApp) -> Void) {
    updatePrefs { p in
      if let i = p.focusAutomation.apps.firstIndex(where: { $0.bundleID == bundleID }) {
        block(&p.focusAutomation.apps[i])
      }
    }
  }

  private func bind<V>(_ keyPath: WritableKeyPath<FocusAutomationPreferences, V>) -> Binding<V> {
    Binding(
      get: { prefs[keyPath: keyPath] },
      set: { v in updatePrefs { $0.focusAutomation[keyPath: keyPath] = v } }
    )
  }

  private func updatePrefs(_ block: (inout AppPreferences) -> Void) {
    store.updatePreferences(block)
    prefs = store.preferences.focusAutomation
  }
}
