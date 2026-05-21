import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettingsPage: View {
    private let store = GestureStore.shared
    @State private var showingImportConfirm = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var statusMessage = ""
    @State private var pendingImportURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    Text("GENERAL")
                        .font(.mgLabelTiny)
                        .tracking(0.5)
                        .foregroundStyle(.tertiary)
                    Text("通用设置")
                        .font(.mgTitleL)
                    Text("调整应用行为、识别参数和数据备份。")
                        .font(.mgBody)
                        .foregroundStyle(.secondary)
                }

                // Section: behavior
                section(title: "行为") {
                    settingsRow("启用手势监听") {
                        Toggle("", isOn: Binding(
                            get: { store.preferences.gesturesEnabled },
                            set: { v in store.updatePreferences { $0.gesturesEnabled = v } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    settingsRow("开机自动启动") {
                        Toggle("", isOn: Binding(
                            get: { LoginItemManager.isEnabled },
                            set: { enabled in
                                do {
                                    try LoginItemManager.setEnabled(enabled)
                                    statusMessage = "已更新开机启动设置。"
                                } catch {
                                    statusMessage = "无法更新开机启动：\(error.localizedDescription)"
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    settingsRow("显示菜单栏图标") {
                        Toggle("", isOn: Binding(
                            get: { store.preferences.showMenuBarIcon },
                            set: { v in store.updatePreferences { $0.showMenuBarIcon = v } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    settingsRow("绘制时显示轨迹") {
                        Toggle("", isOn: Binding(
                            get: { store.preferences.showTrail },
                            set: { v in store.updatePreferences { $0.showTrail = v } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }

                // Section: recognition
                section(title: "识别参数") {
                    settingsRow("手势超时时长") {
                        HStack(spacing: 4) {
                            TextField("", value: Binding(
                                get: { store.preferences.gestureTimeoutSeconds },
                                set: { v in store.updatePreferences { $0.gestureTimeoutSeconds = min(max(v, 0.5), 10) } }
                            ), format: .number)
                            .frame(width: 52)
                            .multilineTextAlignment(.trailing)
                            Stepper("", value: Binding(
                                get: { store.preferences.gestureTimeoutSeconds },
                                set: { v in store.updatePreferences { $0.gestureTimeoutSeconds = min(max(v, 0.5), 10) } }
                            ), in: 0.5...10, step: 0.5)
                            .labelsHidden()
                            Text("秒").foregroundStyle(.secondary)
                        }
                    }
                    settingsRow("手势作用目标") {
                        Picker("", selection: Binding(
                            get: { store.preferences.gestureTargetPolicy },
                            set: { v in store.updatePreferences { $0.gestureTargetPolicy = v } }
                        )) {
                            Text("鼠标指针下方").tag(GestureTargetPolicy.windowUnderPointer)
                            Text("活动窗口").tag(GestureTargetPolicy.activeWindow)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                        .labelsHidden()
                    }
                }

                // Section: data & permissions
                section(title: "数据与权限") {
                    HStack(spacing: 10) {
                        Button("导入配置") { importConfiguration() }.buttonStyle(.mgGhost)
                        Button("导出配置") { exportConfiguration() }.buttonStyle(.mgGhost)
                        Spacer()
                        Button("打开权限设置") { PermissionManager.openPrivacySettings() }.buttonStyle(.mgGhost)
                    }
                    .padding(.vertical, 4)

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.mgMeta)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "导入配置会覆盖当前手势",
            isPresented: $showingImportConfirm,
            titleVisibility: .visible
        ) {
            Button("导入", role: .destructive) { performImport() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("建议先导出当前配置作为备份。")
        }
        .alert("操作失败", isPresented: $showingError) {
            Button("好") {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Reusable section + row

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MGSectionLabel(text: title)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassSurface(.thin, radius: MGRadius.card)
        }
    }

    @ViewBuilder
    private func settingsRow<Trailing: View>(
        _ label: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(label).font(.mgBody)
            Spacer()
            trailing()
        }
        .padding(.vertical, 10)
    }

    // MARK: - Import/export

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.title = "导入 MyGestures 配置"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingImportURL = url
        showingImportConfirm = true
    }

    private func performImport() {
        guard let url = pendingImportURL else { return }
        pendingImportURL = nil
        do {
            let data = try Data(contentsOf: url)
            try store.importBackupData(data)
            statusMessage = "配置已导入：\(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.title = "导出 MyGestures 配置"
        panel.nameFieldStringValue = "MyGestures-Backup.json"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try store.exportBackupData()
            try data.write(to: url, options: .atomic)
            statusMessage = "配置已导出：\(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}
