import AppKit
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
  @State private var showAppPicker = false

  /// 输入法候选(进页面取一次)。
  private var sources: [InputSourceInfo] { InputSourceCatalog.all() }

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

  // MARK: - 应用规则

  private var appRulesGroup: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Spacer()
        Button {
          showAppPicker = true
        } label: { Label("从应用选择", systemImage: "plus") }
          .buttonStyle(MGSecondaryButtonStyle(foreground: .mgAccent))
      }
      GroupCard(radius: MGRadius.cardLg) {
        VStack(spacing: 0) {
          let rules = store.preferences.inputSourceSwitch.appRules
          if rules.isEmpty {
            emptyHint("还没有应用规则。点右上角「从应用选择」添加。")
          }
          ForEach(rules) { rule in
            ruleRow(
              title: rule.displayName, subtitle: rule.bundleIdentifier,
              icon: { AnyView(AppRuleIcon(rule: rule)) },
              isEnabled: rule.isEnabled,
              sourceID: rule.inputSourceID,
              showDivider: rule.id != rules.first?.id,
              onToggle: { v in updateAppRule(rule.id) { $0.isEnabled = v } },
              onPick: { id in updateAppRule(rule.id) { $0.inputSourceID = id } },
              onDelete: { deleteAppRule(rule.id) }
            )
          }
        }
      }
    }
    .fileImporter(isPresented: $showAppPicker, allowedContentTypes: [.application]) { result in
      if case .success(let url) = result { addAppRule(fromAppAt: url) }
    }
  }

  // MARK: - 浏览器规则

  private var browserRulesGroup: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 10) {
        sectionLabel("启用的浏览器")
        GroupCard(radius: MGRadius.cardLg) {
          VStack(spacing: 0) {
            let installed = SupportedBrowserCatalog.installed()
            if installed.isEmpty { emptyHint("没检测到受支持的浏览器。") }
            ForEach(installed) { b in
              row(
                title: b.displayName,
                desc: b.bundleID,
                showDivider: b.id != installed.first?.id,
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

  // MARK: - 规则增删改

  private func addAppRule(fromAppAt url: URL) {
    guard let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else { return }
    let name = (bundle.infoDictionary?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
    store.updatePreferences { p in
      guard !p.inputSourceSwitch.appRules.contains(where: { $0.bundleIdentifier == bid }) else { return }
      p.inputSourceSwitch.appRules.append(InputSourceAppRule(
        bundleIdentifier: bid, displayName: name, bundlePath: url.path
      ))
    }
  }

  private func updateAppRule(_ id: UUID, _ mutate: (inout InputSourceAppRule) -> Void) {
    store.updatePreferences { p in
      if let idx = p.inputSourceSwitch.appRules.firstIndex(where: { $0.id == id }) {
        mutate(&p.inputSourceSwitch.appRules[idx])
      }
    }
  }

  private func deleteAppRule(_ id: UUID) {
    store.updatePreferences { $0.inputSourceSwitch.appRules.removeAll { $0.id == id } }
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

private struct AppRuleIcon: View {
  let rule: InputSourceAppRule

  var body: some View {
    if let icon = appIcon {
      let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
      Image(nsImage: icon)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 30, height: 30)
        .padding(5)
        .frame(width: 40, height: 40)
        .background(shape.fill(Color.mgGlassControl))
        .veltoNativeGlass(in: shape)
        .overlay {
          shape.strokeBorder(Color.mgHair, lineWidth: 0.5)
        }
    } else {
      ActionIcon(systemName: "app")
    }
  }

  private var appIcon: NSImage? {
    if let bundlePath = rule.bundlePath,
       FileManager.default.fileExists(atPath: bundlePath) {
      return NSWorkspace.shared.icon(forFile: bundlePath)
    }
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleIdentifier) {
      return NSWorkspace.shared.icon(forFile: appURL.path)
    }
    return nil
  }
}

private struct BrowserIcon: View {
  let browser: SupportedBrowser

  var body: some View {
    if let icon = browserIcon {
      let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
      Image(nsImage: icon)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 30, height: 30)
        .padding(5)
        .frame(width: 40, height: 40)
        .background(shape.fill(Color.mgGlassControl))
        .veltoNativeGlass(in: shape)
        .overlay {
          shape.strokeBorder(Color.mgHair, lineWidth: 0.5)
        }
    } else {
      ActionIcon(systemName: "globe")
    }
  }

  private var browserIcon: NSImage? {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
      return nil
    }
    return NSWorkspace.shared.icon(forFile: appURL.path)
  }
}
