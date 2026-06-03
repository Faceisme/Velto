import SwiftUI

// MARK: - WindowManagementPage (v2)
//
// PageHeader + 单卡 (4 行) + 底部 BottomToolbar。
// 每行:40×40 ActionIcon + 标题/描述 + KeyCapSlot + 清除 按钮。
// 行间分隔线:0.5px, margin-left 78 (对齐文字开头, 不切到图标)。

struct WindowManagementPage: View {
    private let store = GestureStore.shared

    @State private var draftMove: UInt64 = 0
    @State private var draftResize: UInt64 = 0
    @State private var draftZoom: UInt64 = 0
    @State private var draftMaximize: Shortcut?
    @State private var didLoad = false
    @State private var statusMessage = ""

    private var hasUnsavedChanges: Bool {
        draftMove != store.preferences.windowMoveModifierFlags
            || draftResize != store.preferences.windowResizeModifierFlags
            || draftZoom != store.preferences.contentZoomModifierFlags
            || draftMaximize != store.preferences.windowMaximizeShortcut
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PageHeader(
                        tag: "Window Management",
                        title: "窗口管理",
                        subtitle: "按住修饰键 + 拖动鼠标即可移动或缩放当前窗口。"
                    )

                    // 模块总开关:即时生效,不走下面的"保存"。关掉则移动/缩放/滚轮缩放/
                    // 窗口快捷键全部停用,但不影响手势与鼠标控制(各模块开关已解耦)。
                    GroupCard(radius: MGRadius.cardLg) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("启用窗口管理")
                                    .font(.mgLabelStrong)
                                    .foregroundStyle(Color.mgText1)
                                Text("关闭后,移动/缩放窗口、滚轮缩放、窗口快捷键全部停用,不影响手势与鼠标控制。")
                                    .font(.mgMeta)
                                    .foregroundStyle(Color.mgText2)
                            }
                            Spacer(minLength: 12)
                            Toggle("", isOn: Binding(
                                get: { store.preferences.windowManagementEnabled },
                                set: { v in store.updatePreferences { $0.windowManagementEnabled = v } }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(.mgAccent)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }

                    GroupCard(radius: MGRadius.cardLg) {
                        VStack(spacing: 0) {
                            WindowRow(
                                icon: "arrow.up.and.down.and.arrow.left.and.right",
                                title: "移动窗口",
                                desc: "按住此键 + 移动鼠标 → 拖动当前窗口",
                                control: {
                                    AnyView(
                                        KeyCapSlot(minWidth: 80) {
                                            ModifierRecorderField(modifierFlagsRawValue: $draftMove)
                                        }
                                    )
                                },
                                onClear: { draftMove = 0 },
                                showDivider: false
                            )
                            WindowRow(
                                icon: "arrow.up.left.and.arrow.down.right",
                                title: "缩放窗口",
                                desc: "按住此键 + 移动鼠标 → 按光标所在边角缩放",
                                control: {
                                    AnyView(
                                        KeyCapSlot(minWidth: 80) {
                                            ModifierRecorderField(modifierFlagsRawValue: $draftResize)
                                        }
                                    )
                                },
                                onClear: { draftResize = 0 },
                                showDivider: true
                            )
                            WindowRow(
                                icon: "plus.magnifyingglass",
                                title: "滚轮缩放修饰键",
                                desc: "按住此键 + 滚动滚轮 → 缩放页面内容",
                                control: {
                                    AnyView(
                                        KeyCapSlot(minWidth: 80) {
                                            ModifierRecorderField(modifierFlagsRawValue: $draftZoom)
                                        }
                                    )
                                },
                                onClear: { draftZoom = 0 },
                                showDivider: true
                            )
                            WindowRow(
                                icon: "rectangle.expand.vertical",
                                title: "最大化快捷键",
                                desc: "按下此快捷键 → 光标下的窗口最大化",
                                control: {
                                    AnyView(
                                        KeyCapSlot(minWidth: 110) {
                                            ShortcutRecorderField(
                                                shortcut: $draftMaximize,
                                                placeholder: "点击录制"
                                            )
                                        }
                                    )
                                },
                                onClear: { draftMaximize = nil },
                                showDivider: true
                            )
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 28)
            }

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
            case .backupImport:
                reloadFromStore(silent: true)
            case .preferences:
                if !hasUnsavedChanges { reloadFromStore(silent: true) }
            default: break
            }
        }
    }

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

// MARK: - WindowRow

private struct WindowRow: View {
    let icon: String
    let title: String
    let desc: String
    let control: () -> AnyView
    let onClear: () -> Void
    let showDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showDivider {
                Rectangle()
                    .fill(Color.mgHair)
                    .frame(height: 0.5)
                    .padding(.leading, 78)
            }

            HStack(alignment: .center, spacing: 16) {
                ActionIcon(systemName: icon)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mgText1)
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mgText2)
                }

                Spacer(minLength: 12)

                control()

                Button("清除", action: onClear)
                    .buttonStyle(MGPlainButtonStyle(foreground: Color.mgText3))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }
}
