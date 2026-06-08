import SwiftUI

struct TrackpadGesturePage: View {
    private let store = GestureStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    tag: "Trackpad Gestures",
                    title: "触控板手势",
                    subtitle: "把光标移到任意窗口的标题栏附近,用双指滑动来操作该窗口。"
                )

                GroupCard(radius: MGRadius.cardLg) {
                    TrackpadGestureToggleRow(
                        title: "启用触控板手势",
                        desc: "开启后,光标压在窗口顶部标题栏附近时双指滑动会被识别为窗口控制手势;其它位置滚动照常。",
                        isOn: Binding(
                            get: { store.preferences.trackpadGesturesEnabled },
                            set: { value in store.updatePreferences { $0.trackpadGesturesEnabled = value } }
                        )
                    )
                }

                GroupCard(radius: MGRadius.cardLg) {
                    VStack(spacing: 0) {
                        TrackpadGestureInfoRow(
                            icon: "arrow.up.to.line",
                            title: "双指上滑",
                            desc: "最大化窗口,填满屏幕可用区域。",
                            showDivider: false
                        )
                        TrackpadGestureInfoRow(
                            icon: "arrow.down.to.line",
                            title: "双指下滑",
                            desc: "最小化窗口,收进 Dock。",
                            showDivider: true
                        )
                        TrackpadGestureInfoRow(
                            icon: "arrow.left.to.line",
                            title: "双指左滑",
                            desc: "关闭窗口,等同点击红色关闭按钮。",
                            showDivider: true
                        )
                    }
                }

                GroupCard(radius: MGRadius.cardLg) {
                    TrackpadGestureToggleRow(
                        title: "调试日志",
                        desc: "记录每次手势的位移和动作判定,用于校准方向。日志写入 ~/Library/Logs/Velto/trackpad-gesture-debug.log。",
                        isOn: Binding(
                            get: { store.preferences.trackpadGestureDebugLoggingEnabled },
                            set: { value in store.updatePreferences { $0.trackpadGestureDebugLoggingEnabled = value } }
                        )
                    )
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TrackpadGestureToggleRow: View {
    let title: String
    let desc: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.mgLabelStrong)
                    .foregroundStyle(Color.mgText1)
                Text(desc)
                    .font(.mgMeta)
                    .foregroundStyle(Color.mgText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.mgAccent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct TrackpadGestureInfoRow: View {
    let icon: String
    let title: String
    let desc: String
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
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }
}
