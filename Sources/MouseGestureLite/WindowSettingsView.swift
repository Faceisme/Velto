import SwiftUI

struct WindowSettingsView: View {
    private let store = GestureStore.shared

    var body: some View {
        ScrollView {
            Form {
                Section {
                    LabeledContent("移动窗口") {
                        HStack(spacing: 8) {
                            ModifierRecorderRepresentable(modifierFlagsRawValue: Binding(
                                get: { store.preferences.windowMoveModifierFlags },
                                set: { v in store.updatePreferences { $0.windowMoveModifierFlags = v } }
                            ))
                            .frame(width: 200, height: 38)
                            Button("清除") {
                                store.updatePreferences { $0.windowMoveModifierFlags = 0 }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    LabeledContent("缩放窗口") {
                        HStack(spacing: 8) {
                            ModifierRecorderRepresentable(modifierFlagsRawValue: Binding(
                                get: { store.preferences.windowResizeModifierFlags },
                                set: { v in store.updatePreferences { $0.windowResizeModifierFlags = v } }
                            ))
                            .frame(width: 200, height: 38)
                            Button("清除") {
                                store.updatePreferences { $0.windowResizeModifierFlags = 0 }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("拖动窗口")
                } footer: {
                    Text("按住修饰键并移动鼠标：移动窗口；按住缩放修饰键并移动鼠标：按光标所在边角缩放窗口。")
                }

                Section {
                    LabeledContent("滚轮缩放修饰键") {
                        HStack(spacing: 8) {
                            ModifierRecorderRepresentable(modifierFlagsRawValue: Binding(
                                get: { store.preferences.contentZoomModifierFlags },
                                set: { v in store.updatePreferences { $0.contentZoomModifierFlags = v } }
                            ))
                            .frame(width: 200, height: 38)
                            Button("清除") {
                                store.updatePreferences { $0.contentZoomModifierFlags = 0 }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("内容缩放")
                } footer: {
                    Text("按住修饰键滚动鼠标滚轮，对网页、图片等内容发送通用缩放快捷键。")
                }

                Section {
                    LabeledContent("最大化快捷键") {
                        HStack(spacing: 8) {
                            ShortcutRecorderRepresentable(shortcut: Binding(
                                get: { store.preferences.windowMaximizeShortcut },
                                set: { v in store.updatePreferences { $0.windowMaximizeShortcut = v } }
                            ))
                            .frame(width: 200, height: 38)
                            Button("清除") {
                                store.updatePreferences { $0.windowMaximizeShortcut = nil }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("窗口最大化")
                } footer: {
                    Text("按下快捷键，将光标下方的窗口最大化到当前屏幕可用区域。")
                }
            }
            .formStyle(.grouped)
        }
    }
}
