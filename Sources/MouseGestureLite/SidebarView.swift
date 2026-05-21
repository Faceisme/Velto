import SwiftUI

struct SidebarView: View {
    @Binding var page: MGPage?
    private let store = GestureStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("功能")
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 6)
            navRow(.gestures, badge: store.gestures.count)
            navRow(.window)

            sectionLabel("偏好")
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 6)
            navRow(.general)

            Spacer()

            StatusCard().padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    @ViewBuilder
    private func navRow(_ p: MGPage, badge: Int? = nil) -> some View {
        Button {
            page = p
        } label: {
            HStack(spacing: 10) {
                Image(systemName: p.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(page == p ? Color.mgAccent : Color.mgText2)
                Text(p.label)
                    .font(.system(size: 13, weight: page == p ? .semibold : .regular))
                    .foregroundStyle(page == p ? Color.mgAccent : Color.mgText1)
                Spacer()
                if let b = badge, b > 0 {
                    Text("\(b)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(page == p ? Color.mgAccent.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }
}

// MARK: - Status card (bottom of sidebar)

struct StatusCard: View {
    private let store = GestureStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("手势监听")
                    .font(.mgBodyStrong)
                    .foregroundStyle(Color.mgText1)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { store.preferences.gesturesEnabled },
                    set: { v in store.updatePreferences { $0.gesturesEnabled = v } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.green)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(store.preferences.gesturesEnabled ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(store.preferences.gesturesEnabled ? "正在监听右键手势" : "已暂停")
                    .font(.mgMeta)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .liquidGlassCard(radius: MGRadius.card)
    }
}
