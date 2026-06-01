import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - GeneralSettingsPage (v2)
//
// PageHeader + 3 个 GroupCard:
//   行为:4 个 Toggle 行
//   识别参数:Stepper + Segmented
//   数据与权限:说明文字 + 导入/导出/打开权限设置 按钮
// 这一页没有 BottomToolbar(所有变更直接落到 store)。

struct GeneralSettingsPage: View {
    private let store = GestureStore.shared

    @State private var showingImportConfirm = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var statusMessage = ""
    @State private var pendingImportURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    tag: "General",
                    title: "通用设置",
                    subtitle: "调整应用行为、识别参数和数据备份。"
                )

                // 行为
                VStack(alignment: .leading, spacing: 0) {
                    MGSectionLabel(text: "行为")
                    GroupCard {
                        VStack(spacing: 0) {
                            GroupRow(label: "启用手势监听") {
                                Toggle("", isOn: Binding(
                                    get: { store.preferences.gesturesEnabled },
                                    set: { v in store.updatePreferences { $0.gesturesEnabled = v } }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .tint(.mgAccent)
                            }
                            GroupRow(label: "开机自动启动", showDivider: true) {
                                Toggle("", isOn: Binding(
                                    get: { LoginItemManager.isEnabled },
                                    set: { enabled in
                                        do {
                                            try LoginItemManager.setEnabled(enabled)
                                            statusMessage = "已更新开机启动设置。"
                                        } catch {
                                            statusMessage = "无法更新开机启动:\(error.localizedDescription)"
                                        }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .tint(.mgAccent)
                            }
                            GroupRow(label: "显示菜单栏图标", showDivider: true) {
                                Toggle("", isOn: Binding(
                                    get: { store.preferences.showMenuBarIcon },
                                    set: { v in store.updatePreferences { $0.showMenuBarIcon = v } }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .tint(.mgAccent)
                            }
                            GroupRow(label: "绘制时显示轨迹", showDivider: true) {
                                Toggle("", isOn: Binding(
                                    get: { store.preferences.showTrail },
                                    set: { v in store.updatePreferences { $0.showTrail = v } }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .tint(.mgAccent)
                            }
                            GroupRow(
                                label: "乱划取消手势",
                                sub: "手势途中来回乱划几下即可取消,无需等待超时",
                                showDivider: true
                            ) {
                                Toggle("", isOn: Binding(
                                    get: { store.preferences.scribbleCancelEnabled },
                                    set: { v in store.updatePreferences { $0.scribbleCancelEnabled = v } }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .tint(.mgAccent)
                            }
                        }
                    }
                }

                // 识别参数
                VStack(alignment: .leading, spacing: 0) {
                    MGSectionLabel(text: "识别参数")
                    GroupCard {
                        VStack(spacing: 0) {
                            GroupRow(
                                label: "手势超时时长",
                                sub: "超时未完成的手势会被丢弃"
                            ) {
                                HStack(spacing: 6) {
                                    MGStepperField(
                                        value: Binding(
                                            get: { store.preferences.gestureTimeoutSeconds },
                                            set: { v in store.updatePreferences { $0.gestureTimeoutSeconds = min(max(v, 0.5), 10) } }
                                        ),
                                        range: 0.5...10.0,
                                        step: 0.5
                                    )
                                    Text("秒")
                                        .font(.mgBody)
                                        .foregroundStyle(Color.mgText2)
                                }
                            }
                            GroupRow(label: "手势作用目标", showDivider: true) {
                                Picker("", selection: Binding(
                                    get: { store.preferences.gestureTargetPolicy },
                                    set: { v in store.updatePreferences { $0.gestureTargetPolicy = v } }
                                )) {
                                    Text("鼠标指针下方").tag(GestureTargetPolicy.windowUnderPointer)
                                    Text("活动窗口").tag(GestureTargetPolicy.activeWindow)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 220)
                            }
                        }
                    }
                }

                // 数据与权限
                VStack(alignment: .leading, spacing: 0) {
                    MGSectionLabel(text: "数据与权限")
                    GroupCard(padding: EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("配置文件会包含鼠标手势、窗口管理快捷键、识别参数和菜单栏偏好;开机自动启动属于系统登录项,不随配置导入导出。")
                                .font(.system(size: 12.5))
                                .lineSpacing(3)
                                .foregroundStyle(Color.mgText2)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 8) {
                                Button {
                                    importConfiguration()
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "square.and.arrow.down")
                                            .font(.system(size: 11, weight: .medium))
                                        Text("导入配置")
                                    }
                                }
                                .buttonStyle(MGSecondaryButtonStyle())

                                Button {
                                    exportConfiguration()
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "square.and.arrow.up")
                                            .font(.system(size: 11, weight: .medium))
                                        Text("导出配置")
                                    }
                                }
                                .buttonStyle(MGSecondaryButtonStyle())

                                Spacer()

                                Button {
                                    PermissionManager.openPrivacySettings()
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("打开权限设置")
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                }
                                .buttonStyle(MGSecondaryButtonStyle(foreground: .mgAccent))
                            }

                            if !statusMessage.isEmpty {
                                Text(statusMessage)
                                    .font(.mgMeta)
                                    .foregroundStyle(Color.mgText2)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "导入配置会覆盖当前全部配置",
            isPresented: $showingImportConfirm,
            titleVisibility: .visible
        ) {
            Button("导入", role: .destructive) { performImport() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会覆盖鼠标手势、窗口管理和通用偏好。建议先导出当前配置作为备份。")
        }
        .alert("操作失败", isPresented: $showingError) {
            Button("好") {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Import/export

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.title = "导入 Velto 配置"
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
            statusMessage = "配置已导入:\(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.title = "导出 Velto 配置"
        panel.nameFieldStringValue = "Velto-Backup.json"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try store.exportBackupData()
            try data.write(to: url, options: .atomic)
            statusMessage = "配置已导出:\(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}
