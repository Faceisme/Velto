import AppKit
import SwiftUI

// MARK: - GesturesPage (v2)
//
// 三段布局:
//   [SidebarView 220]  |  [List column 340 #FFF]  |  [Detail #FFF + bottom toolbar]
// 这里只负责 List + Detail + BottomBar 三块,Sidebar 由 SettingsRootView 提供。

struct GesturesPage: View {
    private let store = GestureStore.shared

    @State private var draftGestures: [GestureCommand] = []
    @State private var didLoad = false
    @State private var selectedID: UUID?
    @State private var editingName = ""
    @State private var shortcut: Shortcut?
    @State private var statusMessage = ""
    @State private var hasUnsavedChanges = false

    private var selected: GestureCommand? {
        guard let id = selectedID else { return nil }
        return draftGestures.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                listColumn
                    .frame(width: 340)
                    .background(Color.mgCard)
                    .overlay(
                        // 0.5px 右分隔线
                        Rectangle()
                            .fill(Color.mgHair)
                            .frame(width: 0.5),
                        alignment: .trailing
                    )

                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mgCard)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            BottomToolbar(
                hasUnsavedChanges: hasUnsavedChanges,
                statusMessage: statusMessage,
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
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("鼠标手势")
                    .font(.mgTitleM)
                    .foregroundStyle(Color.mgText1)

                Text("\(draftGestures.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.mgAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.mgAccent.opacity(0.10)))

                Spacer()

                Button(action: addGesture) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("新建")
                    }
                }
                .buttonStyle(MGPrimaryButtonStyle(height: 26, hPad: 12, font: .mgButtonSm))
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // List
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(draftGestures) { g in
                        GestureListItem(
                            gesture: g,
                            selected: g.id == selectedID,
                            onClick: { selectGesture(g.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
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
                    shortcut: $shortcut,
                    onDelete: deleteSelectedGesture,
                    updateDraft: updateSelectedDraft
                )
                .padding(.horizontal, 28)
                .padding(.top, 22)
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
        let normalized = draftGestures.map { g -> GestureCommand in
            var n = g
            let trimmed = n.name.trimmingCharacters(in: .whitespacesAndNewlines)
            n.name = trimmed.isEmpty ? "未命名" : trimmed
            return n
        }
        store.updateGestures { $0 = normalized }
        draftGestures = normalized
        hasUnsavedChanges = false
        statusMessage = "已保存。"
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
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 12) {
                // Thumbnail 盒子
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected
                              ? Color.white.opacity(0.15)
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
                                ? [.white, Color.mgAccentSoft]
                                : [.mgAccent, .mgAccentEnd],
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
                    Text("\(gesture.templates.count) 样本")
                        .font(.mgMeta)
                        .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.mgText2)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.mgAccent : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

// MARK: - Detail panel (right column)

private struct GestureDetailPanel: View {
    let gesture: GestureCommand
    @Binding var editingName: String
    @Binding var shortcut: Shortcut?
    var onDelete: () -> Void
    var updateDraft: ((inout GestureCommand) -> Void) -> Void

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

    // Header: GESTURE tag + 大标题 + Kbd + 删除
    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text("GESTURE")
                    .font(.mgTag)
                    .tracking(1.5)
                    .foregroundStyle(Color.mgText3)
                    .padding(.bottom, 6)

                TextField("手势名称", text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.mgPageTitle)
                    .tracking(-0.4)
                    .foregroundStyle(Color.mgText1)
                    .onChange(of: editingName) { _, newVal in
                        updateDraft { $0.name = newVal }
                    }
            }

            Spacer(minLength: 12)

            if let sc = gesture.shortcut {
                Kbd(keys: sc.kbdKeys, size: .lg)
                    .padding(.top, 4)
            }

            Button(action: onDelete) {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                    Text("删除")
                }
            }
            .buttonStyle(MGDestructiveButtonStyle())
            .padding(.top, 4)
        }
    }

    // 大白卡片:画布 + 撤销/清空 + 提示
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
        .mgCard(radius: MGRadius.cardLg)
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
        .mgCard(radius: MGRadius.card)
    }
}

// MARK: - BottomToolbar
//
// 52pt 高, 白底, 顶部 0.5px 分隔线, 右对齐:
//   [丢弃更改]  [保存]

struct BottomToolbar: View {
    let hasUnsavedChanges: Bool
    let statusMessage: String
    let onDiscard: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.mgHair)
                .frame(height: 0.5)

            HStack(spacing: 10) {
                if hasUnsavedChanges {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text("有未保存的更改")
                            .font(.mgMeta)
                            .foregroundStyle(Color.mgText2)
                    }
                } else if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.mgMeta)
                        .foregroundStyle(Color.mgText2)
                }

                Spacer()

                Button("丢弃更改", action: onDiscard)
                    .buttonStyle(MGPlainButtonStyle())
                    .disabled(!hasUnsavedChanges)
                    .opacity(hasUnsavedChanges ? 1 : 0.45)

                Button("保存", action: onSave)
                    .buttonStyle(MGPrimaryButtonStyle())
                    .keyboardShortcut(.return)
                    .disabled(!hasUnsavedChanges)
                    .opacity(hasUnsavedChanges ? 1 : 0.55)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
        .background(Color.mgCard)
    }
}
