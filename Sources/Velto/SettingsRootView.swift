import SwiftUI

enum MGPage: String, CaseIterable, Identifiable, Hashable {
    case gestures, window, switcher, general

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gestures: "鼠标手势"
        case .window:   "窗口管理"
        case .switcher: "窗口切换"
        case .general:  "通用设置"
        }
    }

    var icon: String {
        switch self {
        case .gestures: "cursorarrow.motionlines"
        case .window:   "macwindow"
        case .switcher: "rectangle.on.rectangle"
        case .general:  "gearshape"
        }
    }
}

// MARK: - Root shell
//
// 自定义 HSplit:左侧 SidebarView 220 宽 + 右侧 main 区。
// 不用 NavigationSplitView,因为它带 sidebar material/vibrancy 和系统插画,
// 会破坏 v2 的 flat #ECECEE / #F5F5F7 配色。

struct SettingsRootView: View {
    @State private var page: MGPage? = .gestures

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(page: $page)
                .frame(width: 220)

            // 主区域:背景 #F5F5F7
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.mgBg)
                .transaction { $0.animation = nil }
        }
        .frame(minWidth: 1100, idealWidth: 1280, minHeight: 720, idealHeight: 800)
        .background(Color.mgSidebar) // 在 hidden titlebar 区域露出
    }

    private var content: some View {
        let current = page ?? .gestures
        return ZStack {
            pageContent(.gestures, current: current) { GesturesPage() }
            pageContent(.window, current: current) { WindowManagementPage() }
            pageContent(.switcher, current: current) { SwitcherSettingsPage() }
            pageContent(.general, current: current) { GeneralSettingsPage() }
        }
    }

    private func pageContent<Content: View>(
        _ target: MGPage,
        current: MGPage,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .opacity(current == target ? 1 : 0)
            .allowsHitTesting(current == target)
            .accessibilityHidden(current != target)
            .zIndex(current == target ? 1 : 0)
    }
}
