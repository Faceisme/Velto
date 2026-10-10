import AppKit
import SwiftUI

// MARK: - SidebarView (v2)

struct SidebarView: View {
    @Binding var page: MGPage?

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
                    ForEach(MGPage.allCases.filter { $0 != .general }) { item in
                        SidebarItem(page: item, active: page == item) { page = item }
                    }
                }

                Spacer().frame(height: 14)

                SidebarGroup(title: "偏好") {
                    SidebarItem(page: .general, active: page == .general) { page = .general }
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
    let page: MGPage
    let active: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            guard !active else { return }
            action()
        } label: {
            HStack(spacing: 10) {
                ModuleIcon(page: page)

                Text(page.label)
                    .font(.system(size: 14, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.white : Color.mgText1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
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

