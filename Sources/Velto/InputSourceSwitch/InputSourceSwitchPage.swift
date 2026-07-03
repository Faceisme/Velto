import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

struct InputSourceSwitchPage: View {
  private let store = GestureStore.shared

  private enum Segment: String, CaseIterable, Identifiable {
    case general, appRules, browserRules, troubleshooting
    var id: String { rawValue }
    var title: String {
      switch self {
      case .general: return "通用"
      case .appRules: return "应用规则"
      case .browserRules: return "浏览器规则"
      case .troubleshooting: return "故障排除"
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

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          PageHeader(
            tag: "Input Source",
            title: "输入法切换",
            subtitle: "根据当前 App 和浏览器网站自动切换输入法。"
          )
          MGSegmentedPicker(
            selection: $segment,
            options: Segment.allCases.map { MGSegmentedOption($0, $0.title) }
          )

          switch segment {
          case .general: generalGroup
          case .appRules: appRulesGroup
          case .browserRules: browserRulesGroup
          case .troubleshooting: troubleshootingGroup
          }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 28)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

  private var generalGroup: some View {
    GroupCard(radius: MGRadius.cardLg) {
      VStack(spacing: 0) {
        row(icon: "power", title: "启用输入法切换",
            desc: "关闭后不再自动切换输入法。", showDivider: false) {
          AnyView(toggle(\.enabled))
        }
        row(icon: "globe", title: "全局默认输入法",
            desc: "无任何规则命中的 App 激活时切到它。", showDivider: true) {
          AnyView(sourcePicker(\.systemDefaultInputSourceID))
        }
        row(icon: "arrow.uturn.backward", title: "切回 App / 网站时",
            desc: "用默认,还是恢复上次在该上下文用过的输入法。", showDivider: true) {
          AnyView(enumPicker(\.restoreStrategy, cases: InputSourceRestoreStrategy.allCases) { $0.displayName })
        }
        row(icon: "magnifyingglass", title: "浏览器地址栏默认输入法",
            desc: "地址栏聚焦时切到它(常用于切英文)。", showDivider: true) {
          AnyView(sourcePicker(\.browserAddressDefaultInputSourceID))
        }
        row(icon: "textformat.abc", title: "强制英文标点",
            desc: "中文输入法打字时标点直接输出英文;在「应用规则」里按应用勾选生效。", showDivider: true) {
          AnyView(toggle(\.forceEnglishPunctuationEnabled))
        }
        row(icon: "ladybug", title: "调试日志",
            desc: "排查时打开,只写 input-source-switch.log。", showDivider: true) {
          AnyView(toggle(\.debugLoggingEnabled))
        }
        row(icon: "folder", title: "打开日志文件夹",
            desc: "~/Library/Logs/Velto/", showDivider: true) {
          AnyView(
            Button("打开") { openLogsFolder() }
              .buttonStyle(MGSecondaryButtonStyle())
          )
        }
      }
    }
  }

  // MARK: - 应用规则（写死两组:英文组 / 中文组,并排两列)

  private var appRulesGroup: some View {
    VStack(alignment: .leading, spacing: 14) {
      sectionLabel("把应用分到中文组 / 英文组,按组指定输入法 —— 改一次,整组生效。「英文标点」开关:该应用里中文输入法打字时,标点直接输出英文字符。")
      HStack(alignment: .top, spacing: 16) {
        groupColumn(role: .chinese)
        groupColumn(role: .english)
      }
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

  /// 一列 = 一个固定分组(英文组 / 中文组)。
  private func groupColumn(role: InputSourceGroupRole) -> some View {
    let group = store.preferences.inputSourceSwitch.appGroups.first { $0.role == role }
    let members = group?.bundleIdentifiers ?? []
    return GroupCard(radius: MGRadius.cardLg) {
      VStack(spacing: 0) {
        // 组头:固定名 + 应用数 + 分组级输入法。
        HStack(alignment: .center, spacing: 12) {
          ActionIcon(systemName: role == .english ? "a.square" : "character.bubble")
          VStack(alignment: .leading, spacing: 2) {
            Text(role.displayName)
              .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.mgText1)
            Text("\(members.count) 个应用")
              .font(.system(size: 12)).foregroundStyle(Color.mgText2)
          }
          Spacer(minLength: 8)
          MGMenuPicker(
            selection: Binding(
              get: { group?.inputSourceID ?? "" },
              set: { updateGroupSource(role: role, $0.isEmpty ? nil : $0) }
            ),
            options: [MGMenuOption("", "不指定")] + sources.map { MGMenuOption($0.id, $0.localizedName) },
            minWidth: 120
          )
        }
        .padding(.horizontal, 16).padding(.vertical, 14)

        ForEach(members, id: \.self) { bid in
          memberRow(role: role, bundleID: bid)
        }
        if members.isEmpty {
          Rectangle().fill(Color.mgHair).frame(height: 0.5)
          Text("还没有应用,点下方「添加应用」。")
            .font(.system(size: 12)).foregroundStyle(Color.mgText3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }

        Rectangle().fill(Color.mgHair).frame(height: 0.5)
        HStack {
          Button {
            importTargetRole = role
            appImporterPresented = true
          } label: { Label("添加应用", systemImage: "plus") }
            .buttonStyle(MGPlainButtonStyle(foreground: .mgAccent))
          Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
      }
    }
    .frame(maxWidth: .infinity, alignment: .top)
  }

  /// 成员应用行:图标 + 名称 + bundleId + 英文标点迷你开关 + 移出分组。
  private func memberRow(role: InputSourceGroupRole, bundleID: String) -> some View {
    VStack(spacing: 0) {
      Rectangle().fill(Color.mgHair).frame(height: 0.5)
      HStack(alignment: .center, spacing: 12) {
        BundleAppIcon(bundleID: bundleID)
        VStack(alignment: .leading, spacing: 2) {
          Text(appDisplayName(forBundleID: bundleID))
            .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.mgText1)
            .lineLimit(1)
          Text(bundleID).font(.system(size: 11)).foregroundStyle(Color.mgText2).lineLimit(1)
        }
        Spacer(minLength: 8)
        // 强制英文标点(移植自 ISP):按应用一个迷你开关,开了即生效。
        HStack(spacing: 5) {
          Text("英文标点").font(.system(size: 11)).foregroundStyle(Color.mgText3)
          Toggle("", isOn: punctuationBinding(bundleID))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(.mgAccent)
        }
        .help("该应用里用中文输入法打字时,, . ; ' [ ] 等标点键直接输出英文字符;带 ⌘⌃⌥ 的快捷键不受影响。")
        Button { removeAppFromGroup(bundleID, role: role) } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(MGPlainButtonStyle(foreground: .mgText3))
      }
      .padding(.horizontal, 16).padding(.vertical, 10)
    }
  }

  private func punctuationBinding(_ bundleID: String) -> Binding<Bool> {
    Binding(
      get: { store.preferences.inputSourceSwitch.forceEnglishPunctuationBundleIDs.contains(bundleID) },
      set: { v in
        store.updatePreferences { p in
          if v {
            p.inputSourceSwitch.forceEnglishPunctuationBundleIDs.insert(bundleID)
          } else {
            p.inputSourceSwitch.forceEnglishPunctuationBundleIDs.remove(bundleID)
          }
        }
      }
    )
  }

  // MARK: - 浏览器规则

  private var browserRulesGroup: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 10) {
        sectionLabel("启用的浏览器")
        GroupCard(radius: MGRadius.cardLg) {
          VStack(spacing: 0) {
            if installedBrowsers.isEmpty { emptyHint("没检测到受支持的浏览器。") }
            ForEach(installedBrowsers) { b in
              row(
                title: b.displayName,
                desc: b.bundleID,
                showDivider: b.id != installedBrowsers.first?.id,
                icon: { AnyView(BrowserIcon(browser: b)) }
              ) {
                AnyView(Toggle("", isOn: Binding(
                  get: { store.preferences.inputSourceSwitch.enabledBrowserBundleIDs.contains(b.bundleID) },
                  set: { v in store.updatePreferences { p in
                    if v { p.inputSourceSwitch.enabledBrowserBundleIDs.insert(b.bundleID) }
                    else { p.inputSourceSwitch.enabledBrowserBundleIDs.remove(b.bundleID) }
                  } }
                )).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.mgAccent))
              }
            }
          }
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          sectionLabel("URL 规则")
          Spacer()
          Button {
            editingBrowserRule = InputSourceBrowserRule()
          } label: { Label("新增规则", systemImage: "plus") }
            .buttonStyle(MGSecondaryButtonStyle(foreground: .mgAccent))
        }
        GroupCard(radius: MGRadius.cardLg) {
          VStack(spacing: 0) {
            let rules = store.preferences.inputSourceSwitch.browserRules
            if rules.isEmpty { emptyHint("还没有 URL 规则。") }
            ForEach(rules) { rule in
              ruleRow(
                title: "\(rule.type.displayName): \(rule.value)", subtitle: rule.sample,
                isEnabled: rule.isEnabled, sourceID: rule.inputSourceID,
                showDivider: rule.id != rules.first?.id,
                onToggle: { v in updateBrowserRule(rule.id) { $0.isEnabled = v } },
                onPick: { id in updateBrowserRule(rule.id) { $0.inputSourceID = id } },
                onDelete: { deleteBrowserRule(rule.id) },
                onEdit: { editingBrowserRule = rule }
              )
            }
          }
        }
      }
    }
  }

  // MARK: - 故障排除

  private var troubleshootingGroup: some View {
    GroupCard(radius: MGRadius.cardLg) {
      VStack(spacing: 0) {
        row(icon: "wrench.and.screwdriver", title: "修复输入法切换问题(CJKV)",
            desc: "中日韩越输入法切了图标变但实际没切时打开。", showDivider: false) {
          AnyView(toggle(\.cjkFixEnabled))
        }
        row(icon: "slider.horizontal.3", title: "CJKV 修复方式",
            desc: "模拟快捷键不抢焦点;切换焦点会短暂激活 Velto,但对 macOS 26/CJKV 更强。",
            showDivider: true) {
          AnyView(enumPicker(\.cjkFixStrategy, cases: InputSourceCJKFixStrategy.allCases) { $0.displayName })
        }
        if store.preferences.inputSourceSwitch.cjkFixEnabled,
           store.preferences.inputSourceSwitch.cjkFixStrategy == .previousInputSourceShortcut,
           InputSourceSwitchSelector.previousInputSourceShortcut() == nil {
          row(icon: "exclamationmark.triangle", title: "系统未配置「选择上一个输入法」快捷键",
              desc: "该策略依赖此系统快捷键,请到键盘设置开启。", showDivider: true) {
            AnyView(
              Button("打开键盘设置") { PermissionManager.openKeyboardSettings() }
                .buttonStyle(MGSecondaryButtonStyle(foreground: .mgAccent))
            )
          }
        }
      }
    }
  }

  // MARK: - 行/控件 helper

  private func row(
    icon: String,
    title: String,
    desc: String?,
    showDivider: Bool,
    @ViewBuilder control: () -> AnyView
  ) -> some View {
    row(title: title, desc: desc, showDivider: showDivider, icon: { AnyView(ActionIcon(systemName: icon)) }, control: control)
  }

  private func row(
    title: String,
    desc: String?,
    showDivider: Bool,
    @ViewBuilder icon: () -> AnyView,
                   @ViewBuilder control: () -> AnyView) -> some View {
    VStack(spacing: 0) {
      if showDivider {
        Rectangle().fill(Color.mgHair).frame(height: 0.5).padding(.leading, 78)
      }
      HStack(alignment: .center, spacing: 16) {
        icon()
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.mgText1)
          if let desc { Text(desc).font(.system(size: 12)).foregroundStyle(Color.mgText2) }
        }
        Spacer(minLength: 12)
        control()
      }
      .padding(.horizontal, 20).padding(.vertical, 16)
    }
  }

  private func ruleRow(
    title: String, subtitle: String, isEnabled: Bool, sourceID: String?,
    showDivider: Bool,
    onToggle: @escaping (Bool) -> Void, onPick: @escaping (String?) -> Void,
    onDelete: @escaping () -> Void, onEdit: (() -> Void)? = nil
  ) -> some View {
    row(icon: "list.bullet", title: title, desc: subtitle.isEmpty ? nil : subtitle, showDivider: showDivider) {
      AnyView(HStack(spacing: 10) {
        MGMenuPicker(
          selection: Binding(get: { sourceID ?? "" }, set: { onPick($0.isEmpty ? nil : $0) }),
          options: [MGMenuOption("", "不指定")] + sources.map { MGMenuOption($0.id, $0.localizedName) },
          minWidth: 140
        )
        Toggle("", isOn: Binding(get: { isEnabled }, set: { onToggle($0) }))
          .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.mgAccent)
        if let onEdit {
          Button { onEdit() } label: { Image(systemName: "pencil") }
            .buttonStyle(MGPlainButtonStyle(foreground: .mgText3))
        }
        Button { onDelete() } label: { Image(systemName: "trash") }
          .buttonStyle(MGPlainButtonStyle(foreground: .mgDanger))
      })
    }
  }

  private func ruleRow(
    title: String, subtitle: String, icon: @escaping () -> AnyView,
    isEnabled: Bool, sourceID: String?,
    showDivider: Bool,
    onToggle: @escaping (Bool) -> Void, onPick: @escaping (String?) -> Void,
    onDelete: @escaping () -> Void, onEdit: (() -> Void)? = nil
  ) -> some View {
    row(title: title, desc: subtitle.isEmpty ? nil : subtitle, showDivider: showDivider, icon: icon) {
      AnyView(HStack(spacing: 10) {
        MGMenuPicker(
          selection: Binding(get: { sourceID ?? "" }, set: { onPick($0.isEmpty ? nil : $0) }),
          options: [MGMenuOption("", "不指定")] + sources.map { MGMenuOption($0.id, $0.localizedName) },
          minWidth: 140
        )
        Toggle("", isOn: Binding(get: { isEnabled }, set: { onToggle($0) }))
          .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.mgAccent)
        if let onEdit {
          Button { onEdit() } label: { Image(systemName: "pencil") }
            .buttonStyle(MGPlainButtonStyle(foreground: .mgText3))
        }
        Button { onDelete() } label: { Image(systemName: "trash") }
          .buttonStyle(MGPlainButtonStyle(foreground: .mgDanger))
      })
    }
  }

  private func sectionLabel(_ t: String) -> some View {
    Text(t).font(.mgSubLabel).foregroundStyle(Color.mgText3).padding(.leading, 4)
  }

  private func emptyHint(_ t: String) -> some View {
    Text(t).font(.system(size: 13)).foregroundStyle(Color.mgText3)
      .frame(maxWidth: .infinity, alignment: .leading).padding(20)
  }

  private func toggle(_ kp: WritableKeyPath<InputSourceSwitchPreferences, Bool>) -> some View {
    Toggle("", isOn: Binding(
      get: { store.preferences.inputSourceSwitch[keyPath: kp] },
      set: { v in store.updatePreferences { $0.inputSourceSwitch[keyPath: kp] = v } }
    )).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.mgAccent)
  }

  private func sourcePicker(_ kp: WritableKeyPath<InputSourceSwitchPreferences, String?>) -> some View {
    MGMenuPicker(
      selection: Binding(
        get: { store.preferences.inputSourceSwitch[keyPath: kp] ?? "" },
        set: { v in store.updatePreferences { $0.inputSourceSwitch[keyPath: kp] = v.isEmpty ? nil : v } }
      ),
      options: [MGMenuOption("", "不指定")] + sources.map { MGMenuOption($0.id, $0.localizedName) },
      minWidth: 160
    )
  }

  private func enumPicker<E: Hashable>(
    _ kp: WritableKeyPath<InputSourceSwitchPreferences, E>,
    cases: [E], name: @escaping (E) -> String
  ) -> some View {
    MGMenuPicker(
      selection: Binding(
        get: { store.preferences.inputSourceSwitch[keyPath: kp] },
        set: { v in store.updatePreferences { $0.inputSourceSwitch[keyPath: kp] = v } }
      ),
      options: cases.map { MGMenuOption($0, name($0)) },
      minWidth: 160
    )
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

  private func openLogsFolder() {
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Logs/Velto", isDirectory: true)
    if let url { NSWorkspace.shared.open(url) }
  }
}

/// 分组内成员图标 —— 仅靠 bundleId 解析(分组只存 bundleId,不存路径)。
private struct BundleAppIcon: View {
  let bundleID: String
  @State private var icon: NSImage?

  var body: some View {
    Group {
      if let icon {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Image(nsImage: icon)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 30, height: 30)
          .padding(5)
          .frame(width: 40, height: 40)
          .background(shape.fill(Color.mgGlassControl.opacity(0.35)))
          .veltoNativeGlass(in: shape)
      } else {
        ActionIcon(systemName: "app")
      }
    }
    .onAppear { if icon == nil { icon = loadIcon() } }
    .onChange(of: bundleID) { _, _ in icon = loadIcon() }
  }

  private func loadIcon() -> NSImage? {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return nil
    }
    return NSWorkspace.shared.icon(forFile: appURL.path)
  }
}


private struct BrowserIcon: View {
  let browser: SupportedBrowser
  @State private var icon: NSImage?

  var body: some View {
    Group {
      if let icon {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Image(nsImage: icon)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 30, height: 30)
          .padding(5)
          .frame(width: 40, height: 40)
          .background(shape.fill(Color.mgGlassControl.opacity(0.35)))
          .veltoNativeGlass(in: shape)
      } else {
        ActionIcon(systemName: "globe")
      }
    }
    .onAppear(perform: loadIconIfNeeded)
    .onChange(of: browser.bundleID) { _, _ in icon = loadIcon() }
  }

  private func loadIconIfNeeded() {
    guard icon == nil else { return }
    icon = loadIcon()
  }

  private func loadIcon() -> NSImage? {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
      return nil
    }
    return NSWorkspace.shared.icon(forFile: appURL.path)
  }
}
