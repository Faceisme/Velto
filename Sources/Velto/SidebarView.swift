import AppKit
import SwiftUI

// MARK: - SidebarView (v2)

struct SidebarView: View {
    @Binding var page: MGPage?
    private let store = GestureStore.shared

    var body: some View {
        ZStack {
            SettingsSidebarGlassView(
                cornerRadius: 0,
                tintColor: NSColor.windowBackgroundColor.withAlphaComponent(0.06),
                style: .regular
            )
            .ignoresSafeArea(.container, edges: [.top, .bottom, .leading])

            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 54)

                SidebarGroup(title: "功能") {
                    SidebarItem(
                        icon: MGPage.gestures.icon,
                        label: MGPage.gestures.label,
                        badge: store.gestures.count,
                        active: page == .gestures
                    ) { page = .gestures }

                    SidebarItem(
                        icon: MGPage.mouseControl.icon,
                        label: MGPage.mouseControl.label,
                        badge: nil,
                        active: page == .mouseControl
                    ) { page = .mouseControl }

                    SidebarItem(
                        icon: MGPage.window.icon,
                        label: MGPage.window.label,
                        badge: nil,
                        active: page == .window
                    ) { page = .window }

                    SidebarItem(
                        icon: MGPage.trackpadGesture.icon,
                        label: MGPage.trackpadGesture.label,
                        badge: nil,
                        active: page == .trackpadGesture
                    ) { page = .trackpadGesture }

                    SidebarItem(
                        icon: MGPage.switcher.icon,
                        label: MGPage.switcher.label,
                        badge: nil,
                        active: page == .switcher
                    ) { page = .switcher }

                    SidebarItem(
                        icon: MGPage.inputSourceSwitch.icon,
                        label: MGPage.inputSourceSwitch.label,
                        badge: nil,
                        active: page == .inputSourceSwitch
                    ) { page = .inputSourceSwitch }

                    SidebarItem(
                        icon: MGPage.keyRemap.icon,
                        label: MGPage.keyRemap.label,
                        badge: nil,
                        active: page == .keyRemap
                    ) { page = .keyRemap }

                    SidebarItem(
                        icon: MGPage.betterFinder.icon,
                        label: MGPage.betterFinder.label,
                        badge: nil,
                        active: page == .betterFinder
                    ) { page = .betterFinder }

                    SidebarItem(
                        icon: MGPage.screenshot.icon,
                        label: MGPage.screenshot.label,
                        badge: nil,
                        active: page == .screenshot
                    ) { page = .screenshot }
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

                Text(Self.appVersionLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mgText3)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: [.top, .bottom, .leading])
    }

    /// 侧栏底部版本号:取自 bundle 的 CFBundleShortVersionString(打包脚本按"年.月.第几次"盖入)。
    private static let appVersionLabel: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "Velto \(version)"
    }()
}

private struct SettingsSidebarGlassView: NSViewRepresentable {
    var cornerRadius: CGFloat
    var tintColor: NSColor?
    var style: NSGlassEffectView.Style = .regular

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = cornerRadius
        view.tintColor = tintColor
        view.style = style
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.tintColor = tintColor
        nsView.style = style
    }
}

// MARK: - SidebarGroup

private struct SidebarGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.mgText3)
                .padding(.horizontal, 12)
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
    @State private var isHovered = false

    var body: some View {
        Button {
            guard !active else { return }
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: active ? .semibold : .regular))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(active ? Color.white : Color.mgText2)

                Text(label)
                    .font(.system(size: 14, weight: active ? .semibold : .regular))
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
                                .fill(active ? Color.white.opacity(0.22) : Color.mgHair)
                        )
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                sidebarItemBackground
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(MouseDownButtonStyle())
        .onHover { isHovered = $0 }
        .transaction { $0.animation = nil }
    }

    /// 侧栏导航在鼠标"按下"即触发(与 AppKit 源列表选中行为一致);
    /// 默认 Button 要等抬起才触发,是"不跟手"感的主要来源。
    private struct MouseDownButtonStyle: PrimitiveButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            MouseDownButton(configuration: configuration)
        }

        private struct MouseDownButton: View {
            let configuration: Configuration
            @State private var fired = false

            var body: some View {
                configuration.label
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !fired else { return }
                                fired = true
                                configuration.trigger()
                            }
                            .onEnded { _ in fired = false }
                    )
            }
        }
    }

    @ViewBuilder
    private var sidebarItemBackground: some View {
        let shape = RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)

        if active {
            Color.clear
                .glassEffect(.regular.tint(Color.mgAccent.opacity(0.85)), in: shape)
        } else if isHovered {
            shape
                .fill(Color.white.opacity(0.08))
        } else {
            Color.clear
        }
    }
}

