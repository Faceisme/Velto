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
    @State private var notInstalledSupportedApps: [BetterFinderApp] = []
    @State private var statusMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    tag: "Better Finder",
                    title: "增强Finder",
                    subtitle: "在 Finder 工具栏和右键菜单中打开终端、编辑器或拷贝路径。"
                )

                integrationSection
                debugSection
                defaultAppsSection
                customMenuSection
                shortcutSection
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: refreshCatalogs)
        .onReceive(NotificationCenter.default.publisher(for: BetterFinderPreferencesStore.didChangeNotification)) { _ in
            preferences = store.preferences
        }
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MGSectionLabel(text: "调试")
            GroupCard {
                VStack(spacing: 0) {
                    GroupRow(
                        label: "调试日志",
                        sub: "排查 Finder 工具栏和右键菜单时打开,日志写入 betterfinder-debug.log",
                        showDivider: false
                    ) {
                        Toggle("", isOn: Binding(
                            get: { preferences.debugLoggingEnabled },
                            set: { value in updatePreferences { $0.debugLoggingEnabled = value } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.mgAccent)
                    }

                    GroupRow(
                        label: "日志文件",
                        sub: BetterFinderDebugLog.fileURL.path,
                        showDivider: true
                    ) {
                        HStack(spacing: 8) {
                            Button("打开文件夹", action: openDebugLogFolder)
                                .buttonStyle(MGSecondaryButtonStyle())
                            Button("清空", action: clearDebugLog)
                                .buttonStyle(MGSecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private var integrationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MGSectionLabel(text: "集成")
            GroupCard {
                VStack(spacing: 0) {
                    GroupRow(
                        label: "启用增强Finder",
                        sub: "关闭后,Finder 扩展菜单和全局快捷键都会停止执行",
                        showDivider: false
                    ) {
                        Toggle("", isOn: Binding(
                            get: { preferences.isEnabled },
                            set: { value in updatePreferences { $0.isEnabled = value } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.mgAccent)
                    }

                    GroupRow(
                        label: "Finder 扩展",
                        sub: "首次使用或重装后,需要注册并启用 Finder Sync 扩展",
                        showDivider: true
                    ) {
                        HStack(spacing: 8) {
                            Button("注册并启用", action: registerFinderExtension)
                                .buttonStyle(MGSecondaryButtonStyle(foreground: .mgAccent))
                            Button("打开系统扩展设置", action: openExtensionSettings)
                                .buttonStyle(MGSecondaryButtonStyle())
                            Button("重启 Finder", action: restartFinder)
                                .buttonStyle(MGSecondaryButtonStyle())
                        }
                    }
                }
            }
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.mgMeta)
                    .foregroundStyle(Color.mgText2)
                    .padding(.top, 8)
                    .padding(.leading, 4)
            }
        }
    }

    private var defaultAppsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MGSectionLabel(text: "默认应用")
            GroupCard {
                VStack(spacing: 0) {
                    GroupRow(
                        label: "默认终端",
                        sub: "Finder 工具栏默认菜单中的第一项"
                    ) {
                        appPicker(
                            selection: Binding(
                                get: { preferences.defaultTerminal },
                                set: { value in updatePreferences { $0.defaultTerminal = value } }
                            ),
                            options: installedTerminals.isEmpty
                                ? BetterFinderApplicationCatalog.allSupportedApps(type: .terminal)
                                : installedTerminals
                        )
                    }

                    GroupRow(
                        label: "默认编辑器",
                        sub: "Finder 工具栏默认菜单中的第二项",
                        showDivider: true
                    ) {
                        appPicker(
                            selection: Binding(
                                get: { preferences.defaultEditor },
                                set: { value in updatePreferences { $0.defaultEditor = value } }
                            ),
                            options: installedEditors.isEmpty
                                ? BetterFinderApplicationCatalog.allSupportedApps(type: .editor)
                                : installedEditors
                        )
                    }
                }
            }
        }
    }

    private var customMenuSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MGSectionLabel(text: "自定义菜单")
            GroupCard(padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)) {
                VStack(alignment: .leading, spacing: 16) {
                    supportedAppsSummary
                    customAppList

                    HStack(spacing: 8) {
                        addAppMenu
                        Button {
                            if !preferences.customMenuApps.isEmpty {
                                updatePreferences { $0.customMenuApps.removeLast() }
                            }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(MGSecondaryButtonStyle(height: 30, hPad: 10))
                        .disabled(preferences.customMenuApps.isEmpty)
                        .opacity(preferences.customMenuApps.isEmpty ? 0.45 : 1)
                    }

                    VStack(spacing: 0) {
                        GroupRow(label: "应用到 Finder 工具栏菜单") {
                            Toggle("", isOn: Binding(
                                get: { preferences.appliesCustomMenuToToolbar },
                                set: { value in updatePreferences { $0.appliesCustomMenuToToolbar = value } }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(.mgAccent)
                        }
                        GroupRow(label: "应用到 Finder 右键菜单", showDivider: true) {
                            Toggle("", isOn: Binding(
                                get: { preferences.appliesCustomMenuToContextMenu },
                                set: { value in updatePreferences { $0.appliesCustomMenuToContextMenu = value } }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(.mgAccent)
                        }
                        GroupRow(label: "隐藏 Finder 右键菜单项", showDivider: true) {
                            Toggle("", isOn: Binding(
                                get: { preferences.hidesContextMenuItems },
                                set: { value in updatePreferences { $0.hidesContextMenuItems = value } }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(.mgAccent)
                        }
                        GroupRow(label: "图标类型", showDivider: true) {
                            MGSegmentedPicker(
                                selection: Binding(
                                    get: { preferences.iconStyle },
                                    set: { value in updatePreferences { $0.iconStyle = value } }
                                ),
                                options: BetterFinderIconStyle.allCases.map {
                                    MGSegmentedOption($0, $0.label)
                                }
                            )
                        }
                        GroupRow(label: "路径转义", showDivider: true) {
                            MGSegmentedPicker(
                                selection: Binding(
                                    get: { preferences.escapesCopiedPaths },
                                    set: { value in updatePreferences { $0.escapesCopiedPaths = value } }
                                ),
                                options: [
                                    MGSegmentedOption(false, "否"),
                                    MGSegmentedOption(true, "是")
                                ]
                            )
                        }
                    }
                    .veltoGlassPanel(radius: MGRadius.card)
                }
            }
        }
    }

    private var supportedAppsSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已安装的受支持应用")
                .font(.mgLabelStrong)
                .foregroundStyle(Color.mgText1)
            Text(installedSupportedApps.map(\.name).sortedIgnoreCase().joined(separator: ", "))
                .font(.mgBody)
                .foregroundStyle(Color.mgText1)
                .fixedSize(horizontal: false, vertical: true)

            Text("未安装的应用")
                .font(.mgLabelStrong)
                .foregroundStyle(Color.mgText1)
                .padding(.top, 4)
            Text(notInstalledSupportedApps.map(\.name).sortedIgnoreCase().joined(separator: ", "))
                .font(.mgBody)
                .foregroundStyle(Color.mgText2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var customAppList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("菜单选项")
                .font(.mgLabelStrong)
                .foregroundStyle(Color.mgText1)

            VStack(spacing: 0) {
                if preferences.customMenuApps.isEmpty {
                    Text("未添加自定义应用")
                        .font(.mgBody)
                        .foregroundStyle(Color.mgText3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                } else {
                    ForEach(preferences.customMenuApps) { app in
                        HStack(spacing: 10) {
                            Image(systemName: app.type == .terminal ? "terminal" : "square.and.pencil")
                                .foregroundStyle(Color.mgText2)
                                .frame(width: 18)
                            Text(app.name)
                                .font(.mgBody)
                                .foregroundStyle(Color.mgText1)
                            Spacer()
                            Button("移除") {
                                removeCustomApp(app)
                            }
                            .buttonStyle(MGPlainButtonStyle(foreground: .mgText3))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        if app.id != preferences.customMenuApps.last?.id {
                            Rectangle()
                                .fill(Color.mgHair)
                                .frame(height: 0.5)
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
                    .fill(Color.mgCardAlt)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
                    .strokeBorder(Color.mgHairStrong, lineWidth: 1)
            )
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
        .buttonStyle(MGSecondaryButtonStyle(height: 30))
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MGSectionLabel(text: "快捷键")
            GroupCard {
                VStack(spacing: 0) {
                    ShortcutRow(
                        icon: "terminal",
                        title: "打开默认终端",
                        shortcut: shortcutBinding(\.openTerminalShortcut)
                    )
                    ShortcutRow(
                        icon: "square.and.pencil",
                        title: "打开默认编辑器",
                        shortcut: shortcutBinding(\.openEditorShortcut),
                        showDivider: true
                    )
                    ShortcutRow(
                        icon: "doc.on.clipboard",
                        title: "拷贝路径到剪贴板",
                        shortcut: shortcutBinding(\.copyPathShortcut),
                        showDivider: true
                    )
                }
            }
        }
    }

    private func appPicker(
        selection: Binding<BetterFinderApp>,
        options: [BetterFinderApp]
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options) { app in
                Text(app.name).tag(app)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 220, alignment: .trailing)
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
        let installedSet = Set(installedSupportedApps)
        notInstalledSupportedApps = BetterFinderApplicationCatalog.allSupportedApps()
            .filter { !installedSet.contains($0) }
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

    private func openDebugLogFolder() {
        let folderURL = BetterFinderDebugLog.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: BetterFinderDebugLog.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([BetterFinderDebugLog.fileURL])
        } else {
            NSWorkspace.shared.open(folderURL)
        }
    }

    private func clearDebugLog() {
        BetterFinderDebugLog.clear()
        statusMessage = "已清空增强Finder调试日志。"
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

private struct ShortcutRow: View {
    let icon: String
    let title: String
    @Binding var shortcut: Shortcut?
    var showDivider: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if showDivider {
                Rectangle()
                    .fill(Color.mgHair)
                    .frame(height: 0.5)
                    .padding(.leading, 78)
            }

            HStack(spacing: 16) {
                ActionIcon(systemName: icon)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.mgText1)
                Spacer(minLength: 12)
                KeyCapSlot(minWidth: 120) {
                    ShortcutRecorderField(shortcut: $shortcut, placeholder: "点击录制")
                }
                Button("清除") { shortcut = nil }
                    .buttonStyle(MGPlainButtonStyle(foreground: .mgText3))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
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

private extension Array where Element == String {
    func sortedIgnoreCase() -> [String] {
        sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
