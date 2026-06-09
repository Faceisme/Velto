import AppKit
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
        return SettingsPageHost(page: current)
    }
}

private struct SettingsPageHost: NSViewControllerRepresentable {
    var page: MGPage

    func makeNSViewController(context: Context) -> SettingsPageHostController {
        let controller = SettingsPageHostController()
        controller.setPage(page)
        return controller
    }

    func updateNSViewController(_ controller: SettingsPageHostController, context: Context) {
        controller.setPage(page)
    }
}

private final class SettingsPageHostController: NSViewController {
    private var controllers: [MGPage: NSViewController] = [:]
    private var currentPage: MGPage?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        view = root
    }

    func setPage(_ page: MGPage) {
        guard page != currentPage else { return }

        if let currentPage, let currentController = controllers[currentPage] {
            currentController.view.removeFromSuperview()
            currentController.removeFromParent()
        }

        let controller = cachedController(for: page)
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        currentPage = page
    }

    private func cachedController(for page: MGPage) -> NSViewController {
        if let controller = controllers[page] {
            return controller
        }

        let controller = NSHostingController(
            rootView: Self.rootView(for: page)
                .transaction { $0.animation = nil }
        )
        controllers[page] = controller
        return controller
    }

    private static func rootView(for page: MGPage) -> AnyView {
        switch page {
        case .gestures:
            AnyView(GesturesPage())
        case .mouseControl:
            AnyView(MouseControlPage())
        case .window:
            AnyView(WindowManagementPage())
        case .trackpadGesture:
            AnyView(TrackpadGesturePage())
        case .switcher:
            AnyView(SwitcherSettingsPage())
        case .inputSourceSwitch:
            AnyView(InputSourceSwitchPage())
        case .general:
            AnyView(GeneralSettingsPage())
        }
    }
}
