import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MouseControlPage: View {
    private let store = GestureStore.shared

    @State private var draft = MouseControlPreferences.defaults
    @State private var didLoad = false
    @State private var statusMessage = ""

    private var hasUnsavedChanges: Bool {
        draft != store.preferences.mouseControl
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PageHeader(
                        tag: "Mouse Control",
                        title: "鼠标控制",
                        subtitle: "平滑滚动、轴向反转、滚动功能键、按应用覆盖和按钮绑定。"
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        MGSectionLabel(text: "总开关")
                        GroupCard {
                            VStack(spacing: 0) {
                                GroupRow(
                                    label: "启用鼠标控制",
                                    sub: "关闭后滚动平滑、滚动功能键和按钮绑定都不会生效"
                                ) {
                                    Toggle("", isOn: $draft.enabled)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                        .tint(.mgAccent)
                                }
                                GroupRow(
                                    label: "滚轮调试日志",
                                    sub: "仅排查滚动手感时打开,日常使用建议关闭",
                                    showDivider: true
                                ) {
                                    Toggle("", isOn: $draft.debugLoggingEnabled)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                        .tint(.mgAccent)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        MGSectionLabel(text: "全局滚动")
                        MouseScrollProfileEditor(profile: $draft.scroll)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        MGSectionLabel(text: "滚动功能键")
                        MouseHotkeysEditor(hotkeys: $draft.hotkeys)
                    }

                    MouseBindingsSection(title: "全局按钮绑定", bindings: $draft.buttonBindings)

                    MouseAppRulesSection(preferences: $draft)
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 28)
            }

            BottomToolbar(
                hasUnsavedChanges: hasUnsavedChanges,
                statusMessage: statusMessage,
                onDiscard: { reloadFromStore() },
                onSave: saveChanges
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: loadDraftIfNeeded)
        .onReceive(NotificationCenter.default.publisher(for: .gestureStoreDidChange)) { note in
            guard note.object as? GestureStore === store else { return }
            switch note.gestureStoreChangeReason {
            case .backupImport:
                reloadFromStore(silent: true)
            case .preferences:
                if !hasUnsavedChanges { reloadFromStore(silent: true) }
            default:
                break
            }
        }
    }

    private func loadDraftIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        reloadFromStore(silent: true)
    }

    private func saveChanges() {
        store.updatePreferences { preferences in
            preferences.mouseControl = draft
        }
        statusMessage = "已保存。"
    }

    private func reloadFromStore(silent: Bool = false) {
        draft = store.preferences.mouseControl
        statusMessage = silent ? "" : "已丢弃未保存更改。"
    }
}

private struct MouseScrollProfileEditor: View {
    @Binding var profile: MouseScrollProfile

    var body: some View {
        GroupCard {
            VStack(spacing: 0) {
                GroupRow(label: "平滑滚动") {
                    Toggle("", isOn: $profile.smooth)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.mgAccent)
                }
                GroupRow(label: "垂直轴平滑", showDivider: true) {
                    Toggle("", isOn: $profile.smoothVertical)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.mgAccent)
                }
                GroupRow(label: "水平轴平滑", showDivider: true) {
                    Toggle("", isOn: $profile.smoothHorizontal)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.mgAccent)
                }
                GroupRow(label: "反向滚动", showDivider: true) {
                    Toggle("", isOn: $profile.reverse)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.mgAccent)
                }
                GroupRow(label: "垂直轴反向", showDivider: true) {
                    Toggle("", isOn: $profile.reverseVertical)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.mgAccent)
                }
                GroupRow(label: "水平轴反向", showDivider: true) {
                    Toggle("", isOn: $profile.reverseHorizontal)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.mgAccent)
                }
                GroupRow(label: "最短步长", sub: "滚轮增量太小时会提升到此值", showDivider: true) {
                    MouseSliderStepperField(
                        value: $profile.minStep,
                        range: 1.0...120.0,
                        step: 0.05,
                        format: "%.2f"
                    )
                }
                GroupRow(label: "速度增益", showDivider: true) {
                    MouseSliderStepperField(
                        value: $profile.speedGain,
                        range: 0.2...8.0,
                        step: 0.05,
                        format: "%.2f"
                    )
                }
                GroupRow(label: "持续时间", sub: "数值越大,滚动尾迹越长", showDivider: true) {
                    HStack(spacing: 6) {
                        MouseSliderStepperField(
                            value: $profile.duration,
                            range: 0.5...5.0,
                            step: 0.05,
                            format: "%.2f"
                        )
                        Text("秒")
                            .font(.mgBody)
                            .foregroundStyle(Color.mgText2)
                    }
                }
                GroupRow(label: "模拟触控板模式", sub: "为合成滚动补充连续滚动标记", showDivider: true) {
                    Toggle("", isOn: $profile.simulateTrackpad)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.mgAccent)
                }
            }
        }
    }
}

private struct MouseSliderStepperField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var format: String

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: clampedValue, in: range)
                .tint(.mgAccent)
                .frame(width: 220)
                .frame(height: 22)

            MGStepperField(
                value: $value,
                range: range,
                step: step,
                format: format
            )
            .frame(width: 96)
        }
        .frame(width: 328)
    }

    private var clampedValue: Binding<Double> {
        Binding(
            get: { min(max(value, range.lowerBound), range.upperBound) },
            set: { newValue in
                let steppedValue = (newValue / step).rounded() * step
                value = min(max(steppedValue, range.lowerBound), range.upperBound)
            }
        )
    }
}

private struct MouseHotkeysEditor: View {
    @Binding var hotkeys: MouseScrollHotkeys

    var body: some View {
        GroupCard {
            VStack(spacing: 0) {
                hotkeyRow(
                    title: "加速滚动",
                    desc: "按住时提高滚动速度",
                    trigger: $hotkeys.acceleration,
                    showDivider: false
                )
                hotkeyRow(
                    title: "方向转换",
                    desc: "按住时将垂直滚动转为水平滚动",
                    trigger: $hotkeys.directionToggle,
                    showDivider: true
                )
                hotkeyRow(
                    title: "禁用平滑",
                    desc: "按住时临时透传普通滚轮事件",
                    trigger: $hotkeys.disableSmooth,
                    showDivider: true
                )
            }
        }
    }

    private func hotkeyRow(
        title: String,
        desc: String,
        trigger: Binding<MouseInputTrigger?>,
        showDivider: Bool
    ) -> some View {
        GroupRow(label: title, sub: desc, showDivider: showDivider) {
            HStack(spacing: 8) {
                KeyCapSlot(minWidth: 92) {
                    MouseInputRecorderField(trigger: trigger)
                }
                Button("清除") {
                    trigger.wrappedValue = nil
                }
                .buttonStyle(MGPlainButtonStyle(foreground: .mgText3))
            }
        }
    }
}

private struct MouseBindingsSection: View {
    let title: String
    @Binding var bindings: [MouseButtonBinding]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                MGSectionLabel(text: title)
                Spacer()
                Button {
                    addBinding()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("添加绑定")
                    }
                }
                .buttonStyle(MGSecondaryButtonStyle(foreground: .mgAccent))
                .padding(.bottom, 8)
            }

            GroupCard(padding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)) {
                if bindings.isEmpty {
                    Text("暂无按钮绑定。")
                        .font(.mgBody)
                        .foregroundStyle(Color.mgText2)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 10) {
                        // 按元素 id 遍历 / 删除:索引式 ForEach 在删除时会越界且动画错乱。
                        ForEach($bindings) { $binding in
                            MouseBindingRow(
                                binding: $binding,
                                onDelete: { bindings.removeAll { $0.id == binding.id } }
                            )
                        }
                    }
                }
            }
        }
    }

    private func addBinding() {
        bindings.append(
            MouseButtonBinding(
                name: "新绑定",
                trigger: MouseInputTrigger(kind: .mouse, code: 3, displayName: "侧键1"),
                action: .system(.missionControl)
            )
        )
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
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Toggle("", isOn: $binding.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.mgAccent)

                TextField("绑定名称", text: $binding.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 130)

                KeyCapSlot(minWidth: 104) {
                    MouseInputRecorderField(
                        trigger: requiredTriggerBinding,
                        allowsModifierOnly: false
                    )
                }

                Picker("", selection: actionKind) {
                    ForEach(MouseActionKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 112)

                Button("删除", action: onDelete)
                    .buttonStyle(MGPlainButtonStyle(foreground: .mgDanger))
            }

            actionEditor
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: MGRadius.cardSm, style: .continuous)
                .fill(Color.mgCardAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MGRadius.cardSm, style: .continuous)
                .strokeBorder(Color.mgHairStrong, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var actionEditor: some View {
        switch binding.action {
        case .system:
            Picker("系统动作", selection: systemActionBinding) {
                ForEach(MouseSystemAction.allCases) { action in
                    Text(action.label).tag(action)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220, alignment: .leading)
        case .shortcut:
            HStack {
                Text("发送快捷键")
                    .font(.mgMeta)
                    .foregroundStyle(Color.mgText2)
                KeyCapSlot(minWidth: 112) {
                    ShortcutRecorderField(shortcut: shortcutBinding, placeholder: "点击录制")
                }
                Spacer()
            }
        case .openApplication:
            pathPickerRow(title: "目标 App", buttonTitle: "选择 App", select: selectApplication)
        case .openFile:
            pathPickerRow(title: "目标文件", buttonTitle: "选择文件", select: selectFile)
        case .runScript:
            HStack(alignment: .top, spacing: 8) {
                Text("脚本")
                    .font(.mgMeta)
                    .foregroundStyle(Color.mgText2)
                    .frame(width: 52, alignment: .leading)
                    .padding(.top, 6)
                TextField("例如 open -a Finder", text: scriptBinding, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
            }
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

    private func pathPickerRow(title: String, buttonTitle: String, select: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.mgMeta)
                .foregroundStyle(Color.mgText2)
                .frame(width: 52, alignment: .leading)
            Text(currentPathLabel)
                .font(.mgBody)
                .foregroundStyle(Color.mgText1)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(buttonTitle, action: select)
                .buttonStyle(MGSecondaryButtonStyle())
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

private struct MouseAppRulesSection: View {
    @Binding var preferences: MouseControlPreferences
    @State private var selectedID: UUID?

    private var selectedIndex: Int? {
        if let selectedID,
           let index = preferences.appRules.firstIndex(where: { $0.id == selectedID }) {
            return index
        }
        return preferences.appRules.indices.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MGSectionLabel(text: "按应用配置")
                Spacer()
                Button {
                    addApplicationRule()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("添加应用")
                    }
                }
                .buttonStyle(MGSecondaryButtonStyle(foreground: .mgAccent))
                .padding(.bottom, 8)
            }

            GroupCard(padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)) {
                if preferences.appRules.isEmpty {
                    Text("暂无应用覆盖规则。添加 App 后可选择继承全局设置,或单独覆盖滚动、功能键和按钮绑定。")
                        .font(.mgBody)
                        .foregroundStyle(Color.mgText2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        appList
                            .frame(width: 220)

                        Rectangle()
                            .fill(Color.mgHair)
                            .frame(width: 0.5)

                        if let selectedIndex {
                            appRuleEditor(index: selectedIndex)
                        }
                    }
                }
            }
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(preferences.appRules) { rule in
                Button {
                    selectedID = rule.id
                } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: rule.path))
                            .resizable()
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.displayName)
                                .font(.mgBodyMedium)
                                .foregroundStyle(Color.mgText1)
                                .lineLimit(1)
                            Text(rule.bundleIdentifier)
                                .font(.mgMeta)
                                .foregroundStyle(Color.mgText3)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: MGRadius.controlSm, style: .continuous)
                            .fill(rule.id == (selectedID ?? preferences.appRules.first?.id) ? Color.mgAccentSoft : .clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func appRuleEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preferences.appRules[index].displayName)
                        .font(.mgTitleM)
                        .foregroundStyle(Color.mgText1)
                    Text(preferences.appRules[index].path)
                        .font(.mgMeta)
                        .foregroundStyle(Color.mgText2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("删除") {
                    let removed = preferences.appRules.remove(at: index)
                    if selectedID == removed.id {
                        selectedID = preferences.appRules.first?.id
                    }
                }
                .buttonStyle(MGDestructiveButtonStyle(height: 28))
            }

            appRuleToggle("继承全局滚动", isOn: binding(index, \.inheritScroll))
            if !preferences.appRules[index].inheritScroll {
                MouseScrollProfileEditor(profile: binding(index, \.scroll))
            }

            appRuleToggle("继承全局功能键", isOn: binding(index, \.inheritHotkeys))
            if !preferences.appRules[index].inheritHotkeys {
                MouseHotkeysEditor(hotkeys: binding(index, \.hotkeys))
            }

            appRuleToggle("继承全局按钮绑定", isOn: binding(index, \.inheritButtons))
            if !preferences.appRules[index].inheritButtons {
                MouseBindingsSection(
                    title: "此 App 的按钮绑定",
                    bindings: binding(index, \.buttonBindings)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func appRuleToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.mgBodyMedium)
                .foregroundStyle(Color.mgText1)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.mgAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
                .fill(Color.mgCardAlt)
        )
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
