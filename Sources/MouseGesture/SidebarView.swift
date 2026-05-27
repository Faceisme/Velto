import SwiftUI

// MARK: - SidebarView (v2)
//
// 220px wide. 背景 #ECECEE.
//  - 两个分组:"功能" / "偏好"
//  - SidebarItem: 圆角 8 / 内 7×10 / 选中 #0A84FF 白字 / badge 22% 白透明底
//  - 底部贴住一张 StatusCard

struct SidebarView: View {
    @Binding var page: MGPage?
    private let store = GestureStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部留出标题栏空间(transparent titlebar)
            Spacer().frame(height: 40)

            SidebarGroup(title: "功能") {
                SidebarItem(
                    icon: MGPage.gestures.icon,
                    label: MGPage.gestures.label,
                    badge: store.gestures.count,
                    active: page == .gestures
                ) { page = .gestures }

                SidebarItem(
                    icon: MGPage.window.icon,
                    label: MGPage.window.label,
                    badge: nil,
                    active: page == .window
                ) { page = .window }

                SidebarItem(
                    icon: MGPage.switcher.icon,
                    label: MGPage.switcher.label,
                    badge: nil,
                    active: page == .switcher
                ) { page = .switcher }
            }

            Spacer().frame(height: 14)

            SidebarGroup(title: "偏好") {
                SidebarItem(
                    icon: MGPage.general.icon,
                    label: MGPage.general.label,
                    badge: nil,
                    active: page == .general
                ) { page = .general }
            }

            Spacer()

            StatusCard()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.mgSidebar)
    }
}

// MARK: - SidebarGroup

private struct SidebarGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.mgSubLabel)
                .foregroundStyle(Color.mgText3)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
            content()
        }
    }
}

// MARK: - SidebarItem

private struct SidebarItem: View {
    let icon: String
    let label: String
    let badge: Int?
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button {
            guard !active else { return }
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(active ? Color.white : Color.mgText2)

                Text(label)
                    .font(.system(size: 15, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Color.white : Color.mgText1)

                Spacer(minLength: 0)

                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(active ? Color.white : Color.mgText2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(active
                                      ? Color.white.opacity(0.22)
                                      : Color(red: 15/255, green: 30/255, blue: 60/255).opacity(0.06))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Color.mgAccent : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transaction { $0.animation = nil }
    }
}

// MARK: - StatusCard (sidebar 底部)
//
// 白底卡 + 圆角 10
// 顶行:"手势监听" + 绿色 Toggle
// 底行:6pt 绿色圆点(带 3pt 光晕) + 11.5pt 灰色 "正在监听右键手势"

struct StatusCard: View {
    private let store = GestureStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("手势监听")
                    .font(.mgLabelStrong)
                    .foregroundStyle(Color.mgText1)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { store.preferences.gesturesEnabled },
                    set: { v in store.updatePreferences { $0.gesturesEnabled = v } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.mgGreen)
            }

            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(store.preferences.gesturesEnabled
                              ? Color.mgGreen.opacity(0.18)
                              : Color.orange.opacity(0.18))
                        .frame(width: 12, height: 12)
                    Circle()
                        .fill(store.preferences.gesturesEnabled ? Color.mgGreen : .orange)
                        .frame(width: 6, height: 6)
                }
                Text(store.preferences.gesturesEnabled ? "正在监听右键手势" : "已暂停")
                    .font(.mgMeta)
                    .foregroundStyle(Color.mgText2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.mgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.mgHair, lineWidth: 0.5)
        )
        .shadow(color: Color(red: 15/255, green: 30/255, blue: 60/255).opacity(0.04),
                radius: 1, x: 0, y: 1)
    }
}
