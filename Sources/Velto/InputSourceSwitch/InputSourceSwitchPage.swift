import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

struct InputSourceSwitchPage: View {
  private let store = GestureStore.shared

  private enum Segment: String, CaseIterable, Identifiable {
    case general, appRules, browserRules
    var id: String { rawValue }
    var title: String {
      switch self {
      case .general: return "通用"
      case .appRules: return "应用规则"
      case .browserRules: return "浏览器规则"
      }
    }
  }

  @State private var segment: Segment = .general
  @State private var editingBrowserRule: InputSourceBrowserRule?
  /// 「添加应用」选择器:用独立 Bool 控制展示 + 单独记目标分组角色。绝不用
  /// `isPresented: Binding(get: target != nil)` 那种派生绑定 —— 它会在 fileImporter
  /// 回调读取 target 之前就把 target 清空,导致选了 App 却加不进去。
  @State private var appImporterPresented = false
  @State private var importTargetRole: InputSourceGroupRole?
  @State private var sources = InputSourceCatalog.all()
  @State private var installedBrowsers = SupportedBrowserCatalog.installed()

  private var prefs: InputSourceSwitchPreferences { store.preferences.inputSourceSwitch }

  var body: some View {
    SettingsPage {
      PageHeader(
        page: .inputSourceSwitch,
        subtitle: "根据当前 App 和浏览器网站自动切换输入法。",
        isOn: bind(\.enabled)
      )
      .help("关闭后不再自动切换输入法。")

      VStack(alignment: .leading, spacing: 8) {
        MGSegmentedPicker(
          selection: $segment,
          options: Segment.allCases.map { MGSegmentedOption($0, $0.title) }
        )
        .controlSize(.large)
        if segment == .appRules {
          Text("把应用分到中文组 / 英文组,按组指定输入法 —— 改一次,整组生效。")
            .font(.mgMeta)
            .foregroundStyle(Color.mgText2)
            .padding(.leading, 4)
        }
      }

      switch segment {
      case .general: generalSegment
      case .appRules: appRulesSegment
      case .browserRules: browserRulesSegment
      }
    }
    // 输入法候选跟着系统走:进页刷新一次,系统「启用的输入法」变化(用户在系统
    // 设置里增删)时也实时刷新。@State 缓存只是避免每帧重查 TIS,不是写死列表。
    .onAppear {
      sources = InputSourceCatalog.all()
      installedBrowsers = SupportedBrowserCatalog.installed()
    }
    .onReceive(DistributedNotificationCenter.default().publisher(
      for: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)
    )) { _ in
      sources = InputSourceCatalog.all()
    }
    .sheet(item: $editingBrowserRule) { rule in
      BrowserRuleEditor(sources: sources, initial: rule) { saved in
        store.updatePreferences { p in
          if let idx = p.inputSourceSwitch.browserRules.firstIndex(where: { $0.id == saved.id }) {
            p.inputSourceSwitch.browserRules[idx] = saved
          } else {
            p.inputSourceSwitch.browserRules.append(saved)
          }
        }
      }
    }
  }

  // MARK: - 通用

  @ViewBuilder
  private var generalSegment: some View {
    SettingsSection("通用") {
      SettingsRow(title: "全局默认输入法", subtitle: "无任何规则命中的 App 激活时切到它。") {
        sourcePicker(bind(\.systemDefaultInputSourceID))
      }
      SettingsRow(title: "切回 App / 网站时", subtitle: "用默认,还是恢复上次在该上下文用过的输入法。") {
        enumPicker(\.restoreStrategy, cases: InputSourceRestoreStrategy.allCases) { $0.displayName }
      }
      SettingsRow(title: "浏览器地址栏默认输入法", subtitle: "地址栏聚焦时切到它(常用于切英文)。") {
        sourcePicker(bind(\.browserAddressDefaultInputSourceID))
      }
      SettingsRow(
        "强制英文标点",
        subtitle: "中文输入法打字时,, . ; ' [ ] 等标点直接输出英文字符;带 ⌘⌃⌥ 的快捷键不受影响。",
        isOn: bind(\.forceEnglishPunctuationEnabled)
      )
    }

    SettingsSection("兼容性") {
      SettingsRow(
        "修复输入法切换问题(CJKV)",
        subtitle: "中日韩越输入法切了图标变但实际没切时打开。",
        isOn: bind(\.cjkFixEnabled)
      )
      // 修复关着时 selector 根本不看修复方式,置灰免得误以为改了有用。
      SettingsRow(
        title: "CJKV 修复方式",
        subtitle: "模拟快捷键不抢焦点;切换焦点会短暂激活 Velto,但对 macOS 26/CJKV 更强。"
      ) {
        enumPicker(\.cjkFixStrategy, cases: InputSourceCJKFixStrategy.allCases) { $0.displayName }
      }
      .disabled(!prefs.cjkFixEnabled)
      if prefs.cjkFixEnabled,
         prefs.cjkFixStrategy == .previousInputSourceShortcut,
         InputSourceSwitchSelector.previousInputSourceShortcut() == nil {
        SettingsRow(title: "系统未配置「选择上一个输入法」快捷键", subtitle: "该策略依赖此系统快捷键,请到键盘设置开启。") {
          Button("打开键盘设置") { PermissionManager.openKeyboardSettings() }
            .buttonStyle(.bordered)
        }
      }
    }

    DebugSection(
      isOn: bind(\.debugLoggingEnabled),
      logURL: InputSourceSwitchDebugLog.fileURL,
      help: "排查时打开,只写 input-source-switch.log。"
    )
  }

  // MARK: - 应用规则(写死两组:中文组 / 英文组,上下排列)

  private var appRulesSegment: some View {
    VStack(alignment: .leading, spacing: 24) {
      groupSection(.chinese)
      groupSection(.english)
    }
    .fileImporter(
      isPresented: $appImporterPresented,
      allowedContentTypes: [.application],
      allowsMultipleSelection: true
    ) { result in
      let role = importTargetRole
      importTargetRole = nil
      if case .success(let urls) = result, let role {
        for url in urls { addAppToGroup(fromAppAt: url, role: role) }
      }
    }
    .onAppear { ensureFixedGroups() }
  }

  private func groupSection(_ role: InputSourceGroupRole) -> some View {
    let group = prefs.appGroups.first { $0.role == role }
    let members = group?.bundleIdentifiers ?? []
    return SettingsSection("\(role.displayName) · \(members.count) 个应用") {
      SettingsRow(title: "输入法") {
        sourcePicker(Binding(
          get: { group?.inputSourceID },
          set: { updateGroupSource(role: role, $0) }
        ))
      }
      if members.isEmpty { EmptyRow("还没有应用。") }
      ForEach(members, id: \.self) { bid in
        BundleAppRow(bundleID: bid, title: appDisplayName(forBundleID: bid)) {
          DeleteIconButton { removeAppFromGroup(bid, role: role) }
        }
      }
    } accessory: {
      Button("添加应用", systemImage: "plus") {
        importTargetRole = role
        appImporterPresented = true
      }
      .buttonStyle(.bordered)
    }
  }

  // MARK: - 浏览器规则

  @ViewBuilder
  private var browserRulesSegment: some View {
    SettingsSection("启用的浏览器") {
      if installedBrowsers.isEmpty { EmptyRow("没检测到受支持的浏览器。") }
      ForEach(installedBrowsers) { b in
        BundleAppRow(bundleID: b.bundleID, title: b.displayName) {
          SettingsSwitch(isOn: Binding(
            get: { prefs.enabledBrowserBundleIDs.contains(b.bundleID) },
            set: { v in store.updatePreferences { p in
              if v { p.inputSourceSwitch.enabledBrowserBundleIDs.insert(b.bundleID) }
              else { p.inputSourceSwitch.enabledBrowserBundleIDs.remove(b.bundleID) }
            } }
          ))
        }
      }
    }

    SettingsSection("URL 规则") {
      if prefs.browserRules.isEmpty { EmptyRow("还没有 URL 规则。") }
      ForEach(prefs.browserRules) { rule in
        SettingsRow(
          title: "\(rule.type.displayName): \(rule.value)",
          subtitle: rule.sample.isEmpty ? nil : rule.sample
        ) {
          sourcePicker(Binding(
            get: { rule.inputSourceID },
            set: { id in updateBrowserRule(rule.id) { $0.inputSourceID = id } }
          ), minWidth: 140)
          Button { editingBrowserRule = rule } label: { Image(systemName: "pencil") }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.mgText3)
            .help("编辑")
          DeleteIconButton { deleteBrowserRule(rule.id) }
          SettingsSwitch(isOn: Binding(
            get: { rule.isEnabled },
            set: { v in updateBrowserRule(rule.id) { $0.isEnabled = v } }
          ))
        }
      }
    } accessory: {
      Button("新增规则", systemImage: "plus") { editingBrowserRule = InputSourceBrowserRule() }
        .buttonStyle(.bordered)
    }
  }

  // MARK: - 控件 helper

  private func bind<V>(_ kp: WritableKeyPath<InputSourceSwitchPreferences, V>) -> Binding<V> {
    Binding(
      get: { store.preferences.inputSourceSwitch[keyPath: kp] },
      set: { v in store.updatePreferences { $0.inputSourceSwitch[keyPath: kp] = v } }
    )
  }

  /// 输入法下拉,「不指定」存 nil。
  private func sourcePicker(_ selection: Binding<String?>, minWidth: CGFloat = 160) -> some View {
    MGMenuPicker(
      selection: Binding(
        get: { selection.wrappedValue ?? "" },
        set: { selection.wrappedValue = $0.isEmpty ? nil : $0 }
      ),
      options: [MGMenuOption("", "不指定")] + sources.map { MGMenuOption($0.id, $0.localizedName) },
      minWidth: minWidth
    )
  }

  private func enumPicker<E: Hashable>(
    _ kp: WritableKeyPath<InputSourceSwitchPreferences, E>,
    cases: [E], name: (E) -> String
  ) -> some View {
    MGMenuPicker(selection: bind(kp), options: cases.map { MGMenuOption($0, name($0)) })
  }

  // MARK: - 固定分组操作

  /// 进入页时把分组规整成固定两组(英文组 / 中文组),仅在尚未规整时写回。
  private func ensureFixedGroups() {
    let p = store.preferences.inputSourceSwitch
    let alreadyFixed = p.appRules.isEmpty
      && p.appGroups.count == 2
      && p.appGroups.contains { $0.role == .english }
      && p.appGroups.contains { $0.role == .chinese }
      && !p.appGroups.contains { $0.role == nil }
    guard !alreadyFixed else { return }
    store.updatePreferences { $0.inputSourceSwitch.ensureFixedGroups() }
  }

  private func updateGroup(role: InputSourceGroupRole, _ mutate: (inout InputSourceAppGroup) -> Void) {
    store.updatePreferences { p in
      if let i = p.inputSourceSwitch.appGroups.firstIndex(where: { $0.role == role }) {
        mutate(&p.inputSourceSwitch.appGroups[i])
      }
    }
  }

  private func updateGroupSource(role: InputSourceGroupRole, _ src: String?) {
    updateGroup(role: role) { $0.inputSourceID = src }
  }

  private func removeAppFromGroup(_ bundleID: String, role: InputSourceGroupRole) {
    updateGroup(role: role) { $0.bundleIdentifiers.removeAll { $0 == bundleID } }
  }

  /// 加 App 到指定角色的分组。单一归属:先从两组都移除该 bundleId,再加入目标组,
  /// 避免一个 App 同时落在两组导致匹配歧义。
  private func addAppToGroup(fromAppAt url: URL, role: InputSourceGroupRole) {
    guard let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else { return }
    store.updatePreferences { p in
      for i in p.inputSourceSwitch.appGroups.indices {
        p.inputSourceSwitch.appGroups[i].bundleIdentifiers.removeAll { $0 == bid }
      }
      if let i = p.inputSourceSwitch.appGroups.firstIndex(where: { $0.role == role }) {
        p.inputSourceSwitch.appGroups[i].bundleIdentifiers.append(bid)
      }
    }
  }

  /// 由 bundleId 解析友好显示名(取不到就回退 bundleId)。
  private func appDisplayName(forBundleID bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
          let b = Bundle(url: url) else { return bundleID }
    return (b.infoDictionary?["CFBundleDisplayName"] as? String)
      ?? (b.infoDictionary?["CFBundleName"] as? String)
      ?? url.deletingPathExtension().lastPathComponent
  }

  private func updateBrowserRule(_ id: UUID, _ mutate: (inout InputSourceBrowserRule) -> Void) {
    store.updatePreferences { p in
      if let idx = p.inputSourceSwitch.browserRules.firstIndex(where: { $0.id == id }) {
        mutate(&p.inputSourceSwitch.browserRules[idx])
      }
    }
  }

  private func deleteBrowserRule(_ id: UUID) {
    store.updatePreferences { $0.inputSourceSwitch.browserRules.removeAll { $0.id == id } }
  }
}

/// 只存了 bundleId 的 App 行(分组成员、浏览器):图标按 bundleId 现查,查不到用通用 App 图标。
private struct BundleAppRow<Trailing: View>: View {
  let bundleID: String
  let title: String
  @ViewBuilder var trailing: () -> Trailing
  @State private var icon: NSImage?

  var body: some View {
    SettingsRow(title: title, subtitle: bundleID, icon: icon, trailing: trailing)
      .onAppear { if icon == nil { icon = loadIcon() } }
      .onChange(of: bundleID) { _, _ in icon = loadIcon() }
  }

  private func loadIcon() -> NSImage {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return NSWorkspace.shared.icon(for: .application)
    }
    return NSWorkspace.shared.icon(forFile: appURL.path)
  }
}
