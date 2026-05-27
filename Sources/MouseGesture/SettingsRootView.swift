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
        }
        .frame(minWidth: 1100, idealWidth: 1280, minHeight: 720, idealHeight: 800)
        .background(Color.mgSidebar) // 在 hidden titlebar 区域露出
    }

    @ViewBuilder
    private var content: some View {
        switch page ?? .gestures {
        case .gestures: GesturesPage()
        case .window:   WindowManagementPage()
        case .switcher: SwitcherSettingsPage()
        case .general:  GeneralSettingsPage()
        }
    }
}
