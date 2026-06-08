import SwiftUI

enum MGPage: String, CaseIterable, Identifiable, Hashable {
    case gestures, mouseControl, window, trackpadGesture, switcher, inputSourceSwitch, general

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gestures: "鼠标手势"
        case .mouseControl: "鼠标控制"
        case .window:   "窗口管理"
        case .trackpadGesture: "触控板手势"
        case .switcher: "窗口切换"
        case .inputSourceSwitch: "输入法切换"
        case .general:  "通用设置"
        }
    }

    var icon: String {
        switch self {
        case .gestures: "cursorarrow.motionlines"
        case .mouseControl: "computermouse"
        case .window:   "macwindow"
        case .trackpadGesture: "hand.draw"
        case .switcher: "rectangle.on.rectangle"
        case .inputSourceSwitch: "keyboard.badge.ellipsis"
        case .general:  "gearshape"
        }
    }
}

// MARK: - Root shell

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
        .background(Color.clear)
    }

    private var content: some View {
        let current = page ?? .gestures
        return ZStack {
            pageContent(.gestures, current: current) { GesturesPage() }
            pageContent(.mouseControl, current: current) { MouseControlPage() }
            pageContent(.window, current: current) { WindowManagementPage() }
            pageContent(.trackpadGesture, current: current) { TrackpadGesturePage() }
            pageContent(.switcher, current: current) { SwitcherSettingsPage() }
            pageContent(.inputSourceSwitch, current: current) { InputSourceSwitchPage() }
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
