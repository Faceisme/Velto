import AppKit
import SwiftUI

// MARK: - GesturesPage (v2)
//
// 三段布局:
//   [SidebarView 220]  |  [List column 360]  |  [Detail + bottom toolbar]
// 这里只负责 List + Detail + BottomBar 三块,Sidebar 由 SettingsRootView 提供。

struct GesturesPage: View {
    private let store = GestureStore.shared

    @State private var draftGestures: [GestureCommand] = []
    @State private var didLoad = false
    @State private var selectedID: UUID?
    @State private var editingName = ""
    @State private var isEditingName = false
    @State private var shortcut: Shortcut?
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
            HStack(spacing: 0) {
                listColumn
                    .frame(width: 360)
                    .background(Color.clear)
                    .overlay(
                        Rectangle()
                            .fill(Color.mgHair)
                            .frame(width: 1),
                        alignment: .trailing
                    )

                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.clear)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            BottomToolbar(
                hasUnsavedChanges: hasUnsavedChanges,
                statusMessage: statusMessage,
                saveBlockReason: validation.block,
                saveWarning: validation.warning,
                onDiscard: { reloadFromStore() },
                onSave: saveChanges
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: loadDraftIfNeeded)
        .onReceive(NotificationCenter.default.publisher(for: .gestureStoreDidChange)) { note in
            guard note.object as? GestureStore === store else { return }
            switch note.gestureStoreChangeReason {
            case .gestures, .backupImport:
                reloadFromStore(silent: true)
            default: break
            }
        }
    }

    // MARK: List column

    private var listColumn: some View {
        // 每次渲染只算一遍规范序列与冲突集,避免在 ForEach 里逐行重复计算。
        let canonical = canonicalByID
        let conflicts = conflictSet(from: canonical)
        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Text("鼠标手势")
                    .font(.mgTitleM)
                    .foregroundStyle(Color.mgText1)

                Text("\(draftGestures.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.mgAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.mgAccentSoft))

                Spacer()

                Button(action: addGesture) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("新建")
                    }
                }
                .buttonStyle(MGPrimaryButtonStyle(height: 30, hPad: 13, font: .mgButtonSm))
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 14)

            // List
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(draftGestures) { g in
                        let sig = canonical[g.id] ?? .empty
                        GestureListItem(
                            gesture: g,
                            directionArrows: GestureDirection.displayString(sig),
                            conflict: conflicts.contains(g.id),
                            selected: g.id == selectedID,
                            onClick: { selectGesture(g.id) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }

            // 模块级调试开关:只点亮手势日志(velto-debug.jsonl),不影响其它模块。
            HStack(spacing: 8) {
                Image(systemName: "ladybug")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mgText2)
                    .frame(width: 30, height: 30)
                    .background(Color.mgAccentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("调试日志")
                        .font(.mgLabelStrong)
                        .foregroundStyle(Color.mgText1)
                    Text("记录手势轨迹/匹配诊断,排查时打开")
                        .font(.mgMeta)
                        .foregroundStyle(Color.mgText2)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { store.preferences.debugLoggingEnabled },
                    set: { v in store.updatePreferences { $0.debugLoggingEnabled = v } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.mgAccent)
            }
            .padding(14)
            .veltoGlassPanel(radius: MGRadius.cardSm)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    // MARK: Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if let g = selected {
            ScrollView {
                GestureDetailPanel(
                    gesture: g,
                    editingName: $editingName,
                    isEditingName: $isEditingName,
                    shortcut: $shortcut,
                    onDelete: deleteSelectedGesture,
                    updateDraft: updateSelectedDraft
                )
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 28)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Color.mgText3)
                Text("未选择手势")
                    .font(.mgTitleM)
                    .foregroundStyle(Color.mgText1)
                Text("从左侧选择一个手势进行编辑")
                    .font(.mgBody)
                    .foregroundStyle(Color.mgText2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Lifecycle helpers

    private func loadDraftIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        draftGestures = store.gestures
        hasUnsavedChanges = false
        if selectedID == nil, let first = draftGestures.first {
            selectedID = first.id
        }
        if let g = selected { syncEditor(from: g) }
    }

    private func syncEditor(from g: GestureCommand) {
        editingName = g.name
        isEditingName = false
        shortcut = g.shortcut
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
        syncEditor(from: new)
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
        if let g = selected { syncEditor(from: g) }
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
        statusMessage = persisted
            ? "已保存。"
            : "保存失败:无法写入配置(本次更改本会话有效,重启后会丢失)。"
    }

    private func reloadFromStore(silent: Bool = false) {
        draftGestures = store.gestures
        hasUnsavedChanges = false
        if selectedID == nil {
            selectedID = draftGestures.first?.id
        } else if let id = selectedID, !draftGestures.contains(where: { $0.id == id }) {
            selectedID = draftGestures.first?.id
        }
        if let g = selected {
            syncEditor(from: g)
        } else {
            editingName = ""
            isEditingName = false
            shortcut = nil
        }
        statusMessage = silent ? "" : "已丢弃未保存更改。"
    }

    private func selectGesture(_ id: UUID) {
        guard selectedID != id else { return }
        selectedID = id
        if let g = draftGestures.first(where: { $0.id == id }) {
            syncEditor(from: g)
        }
    }
}

// MARK: - GestureListItem
//
// 高 ~56pt 横向布局:
//  - 40×40 缩略图盒子
//  - 标签 + N 样本(子文字)
//  - Kbd chips
// 选中:整行 #0A84FF, 全部文字白色, 缩略图盒子 + Kbd 切到 inverted 配色

private struct GestureListItem: View {
    let gesture: GestureCommand
    /// 该手势识别成的方向箭头串(如 "↗→"),空串表示还没录。
    let directionArrows: String
    /// 与别的手势撞了同一条方向序列。
    let conflict: Bool
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 12) {
                // Thumbnail 盒子
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected
                              ? Color.white.opacity(0.18)
                              : Color.mgCardAlt)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(selected
                                              ? Color.white.opacity(0.20)
                                              : Color.mgHair,
                                              lineWidth: 0.5)
                        )

                    if !gesture.templates.isEmpty {
                        GestureTrailView(
                            templates: [gesture.templates.last!],  // 缩略图只渲染最后一个样本,免噪
                            stroke: 3,
                            colors: selected
                                ? [.white, Color.white.opacity(0.75)]
                                : [.mgAccent, .mgAccent],
                            showStartDot: true,
                            showEndArrow: true,
                            maxGhosts: 0
                        )
                        .padding(6)
                    } else {
                        Image(systemName: "questionmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(selected
                                             ? Color.white.opacity(0.75)
                                             : Color.mgText3)
                    }
                }
                .frame(width: 40, height: 40)

                // Label + sub
                VStack(alignment: .leading, spacing: 2) {
                    Text(gesture.name)
                        .font(.mgLabelStrong)
                        .foregroundStyle(selected ? .white : Color.mgText1)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if !directionArrows.isEmpty {
                            Text(directionArrows)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(selected ? .white : Color.mgText1)
                        }
                        Text("\(gesture.templates.count) 样本")
                            .font(.mgMeta)
                            .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.mgText2)
                        if conflict {
                            Text("冲突")
                                .font(.mgMeta)
                                .foregroundStyle(selected ? Color.yellow : Color.orange)
                        }
                    }
                }

                Spacer(minLength: 4)

                // Kbd chips
                if let sc = gesture.shortcut {
                    Kbd(keys: sc.kbdKeys, size: .sm, inverted: selected)
                } else {
                    Text("未设置")
                        .font(.mgMeta)
                        .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.mgText3)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Group {
                    if selected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.mgAccent)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.mgGlassWeak)
                            .veltoNativeGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.clear : Color.mgHair, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transaction { $0.animation = nil }
    }
}

// MARK: - Detail panel (right column)

private struct GestureDetailPanel: View {
    let gesture: GestureCommand
    @Binding var editingName: String
    @Binding var isEditingName: Bool
    @Binding var shortcut: Shortcut?
    var onDelete: () -> Void
    var updateDraft: ((inout GestureCommand) -> Void) -> Void
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.bottom, 22)

            // 录制新样本 section
            Text("录制新样本")
                .font(.mgLabelStrong)
                .foregroundStyle(Color.mgText2)
                .padding(.bottom, 8)

            captureCard
                .padding(.bottom, 20)

            // 触发的快捷键 section
            Text("触发的快捷键")
                .font(.mgLabelStrong)
                .foregroundStyle(Color.mgText2)
                .padding(.bottom, 8)

            shortcutCard
        }
    }

    // Header: GESTURE tag 独立一行;下面大标题 + Kbd + 按钮组同一行,
    // 右侧控件整体垂直居中于标题。**不要**用外层 alignment + padding 微调
    // 的写法 —— 字号一动就破。
    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("GESTURE")
                .font(.mgTag)
                .tracking(1.5)
                .foregroundStyle(Color.mgText3)
                .padding(.bottom, 6)

            HStack(alignment: .center, spacing: 12) {
                titleField

                Spacer(minLength: 12)

                HStack(alignment: .center, spacing: 8) {
                    Button {
                        isEditingName.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isEditingName ? "checkmark" : "pencil")
                                .font(.system(size: 12, weight: .medium))
                            Text(isEditingName ? "完成" : "修改")
                        }
                    }
                    .buttonStyle(MGSecondaryButtonStyle(height: 32, hPad: 12, font: .mgBodyMedium))

                    Button(action: onDelete) {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .medium))
                            Text("删除")
                        }
                    }
                    .buttonStyle(MGDestructiveButtonStyle())
                }
                // hold 住右侧整组的固有宽度。Kbd 多一个键(如 ⇧⌘])就要多 ~37pt,
                // 父 HStack 宽度紧时 SwiftUI 默认会去挤 Button label —— 表现是
                // "修改" / "删除" 两个字被截掉,只剩个铅笔/垃圾桶图标。
                // fixedSize 把压缩压力推回给左边的标题 Text(它已经 lineLimit(1),
                // 会优雅截断)。
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .onChange(of: isEditingName) { _, editing in
            if editing {
                DispatchQueue.main.async {
                    nameFieldFocused = true
                }
            } else {
                nameFieldFocused = false
            }
        }
    }

    @ViewBuilder
    private var titleField: some View {
        if isEditingName {
            TextField("手势名称", text: $editingName)
                .textFieldStyle(.plain)
                .font(.mgPageTitle)
                .foregroundStyle(Color.mgText1)
                .focused($nameFieldFocused)
                .onSubmit { isEditingName = false }
                .onChange(of: editingName) { _, newVal in
                    updateDraft { $0.name = newVal }
                }
        } else {
            Text(displayName)
                .font(.mgPageTitle)
                .foregroundStyle(Color.mgText1)
                .lineLimit(1)
                .textSelection(.disabled)
        }
    }

    private var displayName: String {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名" : trimmed
    }

    // 录制卡:系统白底 + 原生玻璃效果 + 操作区
    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // GesturePreviewCard 提供网格 / 已保存样本 / 玻璃药丸 / 提示;
            // GestureCaptureRepresentable 是透明 NSView,只负责截获鼠标事件并
            // 实时画出正在录制的笔迹。
            GesturePreviewCard(
                templates: gesture.templates,
                sampleCount: gesture.templates.count,
                height: 220
            ) {
                GestureCaptureRepresentable { points in
                    updateDraft { $0.templates.append(points.map(StrokePoint.init)) }
                }
            }

            HStack(spacing: 8) {
                Button("撤销上一个") {
                    updateDraft { g in
                        if !g.templates.isEmpty { g.templates.removeLast() }
                    }
                }
                .buttonStyle(MGSecondaryButtonStyle())
                .disabled(gesture.templates.isEmpty)

                Button("清空样本") {
                    updateDraft { $0.templates.removeAll() }
                }
                .buttonStyle(MGSecondaryButtonStyle())
                .disabled(gesture.templates.isEmpty)

                Spacer()

                Text("建议同一手势录制 2–3 个样本,识别会更稳。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mgText2)
            }
        }
        .padding(16)
        .veltoGlassPanel(radius: MGRadius.cardLg, shadow: true)
    }

    // 触发的快捷键卡片
    private var shortcutCard: some View {
        HStack(spacing: 12) {
            ShortcutRecorderField(
                shortcut: $shortcut,
                placeholder: "未设置 · 点击录制",
                fillWidth: true
            )
            .onChange(of: shortcut) { _, newVal in
                updateDraft { $0.shortcut = newVal }
            }

            if shortcut != nil {
                Button("清除") {
                    shortcut = nil
                }
                .buttonStyle(MGPlainButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
        .veltoGlassPanel(radius: MGRadius.card)
    }
}

// MARK: - BottomToolbar
//
// 52pt 高, 白底, 顶部 0.5px 分隔线, 右对齐:
//   [丢弃更改]  [保存]

struct BottomToolbar: View {
    let hasUnsavedChanges: Bool
    let statusMessage: String
    /// 非空 = 存在冲突,阻止保存(红色提示 + 禁用保存按钮)。
    var saveBlockReason: String? = nil
    /// 非空 = 半配置手势,不阻止保存(橙色提示)。
    var saveWarning: String? = nil
    let onDiscard: () -> Void
    let onSave: () -> Void

    private var saveDisabled: Bool { !hasUnsavedChanges || saveBlockReason != nil }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.mgHair)
                .frame(height: 0.5)

            HStack(spacing: 10) {
                statusArea

                Spacer()

                Button("丢弃更改", action: onDiscard)
                    .buttonStyle(MGPlainButtonStyle())
                    .disabled(!hasUnsavedChanges)
                    .opacity(hasUnsavedChanges ? 1 : 0.45)

                Button("保存", action: onSave)
                    .buttonStyle(MGPrimaryButtonStyle())
                    .keyboardShortcut(.return)
                    .disabled(saveDisabled)
                    .opacity(saveDisabled ? 0.55 : 1)
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
        }
        .veltoGlassSurface(radius: 0, fill: .mgGlassWeak, shadow: false)
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
