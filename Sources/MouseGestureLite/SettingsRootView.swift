import SwiftUI

enum MGPage: String, CaseIterable, Identifiable, Hashable {
    case gestures, window, general

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gestures: "鼠标手势"
        case .window: "窗口管理"
        case .general: "通用设置"
        }
    }

    var icon: String {
        switch self {
        case .gestures: "cursorarrow.motionlines"
        case .window: "macwindow"
        case .general: "gearshape"
        }
    }
}

struct SettingsRootView: View {
    @State private var page: MGPage? = .gestures
    private let store = GestureStore.shared

    var body: some View {
        NavigationSplitView {
            SidebarView(page: $page)
                .navigationSplitViewColumnWidth(240)
        } detail: {
            content
        }
        .frame(minWidth: 1100, idealWidth: 1180, minHeight: 720, idealHeight: 760)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ToolbarStatusIndicator(listening: store.preferences.gesturesEnabled)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page ?? .gestures {
        case .gestures:
            GesturesPage()
        case .window:
            WindowManagementPage()
        case .general:
            GeneralSettingsPage()
        }
    }
}
