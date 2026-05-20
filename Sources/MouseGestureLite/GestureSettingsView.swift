import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GestureSettingsView: View {
    private let store = GestureStore.shared
    @State private var draftGestures: [GestureCommand] = []
    @State private var didLoadDraft = false
    @State private var selectedGestureID: UUID?
    @State private var editingName = ""
    @State private var shortcut: Shortcut?
    @State private var statusMessage = ""
    @State private var showingImportConfirm = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var pendingImportURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            generalSettingsSection
            Divider()
            HSplitView {
                gestureListPanel
                    .frame(minWidth: 240, idealWidth: 280)
                gestureEditorPanel
                    .frame(minWidth: 480)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            actionBar
        }
        .onChange(of: selectedGestureID) { oldID, newID in
            guard newID != nil || draftGestures.isEmpty else {
                selectedGestureID = oldID ?? draftGestures.first?.id
                return
            }
            syncEditorFromDraft(id: newID)
        }
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
        .onAppear {
            guard !didLoadDraft else { return }
            didLoadDraft = true
            reloadDraftFromStore()
        }
    }

    private var visibleStatusMessage: String {
        if !statusMessage.isEmpty {
            return statusMessage
        }
        if draftGestures != store.gestures {
            return "有未保存的更改。"
        }
        return ""
    }

    private var selectedGesture: GestureCommand? {
        guard let id = selectedGestureID else { return nil }
        return draftGestures.first { $0.id == id }
    }

    private func reloadDraftFromStore(select id: UUID? = nil) {
        draftGestures = store.gestures
        let targetID = id ?? selectedGestureID
        if let targetID, draftGestures.contains(where: { $0.id == targetID }) {
            selectedGestureID = targetID
            syncEditorFromDraft(id: targetID)
        } else {
            selectedGestureID = draftGestures.first?.id
            syncEditorFromDraft(id: selectedGestureID)
        }
    }

    private func syncEditorFromDraft(id: UUID?) {
        guard let id, let gesture = draftGestures.first(where: { $0.id == id }) else {
            editingName = ""
            shortcut = nil
            return
        }
        editingName = gesture.name
        shortcut = gesture.shortcut
    }

    private func updateSelectedDraftGesture(_ update: (inout GestureCommand) -> Void) {
        guard let id = selectedGestureID,
              let idx = draftGestures.firstIndex(where: { $0.id == id }) else { return }
        update(&draftGestures[idx])
        statusMessage = ""
    }

    private func applyEditorToDraft() {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSelectedDraftGesture { gesture in
            gesture.name = trimmed.isEmpty ? "未命名" : trimmed
            gesture.shortcut = shortcut
        }
    }

    private func normalizedDraftGesturesForSave() -> [GestureCommand] {
        draftGestures.map { gesture in
            var normalized = gesture
            let trimmed = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.name = trimmed.isEmpty ? "未命名" : trimmed
            return normalized
        }
    }

    private func gestureNameBinding() -> Binding<String> {
        Binding(
            get: { editingName },
            set: { value in
                editingName = value
                updateSelectedDraftGesture { $0.name = value }
            }
        )
    }

    // MARK: - General Settings

    private var generalSettingsSection: some View {
        Form {
            Section {
                Toggle("启用手势监听", isOn: Binding(
                    get: { store.preferences.gesturesEnabled },
                    set: { v in store.updatePreferences { $0.gesturesEnabled = v } }
                ))
                Toggle("开机自动启动", isOn: Binding(
                    get: { LoginItemManager.isEnabled },
                    set: { enabled in
                        do {
                            try LoginItemManager.setEnabled(enabled)
                        } catch {
                            statusMessage = "无法更新开机启动：\(error.localizedDescription)"
                        }
                    }
                ))
                Toggle("显示菜单栏图标", isOn: Binding(
                    get: { store.preferences.showMenuBarIcon },
                    set: { v in store.updatePreferences { $0.showMenuBarIcon = v } }
                ))
                Toggle("绘制时显示轨迹", isOn: Binding(
                    get: { store.preferences.showTrail },
                    set: { v in store.updatePreferences { $0.showTrail = v } }
                ))
                LabeledContent("手势超时") {
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
                Picker("手势作用目标", selection: Binding(
                    get: { store.preferences.gestureTargetPolicy },
                    set: { v in store.updatePreferences { $0.gestureTargetPolicy = v } }
                )) {
                    Text("鼠标指针下方").tag(GestureTargetPolicy.windowUnderPointer)
                    Text("活动窗口").tag(GestureTargetPolicy.activeWindow)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, -8)
    }

    // MARK: - Gesture List

    private var gestureListPanel: some View {
        VStack(spacing: 0) {
            List(draftGestures, selection: $selectedGestureID) { gesture in
                GestureRowView(gesture: gesture)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectGesture(gesture.id)
                    }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .controlBackgroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 8) {
                Button(action: addGesture) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新增手势")

                Button(action: deleteSelectedGesture) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(draftGestures.isEmpty)
                .help("删除所选手势")

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.background)
        }
    }

    // MARK: - Gesture Editor

    @ViewBuilder
    private var gestureEditorPanel: some View {
        if let gesture = selectedGesture {
            ScrollView {
                Form {
                    Section("名称") {
                        TextField("手势名称", text: gestureNameBinding())
                    }

                    Section("快捷键") {
                        ShortcutRecorderRepresentable(shortcut: $shortcut)
                            .frame(height: 44)
                            .onChange(of: shortcut) { _, newVal in
                                updateSelectedDraftGesture { $0.shortcut = newVal }
                            }
                    }

                    Section {
                        GestureCaptureRepresentable(
                            templates: gesture.templates,
                            onStrokeFinished: { points in
                                updateSelectedDraftGesture { $0.templates.append(points.map(StrokePoint.init)) }
                            }
                        )
                        .frame(minHeight: 200)

                        HStack {
                            Text("\(gesture.templates.count) 个样本")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                            Spacer()
                            Button("撤销上一个") {
                                updateSelectedDraftGesture { gesture in
                                    if !gesture.templates.isEmpty { gesture.templates.removeLast() }
                                }
                            }
                            .disabled(gesture.templates.isEmpty)
                            Button("清空样本") {
                                updateSelectedDraftGesture { $0.templates.removeAll() }
                            }
                            .disabled(gesture.templates.isEmpty)
                        }
                        Text("建议：同一个手势录制 2-3 个样本，识别会更稳。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("手势样本")
                    }
                }
                .formStyle(.grouped)
            }
        } else {
            ContentUnavailableView(
                "未选择手势",
                systemImage: "hand.draw",
                description: Text("从左侧列表选择一个手势进行编辑。")
            )
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("导入配置") { importConfiguration() }
            Button("导出配置") { exportConfiguration() }
            Spacer()
            if !visibleStatusMessage.isEmpty {
                Text(visibleStatusMessage)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Button("打开权限设置") { PermissionManager.openPrivacySettings() }
            Button("保存") { saveCurrentEditor() }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background)
    }

    // MARK: - Helpers

    private func selectGesture(_ id: UUID?) {
        selectedGestureID = id
        syncEditorFromDraft(id: id)
    }

    private func saveCurrentEditor() {
        applyEditorToDraft()
        let gesturesToSave = normalizedDraftGesturesForSave()
        store.updateGestures { $0 = gesturesToSave }
        draftGestures = gesturesToSave
        statusMessage = "已保存。"
    }

    private func addGesture() {
        let newGesture = GestureCommand(name: "新手势", templates: [], shortcut: nil)
        draftGestures.append(newGesture)
        selectGesture(newGesture.id)
        statusMessage = ""
    }

    private func deleteSelectedGesture() {
        guard let id = selectedGestureID ?? draftGestures.last?.id,
              let idx = draftGestures.firstIndex(where: { $0.id == id }) else { return }
        let nextID: UUID? = draftGestures.count > 1
            ? draftGestures[idx == draftGestures.count - 1 ? idx - 1 : idx + 1].id
            : nil
        draftGestures.remove(at: idx)
        selectGesture(nextID)
        statusMessage = ""
    }

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
            reloadDraftFromStore(select: store.gestures.first?.id)
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

// MARK: - Gesture Row

private struct GestureRowView: View {
    let gesture: GestureCommand

    var body: some View {
        HStack {
            Text(gesture.name)
                .fontWeight(.medium)
            Spacer()
            if let sc = gesture.shortcut {
                Text(sc.displayName)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
