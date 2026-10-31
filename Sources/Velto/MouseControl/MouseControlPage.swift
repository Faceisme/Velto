import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 鼠标控制设置页。改动即时保存;拉条松手才写入。
struct MouseControlPage: View {
    private let store = ConfigStore.shared

    /// 指针速度是系统设置,不进偏好:拖动即写入系统,所以单独存一份。
    @State private var pointerSpeed = 0.0

    private var prefs: Binding<MouseControlPreferences> {
        Binding(
            get: { store.preferences.mouseControl },
            set: { newValue in store.updatePreferences { $0.mouseControl = newValue } }
        )
    }

    private var pointerSpeedBinding: Binding<Double> {
        Binding(
            get: { pointerSpeed },
            set: { newValue in
                let speed = MousePointerSpeed.quantized(newValue)
                // 拖动时同一档位会连发多次,只在跨档时写系统。
                guard speed != pointerSpeed else { return }
                pointerSpeed = speed
                MousePointerSpeed.apply(speed)
            }
        )
    }

    var body: some View {
        SettingsPage {
            PageHeader(
                page: .mouseControl,
                subtitle: "指针速度、平滑滚动、轴向反转、滚动功能键、按应用覆盖和按钮绑定。",
                isOn: prefs.enabled
            )
            .help("关闭后滚动平滑、滚动功能键和按钮绑定都不生效;指针速度不受影响。")

            SettingsSection("指针") {
                SettingsRow(title: "移动速度", subtitle: "系统鼠标跟踪速度,可超过系统设置的上限 3.0") {
                    MouseSliderStepperField(
                        value: pointerSpeedBinding,
                        range: MousePointerSpeed.range,
                        step: MousePointerSpeed.step,
                        format: "%.1f",
                        commitsOnRelease: false
                    )
                }
                .help("拖动即时生效;只影响鼠标,不影响触控板,也不受总开关影响。")
            }

            SettingsSection("滚动") {
                MouseScrollProfileEditor(profile: prefs.scroll)
            }

            SettingsSection("滚动功能键") {
                MouseHotkeysEditor(hotkeys: prefs.hotkeys)
            }

            SettingsSection("按钮绑定") {
                MouseBindingRows(bindings: prefs.buttonBindings)
            } accessory: {
                addBindingButton(prefs.buttonBindings)
            }

            MouseAppRulesSections(preferences: prefs)

            DebugSection(
                isOn: prefs.debugLoggingEnabled,
                logURL: MouseScrollDebugLogger.fileURL,
                help: "记录每个滚轮事件的平滑计算过程,只在排查滚动手感时打开;每次打开会清空上一次的日志。"
            )
        }
        .onAppear {
            // 每次进页面都重读:用户可能刚在系统设置里改过跟踪速度。
            pointerSpeed = MousePointerSpeed.current()
        }
    }
}

/// 平滑 / 反向的四档。数据结构不变:映射到总开关 + 两个轴开关。
private enum MouseAxisMode: CaseIterable {
    case off, vertical, horizontal, both

    var label: String {
        switch self {
        case .off: "关"
        case .vertical: "仅垂直"
        case .horizontal: "仅水平"
        case .both: "双向"
        }
    }
}

/// 一套滚动参数的各行,全局和按应用覆盖共用。
private struct MouseScrollProfileEditor: View {
    @Binding var profile: MouseScrollProfile

    /// 步长 / 增益 / 尾迹 / 模拟触控板只作用于平滑后的合成滚动。
    private var smoothOn: Bool {
        profile.smooth && (profile.smoothVertical || profile.smoothHorizontal)
    }

    var body: some View {
        SettingsRow(title: "平滑滚动") {
            axisPicker(\.smooth, \.smoothVertical, \.smoothHorizontal)
        }
        SettingsRow(title: "反向滚动") {
            axisPicker(\.reverse, \.reverseVertical, \.reverseHorizontal)
        }
        Group {
            SettingsRow(title: "最短步长", subtitle: "滚轮增量太小时会提升到此值") {
                MouseSliderStepperField(value: $profile.minStep, range: 1.0...120.0, step: 0.1, format: "%.1f")
            }
            SettingsRow(title: "速度增益") {
                MouseSliderStepperField(value: $profile.speedGain, range: 0.2...8.0, step: 0.1, format: "%.1f")
            }
            SettingsRow(title: "尾迹长度", subtitle: "越大缓动越久、尾迹越长(相对值,非秒)") {
                MouseSliderStepperField(value: $profile.duration, range: 0.5...5.0, step: 0.05, format: "%.2f")
            }
            SettingsRow("模拟触控板模式", subtitle: "为合成滚动补充连续滚动标记", isOn: $profile.simulateTrackpad)
        }
        .disabled(!smoothOn)
    }

    /// 两个轴都关也显示为「关」,菜单里就没有"总开关开着却不生效"的组合。
    private func axisPicker(
        _ master: WritableKeyPath<MouseScrollProfile, Bool>,
        _ vertical: WritableKeyPath<MouseScrollProfile, Bool>,
        _ horizontal: WritableKeyPath<MouseScrollProfile, Bool>
    ) -> some View {
        MGMenuPicker(
            selection: Binding(
                get: {
                    guard profile[keyPath: master] else { return MouseAxisMode.off }
                    switch (profile[keyPath: vertical], profile[keyPath: horizontal]) {
                    case (true, true): return .both
                    case (true, false): return .vertical
                    case (false, true): return .horizontal
                    case (false, false): return .off
                    }
                },
                set: { mode in
                    // 拷一份改完再整体写回:逐字段写会连着落盘好几次。
                    var p = profile
                    p[keyPath: master] = mode != .off
                    if mode != .off {
                        p[keyPath: vertical] = mode != .horizontal
                        p[keyPath: horizontal] = mode != .vertical
                    }
                    profile = p
                }
            ),
            options: MouseAxisMode.allCases.map { MGMenuOption($0, $0.label) }
        )
    }
}

/// 拉条 + 数字框。拉条默认松手才写回:每次写回都会整份偏好落盘。
private struct MouseSliderStepperField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var format: String
    var commitsOnRelease = true
    /// 拖动中的值,非 nil 即正在拖。
    @State private var dragValue: Double?

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: sliderValue, in: range, onEditingChanged: { editing in
                guard commitsOnRelease else { return }
                if editing {
                    dragValue = value
                } else {
                    if let dragValue, dragValue != value { value = dragValue }
                    dragValue = nil
                }
            })
            .frame(width: 220)
            .frame(height: 22)

            MGStepperField(
                value: Binding(get: { dragValue ?? value }, set: { value = $0 }),
                range: range,
                step: step,
                format: format
            )
            .frame(width: 96)
        }
        .frame(width: 328)
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { min(max(dragValue ?? value, range.lowerBound), range.upperBound) },
            set: { newValue in
                let stepped = min(max((newValue / step).rounded() * step, range.lowerBound), range.upperBound)
                if dragValue != nil { dragValue = stepped } else { value = stepped }
            }
        )
    }
}

/// 三个滚动功能键的行,全局和按应用覆盖共用。
private struct MouseHotkeysEditor: View {
    @Binding var hotkeys: MouseScrollHotkeys

    var body: some View {
        hotkeyRow("加速滚动", "按住时提高滚动速度", $hotkeys.acceleration)
        hotkeyRow("方向转换", "按住时将垂直滚动转为水平滚动", $hotkeys.directionToggle)
        hotkeyRow("禁用平滑", "按住时临时透传普通滚轮事件", $hotkeys.disableSmooth)
    }

    private func hotkeyRow(_ title: String, _ subtitle: String, _ trigger: Binding<MouseInputTrigger?>) -> some View {
        SettingsRow(title: title, subtitle: subtitle) {
            ShortcutField(hasValue: trigger.wrappedValue != nil, clear: { trigger.wrappedValue = nil }) {
                MouseInputRecorderField(trigger: trigger)
            }
        }
    }
}

/// 分组标题右侧的「+ 添加绑定」。
private func addBindingButton(_ bindings: Binding<[MouseButtonBinding]>) -> some View {
    Button("添加绑定", systemImage: "plus") {
        bindings.wrappedValue.append(
            MouseButtonBinding(
                name: "新绑定",
                trigger: MouseInputTrigger(kind: .mouse, code: 3, displayName: "侧键1"),
                action: .system(.missionControl)
            )
        )
    }
    .buttonStyle(.bordered)
}

/// 按钮绑定的各行,全局和按应用覆盖共用。
private struct MouseBindingRows: View {
    @Binding var bindings: [MouseButtonBinding]

    var body: some View {
        if bindings.isEmpty {
            EmptyRow("暂无按钮绑定。")
        }
        // 按元素 id 遍历 / 删除:索引式 ForEach 在删除时会越界且动画错乱。
        ForEach($bindings) { $binding in
            MouseBindingRow(binding: $binding) {
                bindings.removeAll { $0.id == binding.id }
            }
        }
    }
}

private enum MouseActionKind: String, CaseIterable, Identifiable {
    case system
    case shortcut
    case openApplication
    case openFile
    case runScript

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "系统动作"
        case .shortcut: "快捷键"
        case .openApplication: "打开 App"
        case .openFile: "打开文件"
        case .runScript: "运行脚本"
        }
    }

    init(action: MouseButtonAction) {
        switch action {
        case .system: self = .system
        case .shortcut: self = .shortcut
        case .openApplication: self = .openApplication
        case .openFile: self = .openFile
        case .runScript: self = .runScript
        }
    }

    func actionKeepingPayload(from current: MouseButtonAction) -> MouseButtonAction {
        switch self {
        case .system:
            if case .system = current { return current }
            return .system(.missionControl)
        case .shortcut:
            if case .shortcut = current { return current }
            return .shortcut(Shortcut(keyCode: VirtualKeyCode.w, modifierFlags: CGEventFlags.maskCommand.storedRawValue, displayName: "⌘W"))
        case .openApplication:
            if case .openApplication = current { return current }
            return .openApplication(path: "/Applications/Safari.app", bundleIdentifier: "com.apple.Safari")
        case .openFile:
            if case .openFile = current { return current }
            return .openFile(path: NSHomeDirectory())
        case .runScript:
            if case .runScript = current { return current }
            return .runScript("")
        }
    }
}

/// 一条绑定:第一行名称 / 删除 / 开关,第二行「触发 → 动作」。
private struct MouseBindingRow: View {
    @Binding var binding: MouseButtonBinding
    let onDelete: () -> Void

    private var actionKind: Binding<MouseActionKind> {
        Binding(
            get: { MouseActionKind(action: binding.action) },
            set: { kind in binding.action = kind.actionKeepingPayload(from: binding.action) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("绑定名称", text: $binding.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Spacer(minLength: 8)
                DeleteIconButton(action: onDelete)
                SettingsSwitch(isOn: $binding.isEnabled)
            }

            HStack(spacing: 8) {
                // 触发键必填,不给清除。
                ShortcutField(hasValue: false, clear: {}) {
                    MouseInputRecorderField(trigger: requiredTriggerBinding, allowsModifierOnly: false)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(Color.mgText3)
                MGMenuPicker(
                    selection: actionKind,
                    options: MouseActionKind.allCases.map { MGMenuOption($0, $0.label) },
                    minWidth: 112
                )
                actionEditor
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var actionEditor: some View {
        switch binding.action {
        case .system:
            MGMenuPicker(
                selection: systemActionBinding,
                options: MouseSystemAction.allCases.map { MGMenuOption($0, $0.label) },
                minWidth: 120
            )
            .fixedSize()
        case .shortcut:
            // 动作必须有快捷键,不给清除。
            ShortcutField(hasValue: false, clear: {}) {
                ShortcutRecorderField(shortcut: shortcutBinding, placeholder: "点击录制")
            }
        case .openApplication:
            pathPicker(buttonTitle: "选择 App…", select: selectApplication)
        case .openFile:
            pathPicker(buttonTitle: "选择文件…", select: selectFile)
        case .runScript:
            TextField("例如 open -a Finder", text: scriptBinding, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
        }
    }

    private var requiredTriggerBinding: Binding<MouseInputTrigger?> {
        Binding(
            get: { binding.trigger },
            set: { newValue in
                if let newValue {
                    binding.trigger = newValue
                }
            }
        )
    }

    private var systemActionBinding: Binding<MouseSystemAction> {
        Binding(
            get: {
                if case .system(let action) = binding.action {
                    return action
                }
                return .missionControl
            },
            set: { binding.action = .system($0) }
        )
    }

    private var shortcutBinding: Binding<Shortcut?> {
        Binding(
            get: {
                if case .shortcut(let shortcut) = binding.action {
                    return shortcut
                }
                return nil
            },
            set: { shortcut in
                if let shortcut {
                    binding.action = .shortcut(shortcut)
                }
            }
        )
    }

    private var scriptBinding: Binding<String> {
        Binding(
            get: {
                if case .runScript(let script) = binding.action {
                    return script
                }
                return ""
            },
            set: { binding.action = .runScript($0) }
        )
    }

    private func pathPicker(buttonTitle: String, select: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(currentPathLabel)
                .font(.mgMeta)
                .foregroundStyle(Color.mgText2)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(currentPathLabel)
            Spacer(minLength: 0)
            Button(buttonTitle, action: select)
                .buttonStyle(.bordered)
        }
    }

    private var currentPathLabel: String {
        switch binding.action {
        case .openApplication(let path, _), .openFile(let path):
            return path
        default:
            return ""
        }
    }

    private func selectApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择 App"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.action = .openApplication(
            path: url.path,
            bundleIdentifier: Bundle(url: url)?.bundleIdentifier
        )
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.title = "选择文件"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.action = .openFile(path: url.path)
    }
}

/// 按应用覆盖:先是 App 列表(点选),下面是选中 App 的三组覆盖。
private struct MouseAppRulesSections: View {
    @Binding var preferences: MouseControlPreferences
    @State private var selectedID: UUID?

    private var selectedIndex: Int? {
        preferences.appRules.firstIndex { $0.id == selectedID } ?? preferences.appRules.indices.first
    }

    var body: some View {
        let selectedIndex = selectedIndex

        SettingsSection("按应用覆盖") {
            if preferences.appRules.isEmpty {
                EmptyRow("暂无按应用覆盖。添加 App 后可以单独设置它的滚动、功能键和按钮绑定。")
            }
            ForEach(preferences.appRules) { rule in
                SettingsRow(
                    title: rule.displayName,
                    subtitle: rule.bundleIdentifier,
                    icon: NSWorkspace.shared.icon(forFile: rule.path)
                ) {
                    DeleteIconButton {
                        preferences.appRules.removeAll { $0.id == rule.id }
                    }
                }
                .background {
                    if let selectedIndex, preferences.appRules[selectedIndex].id == rule.id {
                        RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
                            .fill(Color.mgAccent.opacity(0.12))
                            .padding(4)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedID = rule.id }
            }
        } accessory: {
            Button("添加应用", systemImage: "plus", action: addApplicationRule)
                .buttonStyle(.bordered)
        }

        if let index = selectedIndex {
            let rule = preferences.appRules[index]

            SettingsSection("\(rule.displayName) · 滚动") {
                SettingsRow("继承全局设置", isOn: binding(index, \.inheritScroll))
                if !rule.inheritScroll {
                    MouseScrollProfileEditor(profile: binding(index, \.scroll))
                }
            }

            SettingsSection("\(rule.displayName) · 滚动功能键") {
                SettingsRow("继承全局设置", isOn: binding(index, \.inheritHotkeys))
                if !rule.inheritHotkeys {
                    MouseHotkeysEditor(hotkeys: binding(index, \.hotkeys))
                }
            }

            SettingsSection("\(rule.displayName) · 按钮绑定") {
                SettingsRow("继承全局设置", isOn: binding(index, \.inheritButtons))
                if !rule.inheritButtons {
                    MouseBindingRows(bindings: binding(index, \.buttonBindings))
                }
            } accessory: {
                if !rule.inheritButtons {
                    addBindingButton(binding(index, \.buttonBindings))
                }
            }
        }
    }

    private func binding<Value>(_ index: Int, _ keyPath: WritableKeyPath<MouseAppRule, Value>) -> Binding<Value> {
        Binding(
            get: { preferences.appRules[index][keyPath: keyPath] },
            set: { preferences.appRules[index][keyPath: keyPath] = $0 }
        )
    }

    private func addApplicationRule() {
        let panel = NSOpenPanel()
        panel.title = "添加应用配置"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bundleID = Bundle(url: url)?.bundleIdentifier ?? url.path
        if let existing = preferences.appRules.first(where: { $0.bundleIdentifier == bundleID }) {
            selectedID = existing.id
            return
        }

        let displayName = FileManager.default
            .displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        let rule = MouseAppRule(
            bundleIdentifier: bundleID,
            displayName: displayName,
            path: url.path,
            scroll: preferences.scroll,
            hotkeys: preferences.hotkeys
        )
        preferences.appRules.append(rule)
        selectedID = rule.id
    }
}
