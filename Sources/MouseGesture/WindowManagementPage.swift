import SwiftUI

struct WindowManagementPage: View {
    private let store = GestureStore.shared
    @State private var draftMove: UInt64 = 0
    @State private var draftResize: UInt64 = 0
    @State private var draftZoom: UInt64 = 0
    @State private var draftMaximize: Shortcut?
    @State private var didLoad = false
    @State private var statusMessage = ""

    var hasUnsavedChanges: Bool {
        draftMove != store.preferences.windowMoveModifierFlags
            || draftResize != store.preferences.windowResizeModifierFlags
            || draftZoom != store.preferences.contentZoomModifierFlags
            || draftMaximize != store.preferences.windowMaximizeShortcut
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    VStack(spacing: 4) {
                        KeybindCardModifier(
                            title: "移动窗口",
                            desc: "按住此键 + 移动鼠标 → 拖动当前窗口",
                            icon: "arrow.up.and.down.and.arrow.left.and.right",
                            flagsBinding: $draftMove
                        )
                        Divider().opacity(0.4).padding(.horizontal, 12)
                        KeybindCardModifier(
                            title: "缩放窗口",
                            desc: "按住此键 + 移动鼠标 → 按光标所在边角缩放",
                            icon: "arrow.up.left.and.arrow.down.right",
                            flagsBinding: $draftResize
                        )
                        Divider().opacity(0.4).padding(.horizontal, 12)
                        KeybindCardModifier(
                            title: "滚轮缩放修饰键",
                            desc: "按住此键 + 滚动滚轮 → 缩放页面内容",
                            icon: "plus.magnifyingglass",
                            flagsBinding: $draftZoom
                        )
                        Divider().opacity(0.4).padding(.horizontal, 12)
                        KeybindCardShortcut(
                            title: "最大化快捷键",
                            desc: "按下此快捷键 → 光标下的窗口最大化",
                            icon: "rectangle.expand.vertical",
                            shortcutBinding: $draftMaximize
                        )
                    }
                    .padding(8)
                    .liquidGlassCard(radius: MGRadius.card)
                }
                .padding(24)
            }

            Divider()
            saveBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: loadDraftIfNeeded)
        .onReceive(NotificationCenter.default.publisher(for: .gestureStoreDidChange)) { notification in
            guard notification.object as? GestureStore === store else { return }
            switch notification.gestureStoreChangeReason {
            case .backupImport:
                reloadFromStore(silent: true)
            case .preferences:
                if !hasUnsavedChanges {
                    reloadFromStore(silent: true)
                }
            default:
                break
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("WINDOW MANAGEMENT")
                .font(.mgLabelTiny)
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            Text("窗口管理")
                .font(.mgTitleL)
            Text("按住修饰键 + 拖动鼠标即可移动或缩放当前窗口。")
                .font(.mgBody)
                .foregroundStyle(.secondary)
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

    // MARK: - Lifecycle

    private func loadDraftIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        reloadFromStore(silent: true)
    }

    private func saveChanges() {
        store.updatePreferences { p in
            p.windowMoveModifierFlags = draftMove
            p.windowResizeModifierFlags = draftResize
            p.contentZoomModifierFlags = draftZoom
            p.windowMaximizeShortcut = draftMaximize
        }
        statusMessage = "已保存。"
    }

    private func reloadFromStore(silent: Bool = false) {
        let p = store.preferences
        draftMove = p.windowMoveModifierFlags
        draftResize = p.windowResizeModifierFlags
        draftZoom = p.contentZoomModifierFlags
        draftMaximize = p.windowMaximizeShortcut
        statusMessage = silent ? "" : "已丢弃未保存更改。"
    }
}

// MARK: - Shared row layout

private struct KeybindCardRow<Trailing: View>: View {
    var title: String
    var desc: String
    var icon: String
    @ViewBuilder var trailing: () -> Trailing
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.mgAccent)
                .frame(width: 38, height: 38)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.mgBodyStrong)
                Text(desc).font(.mgMeta).foregroundStyle(.secondary)
            }

            Spacer()

            trailing()

            Button("清除", action: onClear)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.system(size: 11.5))
        }
        .padding(12)
    }
}

// MARK: - Modifier card

private struct KeybindCardModifier: View {
    var title: String
    var desc: String
    var icon: String
    @Binding var flagsBinding: UInt64

    var body: some View {
        KeybindCardRow(title: title, desc: desc, icon: icon) {
            ModifierRecorderRepresentable(modifierFlagsRawValue: $flagsBinding)
                .frame(width: 180, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous))
        } onClear: {
            flagsBinding = 0
        }
    }
}

// MARK: - Shortcut card

private struct KeybindCardShortcut: View {
    var title: String
    var desc: String
    var icon: String
    @Binding var shortcutBinding: Shortcut?

    var body: some View {
        KeybindCardRow(title: title, desc: desc, icon: icon) {
            ShortcutRecorderRepresentable(shortcut: $shortcutBinding)
                .frame(width: 180, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous))
        } onClear: {
            shortcutBinding = nil
        }
    }
}
