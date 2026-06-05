import SwiftUI

/// 窗口切换器的设置页。承载在侧边栏"窗口切换"入口下。
///
/// 跟 WindowManagementPage 的 save/discard 模式不同 —— 这里字段太多(~12 项),
/// 每项都走 draft + 比对会写一大堆样板。直接**live save**:改一项立刻 commit
/// 进 store,UI 自然响应。代价是没有"预览未保存改动"的功能,但这里也没人需要。
struct SwitcherSettingsPage: View {
    private let store = GestureStore.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PageHeader(
                        tag: "Window Switcher",
                        title: "窗口切换",
                        subtitle: "类似 Win11 风格的窗口切换器,按快捷键呼出,带实时缩略图。"
                    )

                    triggerGroup
                    filtersGroup
                    sortingAndAppearanceGroup
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 1. 启用 + 触发 + 屏幕

    private var triggerGroup: some View {
        GroupCard(radius: MGRadius.cardLg) {
            VStack(spacing: 0) {
                row(
                    icon: "power",
                    title: "启用窗口切换器",
                    desc: "关闭后 ⌘+Tab 会还给 macOS 系统原生切换器。",
                    showDivider: false
                ) {
                    AnyView(
                        Toggle("", isOn: bind(\.enabled))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(.mgAccent)
                    )
                }

                row(
                    icon: "keyboard",
                    title: "触发快捷键",
                    desc: "默认 ⌘+Tab。改完立即生效。按住组合键不放可循环选择,松开切换。",
                    showDivider: true
                ) {
                    AnyView(
                        KeyCapSlot(minWidth: 110) {
                            ShortcutRecorderField(
                                shortcut: Binding(
                                    get: { store.preferences.switcher.triggerShortcut },
                                    set: { newValue in
                                        // 触发键必须含真 modifier(⌘/⌃/⌥)。裸键 / 仅 Shift 的录入
                                        // 直接忽略(保留旧值);清空(nil)允许 —— 会回退默认 ⌘+Tab。
                                        if let s = newValue, !s.hasRealModifier { return }
                                        store.updatePreferences { $0.switcher.triggerShortcut = newValue }
                                    }
                                ),
                                placeholder: "点击录制"
                            )
                        }
                    )
                }

                row(
                    icon: "display",
                    title: "显示于",
                    desc: "切换器面板出现在哪块屏幕。",
                    showDivider: true
                ) {
                    AnyView(menuPicker(\.showOnScreen))
                }

                row(
                    icon: "ladybug",
                    title: "调试日志",
                    desc: "排查切换器问题时打开,只写 switcher-debug.log,不影响其它模块。平时保持关闭。",
                    showDivider: true
                ) {
                    AnyView(
                        Toggle("", isOn: bind(\.debugLoggingEnabled))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(.mgAccent)
                    )
                }
            }
        }
    }

    // MARK: - 2. 筛选

    private var filtersGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("筛选")
            GroupCard(radius: MGRadius.cardLg) {
                VStack(spacing: 0) {
                    row(
                        icon: "app.dashed",
                        title: "显示来自应用的窗口",
                        desc: nil,
                        showDivider: false
                    ) {
                        AnyView(menuPicker(\.appsToShow))
                    }
                    row(
                        icon: "macwindow.on.rectangle",
                        title: "显示来自桌面的窗口",
                        desc: nil,
                        showDivider: true
                    ) {
                        AnyView(menuPicker(\.spacesToShow))
                    }
                    row(
                        icon: "display.2",
                        title: "显示来自屏幕的窗口",
                        desc: nil,
                        showDivider: true
                    ) {
                        AnyView(menuPicker(\.screensToShow))
                    }
                    row(
                        icon: "arrow.down.right.and.arrow.up.left",
                        title: "显示最小化窗口",
                        desc: nil,
                        showDivider: true
                    ) {
                        AnyView(menuPicker(\.minimizedWindows))
                    }
                    row(
                        icon: "eye.slash",
                        title: "显示隐藏窗口",
                        desc: "用 ⌘H 隐藏的应用的窗口。",
                        showDivider: true
                    ) {
                        AnyView(menuPicker(\.hiddenWindows))
                    }
                    row(
                        icon: "rectangle.fill.on.rectangle.fill",
                        title: "显示全屏窗口",
                        desc: nil,
                        showDivider: true
                    ) {
                        AnyView(menuPicker(\.fullscreenWindows))
                    }
                    row(
                        icon: "app.badge",
                        title: "显示没有打开窗口的应用",
                        desc: nil,
                        showDivider: true
                    ) {
                        AnyView(menuPicker(\.windowlessApps))
                    }
                }
            }
        }
    }

    // MARK: - 3. 排序与外观

    private var sortingAndAppearanceGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("排序与外观")
            GroupCard(radius: MGRadius.cardLg) {
                VStack(spacing: 0) {
                    row(
                        icon: "square.stack.3d.up",
                        title: "分组方式",
                        desc: "按窗口 = 每个窗口/标签一个条目;按应用 = 每个应用只保留一个(MRU 代表),终端/Chrome 标签多时更清爽。",
                        showDivider: false
                    ) {
                        AnyView(menuPicker(\.groupBy))
                    }
                    row(
                        icon: "arrow.up.arrow.down",
                        title: "排序",
                        desc: "窗口在切换器里的排列顺序。",
                        showDivider: true
                    ) {
                        AnyView(menuPicker(\.sortBy))
                    }
                    row(
                        icon: "rectangle.grid.2x2",
                        title: "外观",
                        desc: "缩略图 = Win11 风格;仅图标 = macOS 原生 ⌘+Tab 风格。",
                        showDivider: true
                    ) {
                        AnyView(menuPicker(\.appearanceStyle))
                    }
                }
            }
        }
    }

    // MARK: - 公用 row 组件

    /// 一行设置 —— 跟 WindowManagementPage.WindowRow 一致的视觉。
    private func row(
        icon: String,
        title: String,
        desc: String?,
        showDivider: Bool,
        @ViewBuilder control: () -> AnyView
    ) -> some View {
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
                    if let desc {
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mgText2)
                    }
                }
                Spacer(minLength: 12)
                control()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.mgSubLabel)
            .foregroundStyle(Color.mgText3)
            .padding(.leading, 4)
    }

    // MARK: - 通用枚举下拉组件

    /// 给一个枚举 KeyPath,自动渲染一个 Menu-style Picker。
    /// 要求枚举 conform `CaseIterable & Equatable & RawRepresentable`,且有
    /// `displayName: String` —— 我们 SwitcherPreferences 里所有枚举都满足。
    private func menuPicker<E>(
        _ keyPath: WritableKeyPath<SwitcherPreferences, E>
    ) -> some View where E: CaseIterable & Hashable & RawRepresentable, E.AllCases: RandomAccessCollection, E.RawValue: Hashable {
        MGMenuPicker(
            selection: bind(keyPath),
            options: Array(E.allCases).map { MGMenuOption($0, displayName(of: $0)) },
            minWidth: 160
        )
    }

    /// 给 menuPicker 用 —— Swift 泛型没法把"任意自带 displayName 的枚举"约束
    /// 成一个 protocol(displayName 是 computed property,反射看不到),所以
    /// 这里手动 switch by type。新增 SwitcherPreferences 字段时记得加一行。
    private func displayName<E>(of value: E) -> String {
        if let v = value as? SwitcherShowMode { return v.displayName }
        if let v = value as? SwitcherAppsScope { return v.displayName }
        if let v = value as? SwitcherSpacesScope { return v.displayName }
        if let v = value as? SwitcherScreensScope { return v.displayName }
        if let v = value as? SwitcherSortOrder { return v.displayName }
        if let v = value as? SwitcherGroupingMode { return v.displayName }
        if let v = value as? SwitcherScreenChoice { return v.displayName }
        if let v = value as? SwitcherAppearanceStyle { return v.displayName }
        return String(describing: value)
    }

    // MARK: - Live binding helper

    /// 把 store.preferences.switcher 上的一个 KeyPath 包成 SwiftUI Binding,
    /// 设值时自动跑 store.updatePreferences(把持久化和通知一并搞定)。
    private func bind<V>(_ keyPath: WritableKeyPath<SwitcherPreferences, V>) -> Binding<V> {
        Binding(
            get: { store.preferences.switcher[keyPath: keyPath] },
            set: { newValue in
                store.updatePreferences { prefs in
                    prefs.switcher[keyPath: keyPath] = newValue
                }
            }
        )
    }
}
