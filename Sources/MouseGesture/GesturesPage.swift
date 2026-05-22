import AppKit
import SwiftUI

struct GesturesPage: View {
    private let store = GestureStore.shared
    @State private var draftGestures: [GestureCommand] = []
    @State private var didLoad = false
    @State private var selectedID: UUID?
    @State private var editingName = ""
    @State private var shortcut: Shortcut?
    @State private var statusMessage = ""
    @State private var hasUnsavedChanges = false

    var selected: GestureCommand? {
        guard let id = selectedID else { return nil }
        return draftGestures.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                listColumn
                    .frame(width: 340)
                    .clipped()
                Divider()
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            saveBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: loadDraftIfNeeded)
        .onReceive(NotificationCenter.default.publisher(for: .gestureStoreDidChange)) { notification in
            guard notification.object as? GestureStore === store else { return }
            switch notification.gestureStoreChangeReason {
            case .gestures, .backupImport:
                reloadFromStore(silent: true)
            default:
                break
            }
        }
    }

    // MARK: - List column

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("鼠标手势").font(.mgTitleM)
                Text("\(draftGestures.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Button(action: addGesture) {
                    Label("新建", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(draftGestures) { gesture in
                        let isSelected = gesture.id == selectedID
                        GestureRow(gesture: gesture, selected: isSelected)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isSelected ? Color.mgAccent : Color.clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectGesture(gesture.id)
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if let g = selected {
            ScrollView {
                DetailPanel(
                    gesture: g,
                    editingName: $editingName,
                    shortcut: $shortcut,
                    onDelete: deleteSelectedGesture,
                    updateDraft: updateSelectedDraft
                )
                .padding(24)
            }
        } else {
            ContentUnavailableView(
                "未选择手势",
                systemImage: "hand.draw",
                description: Text("从左侧选择一个手势进行编辑")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Save bar

    private var saveBar: some View {
        HStack(spacing: 10) {
            if hasUnsavedChanges {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text("有未保存的更改")
                        .font(.mgMeta)
                        .foregroundStyle(.secondary)
                }
            } else if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.mgMeta)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("丢弃更改") { reloadFromStore() }
                .buttonStyle(.glass)
                .disabled(!hasUnsavedChanges)

            Button("保存", action: saveChanges)
                .buttonStyle(.glassProminent)
                .disabled(!hasUnsavedChanges)
                .keyboardShortcut(.return)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

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
        // Normalize names (trim, fallback to "未命名")
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

// MARK: - Gesture row

private struct GestureRow: View {
    let gesture: GestureCommand
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Trail thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.22) : Color.white.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                selected ? Color.white.opacity(0.30) : Color.mgBorder,
                                lineWidth: 1
                            )
                    )
                    .frame(width: 36, height: 36)

                if let template = gesture.templates.last {
                    GestureThumbnailView(
                        template: template,
                        color: selected ? .white.opacity(0.92) : Color.mgText2
                    )
                    .frame(width: 26, height: 26)
                } else {
                    Image(systemName: "questionmark")
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.mgText3)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(gesture.name)
                    .font(.mgBodyStrong)
                    .foregroundStyle(selected ? Color.white : Color.mgText1)
                Text("\(gesture.templates.count) 样本")
                    .font(.mgMeta)
                    .foregroundStyle(selected ? Color.white.opacity(0.72) : Color.mgText3)
            }

            Spacer()

            if let sc = gesture.shortcut {
                Kbd(keys: sc.kbdKeys, size: .sm, muted: true, inverted: selected)
            } else {
                Text("未设置")
                    .font(.mgMeta)
                    .foregroundStyle(selected ? Color.white.opacity(0.72) : Color.mgText3)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct GestureThumbnailView: View {
    let template: [StrokePoint]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let points = GestureTrailView.normalize(template, into: size, padding: 3)
            guard points.count >= 2 else { return }

            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )

            let previous = points[points.count - 2]
            let current = points[points.count - 1]
            let angle = atan2(current.y - previous.y, current.x - previous.x)
            var arrow = Path()
            arrow.move(to: current)
            arrow.addLine(to: CGPoint(x: current.x - 6, y: current.y - 4))
            arrow.addLine(to: CGPoint(x: current.x - 3, y: current.y))
            arrow.addLine(to: CGPoint(x: current.x - 6, y: current.y + 4))
            arrow.closeSubpath()
            context.translateBy(x: current.x, y: current.y)
            context.rotate(by: .radians(angle))
            context.translateBy(x: -current.x, y: -current.y)
            context.fill(arrow, with: .color(color))
        }
    }
}

// MARK: - Detail panel

private struct DetailPanel: View {
    let gesture: GestureCommand
    @Binding var editingName: String
    @Binding var shortcut: Shortcut?
    var onDelete: () -> Void
    var updateDraft: ((inout GestureCommand) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GESTURE")
                            .font(.mgLabelTiny)
                            .tracking(0.5)
                            .foregroundStyle(.tertiary)
                        TextField("手势名称", text: $editingName)
                            .textFieldStyle(.plain)
                            .font(.mgTitleL)
                            .onChange(of: editingName) { _, newVal in
                                updateDraft { $0.name = newVal }
                            }
                    }
                    Spacer(minLength: 12)
                    if let sc = gesture.shortcut {
                        Kbd(keys: sc.kbdKeys, size: .md)
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("删除", systemImage: "trash")
                    }
                    .buttonStyle(.glass)
                }
            }

            // Capture canvas (paint a new sample)
            VStack(alignment: .leading, spacing: 8) {
                MGSectionLabel(text: "录制新样本")
                GestureCaptureRepresentable(
                    templates: gesture.templates,
                    onStrokeFinished: { points in
                        updateDraft { $0.templates.append(points.map(StrokePoint.init)) }
                    }
                )
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: MGRadius.card, style: .continuous))

                HStack(spacing: 8) {
                    Button("撤销上一个") {
                        updateDraft { g in
                            if !g.templates.isEmpty { g.templates.removeLast() }
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(gesture.templates.isEmpty)

                    Button("清空样本") {
                        updateDraft { $0.templates.removeAll() }
                    }
                    .buttonStyle(.glass)
                    .disabled(gesture.templates.isEmpty)
                    Spacer()
                }
                Text("建议同一手势录制 2–3 个样本，识别会更稳。")
                    .font(.mgMeta)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Shortcut
            VStack(alignment: .leading, spacing: 8) {
                MGSectionLabel(text: "触发的快捷键")
                ShortcutRecorderRepresentable(shortcut: $shortcut)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous))
                    .onChange(of: shortcut) { _, newVal in
                        updateDraft { $0.shortcut = newVal }
                    }
            }
        }
    }
}
