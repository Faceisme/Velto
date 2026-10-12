import AppKit
import SwiftUI

// MARK: - GesturesPage
//
// 页头 + [手势 | 设置] 分段固定在顶部,下面按分段切换:
//   手势:列表(一张卡)| 详情(录制 / 快捷键),两栏各自滚动、不限宽;有改动或冲突时底部出现保存栏
//   设置:行为 / 识别 / 调试,直接写 store
// 手势列表留草稿:录样本是"编辑文档"式的操作,而且要先过冲突校验才能保存。

struct GesturesPage: View {
    private enum Tab: Hashable { case gestures, settings }

    private let store = GestureStore.shared

    @State private var tab: Tab = .gestures
    @State private var draftGestures: [GestureCommand] = []
    @State private var didLoad = false
    @State private var selectedID: UUID?
    @State private var statusMessage = ""
    @State private var hasUnsavedChanges = false

    private var selected: GestureCommand? {
        guard let id = selectedID else { return nil }
        return draftGestures.first { $0.id == id }
    }

    /// 每个手势的规范签名 —— 列表用它展示箭头 + 弧向(如 "↗⌣")并据此检测冲突。
    private var canonicalByID: [UUID: GestureDirection.Signature] {
        Dictionary(
            uniqueKeysWithValues: draftGestures.map {
                ($0.id, GestureDirection.canonical(for: $0.templates.map { $0.map(\.cgPoint) }))
            }
        )
    }

    /// 签名差异度过小(< 余量门槛)的手势互相冲突 —— 谁都可能识别不出。
    /// 用与运行时一致的 `GestureDirection.distance`。返回涉及冲突的全部 id。
    private func conflictSet(from canonical: [UUID: GestureDirection.Signature]) -> Set<UUID> {
        let entries = canonical.filter { !$0.value.isEmpty }.map { ($0.key, $0.value) }
        var conflicting: Set<UUID> = []
        for i in entries.indices {
            for j in entries.indices where j > i {
                if GestureDirection.distance(entries[i].1, entries[j].1) < 0.05 {
                    conflicting.insert(entries[i].0)
                    conflicting.insert(entries[j].0)
                }
            }
        }
        return conflicting
    }

    /// 保存前校验。`block` 非空时**阻止保存**(列表里有手势互相重复 —— 这是最隐蔽、
    /// 最让人困惑的状态:存了却谁都不触发);`warning` 是不阻止保存的提示(半配置手势,
    /// 有快捷键没样本 / 有样本没快捷键,存下来也不会生效)。canonical 只算一遍。
    private var saveValidation: (block: String?, warning: String?) {
        let canonical = canonicalByID
        let conflicts = conflictSet(from: canonical)
        let conflictNames = draftGestures.filter { conflicts.contains($0.id) }.map(\.name)
        let block = conflictNames.isEmpty
            ? nil
            : "手势重复:\(conflictNames.joined(separator: "、")) —— 改成不同形状后才能保存"

        var warnings: [String] = []
        for gesture in draftGestures {
            let hasTemplate = !(canonical[gesture.id] ?? .empty).isEmpty
            let hasShortcut = gesture.shortcut != nil
            if hasShortcut, !hasTemplate {
                warnings.append("「\(gesture.name)」缺少有效样本")
            } else if hasTemplate, !hasShortcut {
                warnings.append("「\(gesture.name)」未设置快捷键")
            }
        }
        let warning = warnings.isEmpty ? nil : "\(warnings.joined(separator: ";")),不会触发"
        return (block, warning)
    }

    var body: some View {
        let validation = saveValidation
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    page: .gestures,
                    subtitle: "按住右键画出轨迹,触发对应的快捷键。",
                    isOn: pref(\.gesturesEnabled)
                )
                .help("关闭后右键手势暂停,不影响其它模块。")

                Picker("", selection: $tab) {
                    Text("手势").tag(Tab.gestures)
                    Text("设置").tag(Tab.settings)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.large)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)

            switch tab {
            case .gestures:
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        gestureList
                            .padding(.top, 24)
                            .padding(.bottom, 28)
                    }
                    .frame(width: 320)

                    ScrollView {
                        detail
                            .padding(.top, 24)
                            .padding(.bottom, 28)
                    }
                }
                .padding(.horizontal, 32)

                if hasUnsavedChanges || validation.block != nil || !statusMessage.isEmpty {
                    BottomToolbar(
                        hasUnsavedChanges: hasUnsavedChanges,
                        statusMessage: statusMessage,
                        saveBlockReason: validation.block,
                        saveWarning: validation.warning,
                        onDiscard: reloadFromStore,
                        onSave: saveChanges
                    )
                }
            case .settings:
                ScrollView {
                    settingsTab
                        .padding(.top, 24)
                        .padding(.bottom, 28)
                        .padding(.horizontal, 32)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: loadDraftIfNeeded)
        .onReceive(NotificationCenter.default.publisher(for: .gestureStoreDidChange)) { note in
            guard note.object as? GestureStore === store else { return }
            switch note.gestureStoreChangeReason {
            case .gestures, .backupImport:
                reloadFromStore()
            default: break
            }
        }
    }

    private func pref<V>(_ kp: WritableKeyPath<AppPreferences, V>) -> Binding<V> {
        Binding(
            get: { store.preferences[keyPath: kp] },
            set: { v in store.updatePreferences { $0[keyPath: kp] = v } }
        )
    }

    // MARK: 手势分段

    private var gestureList: some View {
        // 每次渲染只算一遍规范序列与冲突集,避免在 ForEach 里逐行重复计算。
        let canonical = canonicalByID
        let conflicts = conflictSet(from: canonical)
        return GroupCard {
            ForEach(draftGestures) { g in
                GestureRow(
                    gesture: g,
                    directionArrows: GestureDirection.displayString(canonical[g.id] ?? .empty),
                    conflict: conflicts.contains(g.id),
                    selected: g.id == selectedID,
                    onSelect: { selectedID = g.id }
                )
            }
            Button(action: addGesture) {
                Label("新建手势", systemImage: "plus")
                    .font(.mgBody)
                    .foregroundStyle(Color.mgAccent)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let g = selected {
            // 换手势时整块重建:改名状态、录制中的笔迹都不带到下一个手势。
            GestureDetail(gesture: g, onDelete: deleteSelectedGesture, updateDraft: updateSelectedDraft)
                .id(g.id)
        } else {
            GroupCard {
                EmptyRow(draftGestures.isEmpty ? "还没有手势。点左侧「新建手势」录制第一个。" : "从左侧选一个手势。")
            }
        }
    }

    // MARK: 设置分段

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection("行为") {
                SettingsRow("绘制时显示轨迹", isOn: pref(\.showTrail))
                SettingsRow(
                    "乱划取消手势",
                    subtitle: "手势途中来回乱划几下即可取消,无需等待超时。",
                    isOn: pref(\.scribbleCancelEnabled)
                )
            }

            SettingsSection("识别") {
                SettingsRow(title: "手势超时时长", subtitle: "超时未完成的手势会被丢弃。") {
                    MGStepperField(value: pref(\.gestureTimeoutSeconds), range: 0.5...10.0, step: 0.5, format: "%.1f 秒")
                }
                SettingsRow(title: "手势作用目标") {
                    Picker("", selection: pref(\.gestureTargetPolicy)) {
                        Text("鼠标指针下方").tag(GestureTargetPolicy.windowUnderPointer)
                        Text("活动窗口").tag(GestureTargetPolicy.activeWindow)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            DebugSection(
                isOn: pref(\.debugLoggingEnabled),
                logURL: DebugLog.fileURL,
                help: "记录手势轨迹和匹配诊断,排查时打开。"
            )
        }
    }

    // MARK: 草稿

    private func loadDraftIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        draftGestures = store.gestures
        selectedID = draftGestures.first?.id
    }

    private func updateSelectedDraft(_ update: (inout GestureCommand) -> Void) {
        guard let id = selectedID,
              let idx = draftGestures.firstIndex(where: { $0.id == id }) else { return }
        var modified = draftGestures[idx]
        update(&modified)
        guard modified != draftGestures[idx] else { return }
        draftGestures[idx] = modified
        hasUnsavedChanges = true
        statusMessage = ""
    }

    private func addGesture() {
        let new = GestureCommand(name: "新手势", templates: [], shortcut: nil)
        draftGestures.append(new)
        selectedID = new.id
        hasUnsavedChanges = true
        statusMessage = ""
    }

    private func deleteSelectedGesture() {
        guard let id = selectedID,
              let idx = draftGestures.firstIndex(where: { $0.id == id }) else { return }
        let nextID: UUID? = draftGestures.count > 1
            ? draftGestures[idx == draftGestures.count - 1 ? idx - 1 : idx + 1].id
            : nil
        draftGestures.remove(at: idx)
        selectedID = nextID
        hasUnsavedChanges = true
        statusMessage = ""
    }

    private func saveChanges() {
        // 阻止保存重复手势(保存按钮平时已禁用,这里兜底防回车等路径)。
        if let block = saveValidation.block {
            statusMessage = "无法保存 —— \(block)"
            return
        }
        let normalized = draftGestures.map { g -> GestureCommand in
            var n = g
            let trimmed = n.name.trimmingCharacters(in: .whitespacesAndNewlines)
            n.name = trimmed.isEmpty ? "未命名" : trimmed
            return n
        }
        let persisted = store.updateGestures { $0 = normalized }
        draftGestures = normalized
        hasUnsavedChanges = false
        // 存成功保存栏直接收起;失败留着提示。
        statusMessage = persisted ? "" : "保存失败:无法写入配置(本次更改本会话有效,重启后会丢失)。"
    }

    /// 丢弃草稿,或 store 被别处改了(备份导入等)时重载。
    private func reloadFromStore() {
        draftGestures = store.gestures
        hasUnsavedChanges = false
        if !draftGestures.contains(where: { $0.id == selectedID }) {
            selectedID = draftGestures.first?.id
        }
        statusMessage = ""
    }
}

// MARK: - 列表行

private struct GestureRow: View {
    let gesture: GestureCommand
    /// 识别成的方向 + 弧向签名(如 "↗⌣"),空串表示还没录。
    let directionArrows: String
    /// 和别的手势太像,谁都可能识别不出。
    let conflict: Bool
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                thumbnail

                VStack(alignment: .leading, spacing: 2) {
                    Text(gesture.name)
                        .font(.mgBody)
                        .foregroundStyle(Color.mgText1)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if !directionArrows.isEmpty {
                            Text(directionArrows)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text("\(gesture.templates.count) 个样本")
                        if conflict {
                            Text("冲突")
                                .foregroundStyle(Color.orange)
                        }
                    }
                    .font(.mgMeta)
                    .foregroundStyle(Color.mgText2)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let sc = gesture.shortcut {
                    Kbd(keys: sc.kbdKeys, size: .sm)
                } else {
                    Text("未设置")
                        .font(.mgMeta)
                        .foregroundStyle(Color.mgText3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
                        .fill(Color.mgAccent.opacity(0.12))
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transaction { $0.animation = nil }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MGRadius.kbd, style: .continuous)
                .fill(Color.mgInset)
            if let last = gesture.templates.last {
                // 缩略图只画最后一个样本,免噪
                GestureTrailView(templates: [last], stroke: 2.5, maxGhosts: 0)
                    .padding(4)
            } else {
                Image(systemName: "questionmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.mgText3)
            }
        }
        .frame(width: 32, height: 32)
    }
}

// MARK: - 详情

private struct GestureDetail: View {
    let gesture: GestureCommand
    let onDelete: () -> Void
    let updateDraft: ((inout GestureCommand) -> Void) -> Void

    @State private var isEditingName = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                if isEditingName {
                    TextField("手势名称", text: Binding(
                        get: { gesture.name },
                        set: { v in updateDraft { $0.name = v } }
                    ))
                    .textFieldStyle(.plain)
                    .font(.mgTitleM)
                    .focused($nameFocused)
                    .onSubmit { isEditingName = false }
                } else {
                    Text(displayName)
                        .font(.mgTitleM)
                        .foregroundStyle(Color.mgText1)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button(isEditingName ? "完成" : "重命名") { isEditingName.toggle() }
                        .buttonStyle(.bordered)
                    Button("删除", role: .destructive, action: onDelete)
                        .buttonStyle(.bordered)
                        .foregroundStyle(Color.mgDanger)
                }
                // 按钮组守住固有宽度:窄的时候让名称去截断,别把按钮的字挤没。
                .fixedSize()
            }
            .onChange(of: isEditingName) { _, editing in
                // 输入框这一帧才插进来,下一轮再给焦点。
                if editing { DispatchQueue.main.async { nameFocused = true } }
            }

            SettingsSection("录制") {
                // 画布画已存的样本;上面叠一层透明的录制视图截右键拖动,松手追加一个样本。
                GesturePreviewCard(templates: gesture.templates) {
                    GestureCaptureRepresentable { points in
                        updateDraft { $0.templates.append(points.map(StrokePoint.init)) }
                    }
                }
                .padding(12)

                SettingsRow(title: "\(gesture.templates.count) 个样本", subtitle: "建议录 2–3 个。") {
                    Group {
                        Button("撤销上一个") { updateDraft { _ = $0.templates.popLast() } }
                        Button("清空") { updateDraft { $0.templates.removeAll() } }
                    }
                    .buttonStyle(.bordered)
                    .disabled(gesture.templates.isEmpty)
                }
            }

            SettingsSection("快捷键") {
                SettingsRow(title: "触发") {
                    ShortcutField(shortcut: Binding(
                        get: { gesture.shortcut },
                        set: { v in updateDraft { $0.shortcut = v } }
                    ))
                }
            }
        }
    }

    private var displayName: String {
        let trimmed = gesture.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名" : trimmed
    }
}

// MARK: - BottomToolbar 保存栏
//
// 只在有改动、冲突或保存失败时出现;状态在左,[丢弃更改] [保存] 在右。

private struct BottomToolbar: View {
    let hasUnsavedChanges: Bool
    let statusMessage: String
    /// 非空 = 存在冲突,阻止保存(红色提示 + 禁用保存按钮)。
    let saveBlockReason: String?
    /// 非空 = 半配置手势,不阻止保存(橙色提示)。
    let saveWarning: String?
    let onDiscard: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusArea

            Spacer()

            Button("丢弃更改", action: onDiscard)
                .buttonStyle(.borderless)
                .disabled(!hasUnsavedChanges)

            Button("保存", action: onSave)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(!hasUnsavedChanges || saveBlockReason != nil)
        }
        .padding(.horizontal, 32)
        .frame(height: 54)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.mgHair)
                .frame(height: 0.5)
        }
        .glassEffect(.regular, in: Rectangle())
    }

    @ViewBuilder
    private var statusArea: some View {
        if let block = saveBlockReason {
            // 冲突优先,红色,且会禁用保存。
            label(text: block, dot: .red, color: .red)
        } else if let warning = saveWarning {
            label(text: warning, dot: .orange, color: Color.mgText2)
        } else if hasUnsavedChanges {
            label(text: "有未保存的更改", dot: .orange, color: Color.mgText2)
        } else if !statusMessage.isEmpty {
            Text(statusMessage)
                .font(.mgMeta)
                .foregroundStyle(Color.mgText2)
        }
    }

    private func label(text: String, dot: Color, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text)
                .font(.mgMeta)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}
