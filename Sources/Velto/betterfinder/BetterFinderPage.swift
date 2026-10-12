import AppKit
import SwiftUI
import UniformTypeIdentifiers
import betterfinder

struct BetterFinderPage: View {
    private let store = BetterFinderPreferencesStore.shared

    @State private var preferences = BetterFinderPreferencesStore.shared.preferences
    @State private var installedTerminals: [BetterFinderApp] = []
    @State private var installedEditors: [BetterFinderApp] = []
    @State private var installedSupportedApps: [BetterFinderApp] = []
    @State private var statusMessage = ""

    var body: some View {
        SettingsPage {
            PageHeader(
                page: .betterFinder,
                subtitle: "在 Finder 工具栏和右键菜单中打开终端、编辑器或拷贝路径。",
                isOn: bind(\.isEnabled)
            )
            .help("关闭后,Finder 扩展菜单和全局快捷键都会停止执行。")

            SettingsSection("集成") {
                SettingsRow(
                    title: "Finder 扩展",
                    subtitle: statusMessage.isEmpty ? "首次使用或重装后,需要注册并启用 Finder Sync 扩展。" : statusMessage
                ) {
                    Button("注册并启用", action: registerFinderExtension)
                        .buttonStyle(.borderedProminent)
                    Menu {
                        Button("打开系统扩展设置", action: openExtensionSettings)
                        Button("重启 Finder", action: restartFinder)
                    } label: {
                        // 裸 Image 只有省略号字形那么高,按钮会比旁边矮一截;包进 Text 撑到正文行高
                        Text(Image(systemName: "ellipsis"))
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .help("更多")
                    .accessibilityLabel("更多")
                }
            }

            SettingsSection("默认应用") {
                SettingsRow(title: "默认终端", subtitle: "Finder 工具栏默认菜单中的第一项") {
                    appPicker(
                        bind(\.defaultTerminal),
                        installedTerminals.isEmpty
                            ? BetterFinderApplicationCatalog.allSupportedApps(type: .terminal)
                            : installedTerminals
                    )
                }
                SettingsRow(title: "默认编辑器", subtitle: "Finder 工具栏默认菜单中的第二项") {
                    appPicker(
                        bind(\.defaultEditor),
                        installedEditors.isEmpty
                            ? BetterFinderApplicationCatalog.allSupportedApps(type: .editor)
                            : installedEditors
                    )
                }
            }

            SettingsSection("自定义菜单") {
                if preferences.customMenuApps.isEmpty {
                    EmptyRow("未添加自定义应用。")
                }
                ForEach(preferences.customMenuApps) { app in
                    SettingsRow(title: app.name, subtitle: app.type.label, icon: appIcon(app)) {
                        DeleteIconButton { removeCustomApp(app) }
                    }
                }
            } accessory: {
                addAppMenu
            }

            SettingsSection("菜单行为") {
                SettingsRow("应用到 Finder 工具栏菜单", isOn: bind(\.appliesCustomMenuToToolbar))
                SettingsRow("应用到 Finder 右键菜单", isOn: bind(\.appliesCustomMenuToContextMenu))
                SettingsRow("隐藏 Finder 右键菜单项", isOn: bind(\.hidesContextMenuItems))
                SettingsRow(title: "图标类型") {
                    MGMenuPicker(
                        selection: bind(\.iconStyle),
                        options: BetterFinderIconStyle.allCases.map { MGMenuOption($0, $0.label) }
                    )
                }
                SettingsRow("拷贝路径时转义", isOn: bind(\.escapesCopiedPaths))
            }

            SettingsSection("快捷键") {
                SettingsRow(title: "打开默认终端") {
                    ShortcutField(shortcut: shortcutBinding(\.openTerminalShortcut))
                }
                SettingsRow(title: "打开默认编辑器") {
                    ShortcutField(shortcut: shortcutBinding(\.openEditorShortcut))
                }
                SettingsRow(title: "拷贝路径到剪贴板") {
                    ShortcutField(shortcut: shortcutBinding(\.copyPathShortcut))
                }
            }

            DebugSection(
                isOn: bind(\.debugLoggingEnabled),
                logURL: BetterFinderDebugLog.fileURL,
                help: "排查 Finder 工具栏和右键菜单时打开,日志写入 betterfinder-debug.log。",
                clear: { BetterFinderDebugLog.clear() }
            )
        }
        .onAppear(perform: refreshCatalogs)
        .onReceive(NotificationCenter.default.publisher(for: BetterFinderPreferencesStore.didChangeNotification)) { _ in
            preferences = store.preferences
        }
    }

    private var addAppMenu: some View {
        Menu {
            Section("已安装的受支持应用") {
                ForEach(installedSupportedApps) { app in
                    Button(app.name) { addCustomApp(app) }
                }
            }
            Section("全部受支持应用") {
                ForEach(BetterFinderApplicationCatalog.allSupportedApps()) { app in
                    Button(app.name) { addCustomApp(app) }
                }
            }
            Divider()
            Button("从 Finder 选择应用…", action: chooseApplicationFromFinder)
            Button("手动输入应用名称…", action: promptManualAppName)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                Text("添加")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
    }

    private func appPicker(_ selection: Binding<BetterFinderApp>, _ options: [BetterFinderApp]) -> some View {
        MGMenuPicker(selection: selection, options: options.map { MGMenuOption($0, $0.name) }, minWidth: 220)
    }

    /// 只填了名字的应用(手动输入、没装)找不到 .app,用通用 App 图标。
    private func appIcon(_ app: BetterFinderApp) -> NSImage {
        guard let url = BetterFinderApplicationCatalog.bundleURL(for: app) else {
            return NSWorkspace.shared.icon(for: .application)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func bind<V>(_ keyPath: WritableKeyPath<BetterFinderPreferences, V>) -> Binding<V> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { value in updatePreferences { $0[keyPath: keyPath] = value } }
        )
    }

    private func shortcutBinding(
        _ keyPath: WritableKeyPath<BetterFinderPreferences, BetterFinderShortcut?>
    ) -> Binding<Shortcut?> {
        Binding(
            get: {
                preferences[keyPath: keyPath]?.veltoShortcut
            },
            set: { value in
                updatePreferences {
                    $0[keyPath: keyPath] = value.map(BetterFinderShortcut.init)
                }
            }
        )
    }

    private func updatePreferences(_ update: (inout BetterFinderPreferences) -> Void) {
        store.update(update)
        preferences = store.preferences
    }

    private func refreshCatalogs() {
        let installedNames = BetterFinderApplicationCatalog.installedApplicationNames()
        installedTerminals = BetterFinderSupportedApp.terminals
            .filter { installedNames.contains($0.name) }
            .map(\.app)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        installedEditors = BetterFinderSupportedApp.editors
            .filter { installedNames.contains($0.name) }
            .map(\.app)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        installedSupportedApps = (installedTerminals + installedEditors)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addCustomApp(_ app: BetterFinderApp) {
        updatePreferences { preferences in
            if !preferences.customMenuApps.contains(app) {
                preferences.customMenuApps.append(app)
            }
        }
    }

    private func removeCustomApp(_ app: BetterFinderApp) {
        updatePreferences {
            $0.customMenuApps.removeAll { $0 == app }
        }
    }

    private func chooseApplicationFromFinder() {
        let panel = NSOpenPanel()
        panel.title = "选择应用"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let app = BetterFinderApp(
            name: BetterFinderApplicationCatalog.displayName(forApplicationAt: url),
            type: .editor,
            path: url.path,
            bundleId: Bundle(url: url)?.bundleIdentifier
        )
        addCustomApp(app)
    }

    private func promptManualAppName() {
        let alert = NSAlert()
        alert.messageText = "手动输入应用名称"
        alert.informativeText = "名称会传给系统 open -a 命令。"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "例如 Visual Studio Code"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        picker.addItems(withTitles: BetterFinderAppType.allCases.map(\.label))
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(picker)
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let type = picker.indexOfSelectedItem == 0 ? BetterFinderAppType.terminal : .editor
        addCustomApp(BetterFinderApp(name: name, type: type))
    }

    private func registerFinderExtension() {
        guard let appexURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent("BetterFinderExtension.appex"),
              FileManager.default.fileExists(atPath: appexURL.path) else {
            statusMessage = "未找到 BetterFinderExtension.appex,请先重新打包。"
            return
        }

        let addOK = runCommand("/usr/bin/pluginkit", arguments: ["-a", appexURL.path])
        let enableOK = runCommand(
            "/usr/bin/pluginkit",
            arguments: ["-e", "use", "-i", BetterFinderConstants.finderExtensionBundleIdentifier]
        )
        statusMessage = addOK && enableOK
            ? "Finder 扩展已注册并启用。若菜单未出现,请重启 Finder。"
            : "Finder 扩展注册失败,可在终端查看 pluginkit 输出。"
    }

    private func openExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }

    private func restartFinder() {
        _ = runCommand("/usr/bin/killall", arguments: ["Finder"])
        statusMessage = "已请求重启 Finder。"
    }

    private func runCommand(_ executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

private extension BetterFinderShortcut {
    init(_ shortcut: Shortcut) {
        self.init(
            keyCode: shortcut.keyCode,
            modifierFlags: shortcut.modifierFlags,
            displayName: shortcut.displayName
        )
    }

    var veltoShortcut: Shortcut {
        Shortcut(
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            displayName: displayName
        )
    }
}
