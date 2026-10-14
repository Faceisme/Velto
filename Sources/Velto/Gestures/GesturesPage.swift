import AppKit
import SwiftUI

// MARK: - GesturesPage
//
// 页头 + [手势 | 设置] 分段固定在顶部,下面按分段切换:
//   手势:左栏「作用范围(全局 / 各 App)+ 这一套的手势列表」| 右栏详情(录制 / 快捷键),
//         两栏各自滚动;选中某个 App 时左栏再多一组「全局手势」:是否在这个 App 里同时生效、
//         哪些被专属手势覆盖、一键把形状复制成专属手势。有改动或冲突时底部出现保存栏
//   设置:行为 / 识别 / 调试,直接写 store
// 手势(全局 + 各 App)整体留草稿:录样本是"编辑文档"式的操作,而且要先过冲突校验才能保存。

struct GesturesPage: View {
    private enum Tab: Hashable { case gestures, settings }

    /// 手势列表正在编辑哪一套:全局,或某个 App 的专属手势。
    private enum Scope: Hashable {
        case global
        case app(UUID)
    }

    private let store = GestureStore.shared

    @State private var tab: Tab = .gestures
    @State private var scope: Scope = .global
    @State private var draftGlobal: [GestureCommand] = []
    @State private var draftProfiles: [GestureAppProfile] = []
    @State private var didLoad = false
    @State private var selectedID: UUID?
    @State private var statusMessage = ""
    @State private var hasUnsavedChanges = false

    private var profileIndex: Int? {
        guard case .app(let id) = scope else { return nil }
        return draftProfiles.firstIndex { $0.id == id }
    }

    private var profile: GestureAppProfile? {
        profileIndex.map { draftProfiles[$0] }
    }

    /// 当前作用范围的那一套手势(列表、详情编辑的对象)。
    private var scopeGestures: [GestureCommand] {
        profile?.gestures ?? draftGlobal
    }

    private var selected: GestureCommand? {
        guard let id = selectedID else { return nil }
        return scopeGestures.first { $0.id == id }
    }

    /// 全部手势(全局 + 各 App)的规范签名 —— 列表用它展示箭头 + 弧向(如 "↗⌣"),
    /// 并据此检测冲突、算覆盖关系。每次渲染只算一遍,往下传。
    private var signatures: [UUID: GestureDirection.Signature] {
        var result: [UUID: GestureDirection.Signature] = [:]
        for gesture in draftGlobal + draftProfiles.flatMap(\.gestures) {
            result[gesture.id] = GestureDirection.canonical(for: gesture.templates.map { $0.map(\.cgPoint) })
        }
        return result
    }

    /// 同一套里签名差异度过小的手势互相冲突 —— 谁都可能识别不出。返回涉及冲突的全部 id。
    /// 跨套(App 手势 vs 全局手势)同形状不算冲突,算覆盖。
    private func conflictSet(in gestures: [GestureCommand], _ signatures: [UUID: GestureDirection.Signature]) -> Set<UUID> {
        let entries = gestures.compactMap { g in signatures[g.id].flatMap { $0.isEmpty ? nil : (g.id, $0) } }
        var conflicting: Set<UUID> = []
        for i in entries.indices {
            for j in entries.indices where j > i {
                if GestureDirection.distance(entries[i].1, entries[j].1) < GestureAppScope.sameShapeThreshold {
                    conflicting.insert(entries[i].0)
                    conflicting.insert(entries[j].0)
                }
            }
        }
        return conflicting
    }

    /// 保存前校验,覆盖全局和每个 App 的那一套。`block` 非空时**阻止保存**(同一套里有手势
    /// 互相重复 —— 存了却谁都不触发,最隐蔽);`warning` 是不阻止保存的提示(半配置手势,
    /// 有快捷键没样本 / 有样本没快捷键,存下来也不会生效)。App 的手势名前带「App 名 · 」。
    private func saveValidation(_ signatures: [UUID: GestureDirection.Signature]) -> (block: String?, warning: String?) {
        let sets: [(prefix: String, gestures: [GestureCommand])] =
            [("", draftGlobal)] + draftProfiles.map { ("\($0.displayName) · ", $0.gestures) }
        var conflictNames: [String] = []
        var warnings: [String] = []
        for set in sets {
            let conflicts = conflictSet(in: set.gestures, signatures)
            conflictNames += set.gestures.filter { conflicts.contains($0.id) }.map { set.prefix + $0.name }
            for gesture in set.gestures {
                let hasTemplate = !(signatures[gesture.id] ?? .empty).isEmpty
                let hasShortcut = gesture.shortcut != nil
                if hasShortcut, !hasTemplate {
                    warnings.append("「\(set.prefix)\(gesture.name)」缺少有效样本")
                } else if hasTemplate, !hasShortcut {
                    warnings.append("「\(set.prefix)\(gesture.name)」未设置快捷键")
                }
            }
        }
        let block = conflictNames.isEmpty
            ? nil
            : "手势重复:\(conflictNames.joined(separator: "、")) —— 改成不同形状后才能保存"
        let warning = warnings.isEmpty ? nil : "\(warnings.joined(separator: ";")),不会触发"
        return (block, warning)
    }

    var body: some View {
        let signatures = signatures
        let validation = saveValidation(signatures)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    page: .gestures,
                    subtitle: "按住右键画出轨迹,触发对应的快捷键;可为单个 App 配一套专属手势。",
                    isOn: pref(\.gesturesEnabled)
                )
                .help("关闭后右键手势暂停,不影响其它模块。")

                Picker("", selection: $tab) {
                    Text("手势").tag(Tab.gestures)
                    Text("设置").tag(Tab.settings)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.large)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)

            switch tab {
            case .gestures:
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        gestureColumn(signatures)
                            .padding(.top, 24)
                            .padding(.bottom, 28)
                    }
                    .frame(width: 320)

                    ScrollView {
                        detail
                            .padding(.top, 24)
                            .padding(.bottom, 28)
                    }
                }
                .padding(.horizontal, 32)

                if hasUnsavedChanges || validation.block != nil || !statusMessage.isEmpty {
                    BottomToolbar(
                        hasUnsavedChanges: hasUnsavedChanges,
                        statusMessage: statusMessage,
                        saveBlockReason: validation.block,
                        saveWarning: validation.warning,
                        onDiscard: reloadFromStore,
                        onSave: saveChanges
                    )
                }
            case .settings:
                ScrollView {
                    settingsTab
                        .padding(.top, 24)
                        .padding(.bottom, 28)
                        .padding(.horizontal, 32)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: loadDraftIfNeeded)
        .onReceive(NotificationCenter.default.publisher(for: .gestureStoreDidChange)) { note in
            guard note.object as? GestureStore === store else { return }
            switch note.gestureStoreChangeReason {
            case .gestures, .backupImport:
                reloadFromStore()
            default: break
            }
        }
    }

    private func pref<V>(_ kp: WritableKeyPath<AppPreferences, V>) -> Binding<V> {
        Binding(
            get: { store.preferences[keyPath: kp] },
            set: { v in store.updatePreferences { $0[keyPath: kp] = v } }
        )
    }

    // MARK: 手势分段 · 左栏

    private func gestureColumn(_ signatures: [UUID: GestureDirection.Signature]) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            scopeSection
            gestureListSection(signatures)
            if let index = profileIndex {
                globalGesturesSection(draftProfiles[index], signatures)
            }
        }
    }

    /// 作用范围:全局一行 + 每个配了专属手势的 App 一行,点选切换下面的手势列表。
    private var scopeSection: some View {
        SettingsSection("作用范围") {
            ScopeRow(
                title: "全局",
                subtitle: "所有 App",
                count: draftGlobal.count,
                selected: scope == .global,
                onSelect: { selectScope(.global) }
            ) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.mgAccent)
                    .frame(width: 24, height: 24)
                    .background(Color.mgInset, in: RoundedRectangle(cornerRadius: MGRadius.kbd, style: .continuous))
            }
            ForEach(draftProfiles) { p in
                ScopeRow(
                    title: p.displayName,
                    subtitle: p.includesGlobalGestures ? "专属 + 全局手势" : "仅专属手势",
                    count: p.gestures.count,
                    selected: scope == .app(p.id),
                    onSelect: { selectScope(.app(p.id)) }
                ) {
                    Image(nsImage: Self.appIcon(bundleID: p.bundleIdentifier, path: p.path))
                        .resizable()
                        .frame(width: 24, height: 24)
                }
            }
        } accessory: {
            AddAppMenu(
                excludedBundleIDs: Set(draftProfiles.map(\.bundleIdentifier)),
                onPick: { addProfile(appURL: $0) }
            )
        }
    }

    /// 当前作用范围的手势列表。App 的专属手势若和某个全局手势同形状(且这个 App 开着
    /// 全局手势),行上标「覆盖「后退」」,一眼看出它顶掉了谁。
    private func gestureListSection(_ signatures: [UUID: GestureDirection.Signature]) -> some View {
        let gestures = scopeGestures
        let conflicts = conflictSet(in: gestures, signatures)
        var overriddenNames: [UUID: [String]] = [:]
        if let profile, profile.includesGlobalGestures {
            let overrides = GestureAppScope.overrides(appGestures: profile.gestures, globalGestures: draftGlobal) {
                signatures[$0.id] ?? .empty
            }
            for global in draftGlobal {
                if let appID = overrides[global.id] { overriddenNames[appID, default: []].append(global.name) }
            }
        }

        return SettingsSection(profile.map { "\($0.displayName) 专属手势" } ?? "全局手势") {
            if gestures.isEmpty, let profile {
                EmptyRow("还没有专属手势。新建一个,或从下方全局手势复制形状,再改成 \(profile.displayName) 的快捷键。")
            }
            ForEach(gestures) { g in
                GestureRow(
                    gesture: g,
                    directionArrows: GestureDirection.displayString(signatures[g.id] ?? .empty),
                    conflict: conflicts.contains(g.id),
                    note: overriddenNames[g.id].map { "覆盖「\($0.joined(separator: "」「"))」" },
                    selected: g.id == selectedID,
                    onSelect: { selectedID = g.id }
                )
            }
            Button(action: addGesture) {
                Label("新建手势", systemImage: "plus")
                    .font(.mgBody)
                    .foregroundStyle(Color.mgAccent)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } accessory: {
            if let profile {
                Button("移除 App", role: .destructive) { removeProfile(profile.id) }
                    .buttonStyle(.bordered)
                    .foregroundStyle(Color.mgDanger)
                    .help("移除 \(profile.displayName) 和它的全部专属手势(保存前可丢弃更改)")
            }
        }
    }

    /// App 作用范围下的全局手势:开关决定它们在这个 App 里是否同时生效;逐行标出被哪个
    /// 专属手势覆盖;每行可把形状复制成专属手势 —— 常见用法是同一个「←」在全局是后退,
    /// 在播放器里改成快退,复制过来只需重设快捷键。
    private func globalGesturesSection(
        _ profile: GestureAppProfile,
        _ signatures: [UUID: GestureDirection.Signature]
    ) -> some View {
        let overrides = profile.includesGlobalGestures
            ? GestureAppScope.overrides(appGestures: profile.gestures, globalGestures: draftGlobal) {
                signatures[$0.id] ?? .empty
            }
            : [:]
        let appNames = Dictionary(uniqueKeysWithValues: profile.gestures.map { ($0.id, $0.name) })

        return SettingsSection("全局手势") {
            SettingsRow(
                "在 \(profile.displayName) 中同时生效",
                subtitle: "同形状的以专属手势为准。",
                isOn: Binding(
                    get: { profile.includesGlobalGestures },
                    set: { v in updateProfile(profile.id) { $0.includesGlobalGestures = v } }
                )
            )
            ForEach(draftGlobal) { g in
                InheritedGestureRow(
                    gesture: g,
                    directionArrows: GestureDirection.displayString(signatures[g.id] ?? .empty),
                    active: profile.includesGlobalGestures && overrides[g.id] == nil,
                    overriddenBy: overrides[g.id].flatMap { appNames[$0] },
                    copyHelp: "复制形状到 \(profile.displayName) 专属手势",
                    onCopy: { copyGlobalGesture(g) }
                )
            }
        }
    }

    // MARK: 手势分段 · 右栏

    @ViewBuilder
    private var detail: some View {
        if let g = selected {
            // 换手势时整块重建:改名状态、录制中的笔迹都不带到下一个手势。
            GestureDetail(
                gesture: g,
                scopeName: profile?.displayName,
                onDelete: deleteSelectedGesture,
                updateDraft: updateSelectedDraft
            )
            .id(g.id)
        } else {
            GroupCard { EmptyRow(emptyDetailText) }
        }
    }

    private var emptyDetailText: String {
        guard scopeGestures.isEmpty else { return "从左侧选一个手势。" }
        if let profile {
            return "还没有 \(profile.displayName) 专属手势。点左侧「新建手势」录制,或从全局手势复制一个形状。"
        }
        return "还没有手势。点左侧「新建手势」录制第一个。"
    }

    // MARK: 设置分段

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection("行为") {
                SettingsRow("绘制时显示轨迹", isOn: pref(\.showTrail))
                SettingsRow(
                    "乱划取消手势",
                    subtitle: "手势途中来回乱划几下即可取消,无需等待超时。",
                    isOn: pref(\.scribbleCancelEnabled)
                )
            }

            SettingsSection("识别") {
                SettingsRow(title: "手势超时时长", subtitle: "超时未完成的手势会被丢弃。") {
                    MGStepperField(value: pref(\.gestureTimeoutSeconds), range: 0.5...10.0, step: 0.5, format: "%.1f 秒")
                }
                SettingsRow(title: "手势作用目标", subtitle: "也决定按哪个 App 的专属手势来识别。") {
                    Picker("", selection: pref(\.gestureTargetPolicy)) {
                        Text("鼠标指针下方").tag(GestureTargetPolicy.windowUnderPointer)
                        Text("活动窗口").tag(GestureTargetPolicy.activeWindow)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            DebugSection(
                isOn: pref(\.debugLoggingEnabled),
                logURL: DebugLog.fileURL,
                help: "记录手势轨迹和匹配诊断,排查时打开。"
            )
        }
    }

    // MARK: 草稿

    private func loadDraftIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        draftGlobal = store.gestures
        draftProfiles = store.appProfiles
        selectedID = draftGlobal.first?.id
    }

    private func markEdited() {
        hasUnsavedChanges = true
        statusMessage = ""
    }

    /// 改当前作用范围的那一套手势。
    private func editScopeGestures(_ edit: (inout [GestureCommand]) -> Void) {
        if let index = profileIndex {
            edit(&draftProfiles[index].gestures)
        } else {
            edit(&draftGlobal)
        }
        markEdited()
    }

    private func updateSelectedDraft(_ update: (inout GestureCommand) -> Void) {
        let gestures = scopeGestures
        guard let id = selectedID,
              let idx = gestures.firstIndex(where: { $0.id == id }) else { return }
        var modified = gestures[idx]
        update(&modified)
        guard modified != gestures[idx] else { return }
        editScopeGestures { $0[idx] = modified }
    }

    private func addGesture() {
        let new = GestureCommand(name: "新手势", templates: [], shortcut: nil)
        editScopeGestures { $0.append(new) }
        selectedID = new.id
    }

    private func deleteSelectedGesture() {
        let gestures = scopeGestures
        guard let id = selectedID,
              let idx = gestures.firstIndex(where: { $0.id == id }) else { return }
        let nextID: UUID? = gestures.count > 1
            ? gestures[idx == gestures.count - 1 ? idx - 1 : idx + 1].id
            : nil
        editScopeGestures { $0.remove(at: idx) }
        selectedID = nextID
    }

    /// 把全局手势的形状复制成当前 App 的专属手势(不带快捷键,等用户设成这个 App 的)。
    private func copyGlobalGesture(_ global: GestureCommand) {
        guard profileIndex != nil else { return }
        let copy = GestureCommand(name: global.name, templates: global.templates, shortcut: nil)
        editScopeGestures { $0.append(copy) }
        selectedID = copy.id
    }

    private func selectScope(_ newScope: Scope) {
        guard newScope != scope else { return }
        scope = newScope
        selectedID = scopeGestures.first?.id
    }

    private func updateProfile(_ id: UUID, _ update: (inout GestureAppProfile) -> Void) {
        guard let index = draftProfiles.firstIndex(where: { $0.id == id }) else { return }
        update(&draftProfiles[index])
        markEdited()
    }

    private func addProfile(appURL url: URL) {
        let bundleID = Bundle(url: url)?.bundleIdentifier ?? url.path
        if let existing = draftProfiles.first(where: { $0.bundleIdentifier == bundleID }) {
            selectScope(.app(existing.id))
            return
        }
        let displayName = FileManager.default
            .displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        let new = GestureAppProfile(bundleIdentifier: bundleID, displayName: displayName, path: url.path)
        draftProfiles.append(new)
        markEdited()
        selectScope(.app(new.id))
    }

    private func removeProfile(_ id: UUID) {
        draftProfiles.removeAll { $0.id == id }
        markEdited()
        selectScope(.global)
    }

    private func saveChanges() {
        // 阻止保存重复手势(保存按钮平时已禁用,这里兜底防回车等路径)。
        if let block = saveValidation(signatures).block {
            statusMessage = "无法保存 —— \(block)"
            return
        }
        let normalize: (GestureCommand) -> GestureCommand = { g in
            var n = g
            let trimmed = n.name.trimmingCharacters(in: .whitespacesAndNewlines)
            n.name = trimmed.isEmpty ? "未命名" : trimmed
            return n
        }
        let global = draftGlobal.map(normalize)
        let profiles = draftProfiles.map { p -> GestureAppProfile in
            var n = p
            n.gestures = p.gestures.map(normalize)
            return n
        }
        let persisted = store.saveGestureSets(global: global, appProfiles: profiles)
        draftGlobal = global
        draftProfiles = profiles
        hasUnsavedChanges = false
        // 存成功保存栏直接收起;失败留着提示。
        statusMessage = persisted ? "" : "保存失败:无法写入配置(本次更改本会话有效,重启后会丢失)。"
    }

    /// 丢弃草稿,或 store 被别处改了(备份导入等)时重载。
    private func reloadFromStore() {
        draftGlobal = store.gestures
        draftProfiles = store.appProfiles
        hasUnsavedChanges = false
        if case .app(let id) = scope, !draftProfiles.contains(where: { $0.id == id }) {
            scope = .global
        }
        if !scopeGestures.contains(where: { $0.id == selectedID }) {
            selectedID = scopeGestures.first?.id
        }
        statusMessage = ""
    }

    /// App 图标:优先按 bundle id 找当前装着的那份(App 挪过位置也找得到),再退到记下的路径。
    static func appIcon(bundleID: String, path: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(forFile: path)
    }
}

// MARK: - 列表行

private struct GestureRow: View {
    let gesture: GestureCommand
    /// 识别成的方向 + 弧向签名(如 "↗⌣"),空串表示还没录。
    let directionArrows: String
    /// 和别的手势太像,谁都可能识别不出。
    let conflict: Bool
    /// 附注(如 App 专属手势覆盖了哪个全局手势),nil 不显示。
    var note: String? = nil
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                GestureThumbnail(gesture: gesture)

                VStack(alignment: .leading, spacing: 2) {
                    Text(gesture.name)
                        .font(.mgBody)
                        .foregroundStyle(Color.mgText1)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if !directionArrows.isEmpty {
                            Text(directionArrows)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text("\(gesture.templates.count) 个样本")
                        if conflict {
                            Text("冲突")
                                .foregroundStyle(Color.orange)
                        }
                        if let note {
                            Text(note)
                                .foregroundStyle(Color.mgAccent)
                        }
                    }
                    .font(.mgMeta)
                    .foregroundStyle(Color.mgText2)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let sc = gesture.shortcut {
                    Kbd(keys: sc.kbdKeys, size: .sm)
                } else {
                    Text("未设置")
                        .font(.mgMeta)
                        .foregroundStyle(Color.mgText3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
                        .fill(Color.mgAccent.opacity(0.12))
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transaction { $0.animation = nil }
    }
}

/// 列表行左侧的轨迹缩略图。
private struct GestureThumbnail: View {
    let gesture: GestureCommand

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MGRadius.kbd, style: .continuous)
                .fill(Color.mgInset)
            if let last = gesture.templates.last {
                // 缩略图只画最后一个样本,免噪
                GestureTrailView(templates: [last], stroke: 2.5, maxGhosts: 0)
                    .padding(4)
            } else {
                Image(systemName: "questionmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.mgText3)
            }
        }
        .frame(width: 32, height: 32)
    }
}

// MARK: - 详情

private struct GestureDetail: View {
    let gesture: GestureCommand
    /// App 专属手势所属 App 的名字;全局手势为 nil。
    let scopeName: String?
    let onDelete: () -> Void
    let updateDraft: ((inout GestureCommand) -> Void) -> Void

    @State private var isEditingName = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if isEditingName {
                        TextField("手势名称", text: Binding(
                            get: { gesture.name },
                            set: { v in updateDraft { $0.name = v } }
                        ))
                        .textFieldStyle(.plain)
                        .font(.mgTitleM)
                        .focused($nameFocused)
                        .onSubmit { isEditingName = false }
                    } else {
                        Text(displayName)
                            .font(.mgTitleM)
                            .foregroundStyle(Color.mgText1)
                            .lineLimit(1)
                    }
                    Text(scopeName.map { "仅在 \($0) 中生效" } ?? "所有 App 生效")
                        .font(.mgMeta)
                        .foregroundStyle(Color.mgText2)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button(isEditingName ? "完成" : "重命名") { isEditingName.toggle() }
                        .buttonStyle(.bordered)
                    Button("删除", role: .destructive, action: onDelete)
                        .buttonStyle(.bordered)
                        .foregroundStyle(Color.mgDanger)
                }
                // 按钮组守住固有宽度:窄的时候让名称去截断,别把按钮的字挤没。
                .fixedSize()
            }
            .onChange(of: isEditingName) { _, editing in
                // 输入框这一帧才插进来,下一轮再给焦点。
                if editing { DispatchQueue.main.async { nameFocused = true } }
            }

            SettingsSection("录制") {
                // 画布画已存的样本;上面叠一层透明的录制视图截右键拖动,松手追加一个样本。
                GesturePreviewCard(templates: gesture.templates) {
                    GestureCaptureRepresentable { points in
                        updateDraft { $0.templates.append(points.map(StrokePoint.init)) }
                    }
                }
                .padding(12)

                SettingsRow(title: "\(gesture.templates.count) 个样本", subtitle: "建议录 2–3 个。") {
                    Group {
                        Button("撤销上一个") { updateDraft { _ = $0.templates.popLast() } }
                        Button("清空") { updateDraft { $0.templates.removeAll() } }
                    }
                    .buttonStyle(.bordered)
                    .disabled(gesture.templates.isEmpty)
                }
            }

            SettingsSection("快捷键") {
                SettingsRow(title: "触发") {
                    ShortcutField(shortcut: Binding(
                        get: { gesture.shortcut },
                        set: { v in updateDraft { $0.shortcut = v } }
                    ))
                }
            }
        }
    }

    private var displayName: String {
        let trimmed = gesture.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名" : trimmed
    }
}

// MARK: - 作用范围行

/// 「作用范围」里的一行:图标 + 名称 / 说明 + 手势数,点选切换。
private struct ScopeRow<Icon: View>: View {
    let title: String
    let subtitle: String
    let count: Int
    let selected: Bool
    let onSelect: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                icon()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.mgBody)
                        .foregroundStyle(Color.mgText1)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.mgMeta)
                        .foregroundStyle(Color.mgText2)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(count) 个手势")
                    .font(.mgMeta)
                    .foregroundStyle(Color.mgText3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
                        .fill(Color.mgAccent.opacity(0.12))
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transaction { $0.animation = nil }
    }
}

// MARK: - App 作用范围下的全局手势行

/// 只读展示一个全局手势在当前 App 里的状态,右侧按钮把形状复制成专属手势。
private struct InheritedGestureRow: View {
    let gesture: GestureCommand
    let directionArrows: String
    /// 在这个 App 里是否生效(开关开着且没被覆盖)。
    let active: Bool
    /// 覆盖它的专属手势名,nil = 没被覆盖。
    let overriddenBy: String?
    let copyHelp: String
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            GestureThumbnail(gesture: gesture)
                .opacity(active ? 1 : 0.45)

            VStack(alignment: .leading, spacing: 2) {
                Text(gesture.name)
                    .font(.mgBody)
                    .foregroundStyle(active ? Color.mgText1 : Color.mgText3)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !directionArrows.isEmpty {
                        Text(directionArrows)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    if let overriddenBy {
                        Text("被「\(overriddenBy)」覆盖")
                            .foregroundStyle(Color.orange)
                    } else if let sc = gesture.shortcut {
                        Text(sc.displayName)
                    }
                }
                .font(.mgMeta)
                .foregroundStyle(active ? Color.mgText2 : Color.mgText3)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onCopy) {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.mgAccent)
            .disabled(gesture.templates.isEmpty)
            .help(copyHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 添加 App 菜单

/// 「添加应用」:先列正在运行的 App(配手势时目标 App 多半开着,一点即加),
/// 再兜底从「应用程序」里选。已加过的不再列出。
private struct AddAppMenu: View {
    let excludedBundleIDs: Set<String>
    let onPick: (URL) -> Void

    var body: some View {
        Menu {
            let apps = runningApps
            if !apps.isEmpty {
                Section("正在运行") {
                    ForEach(apps, id: \.processIdentifier) { app in
                        Button {
                            if let url = app.bundleURL { onPick(url) }
                        } label: {
                            Label {
                                Text(app.localizedName ?? app.bundleIdentifier ?? "")
                            } icon: {
                                Image(nsImage: Self.menuIcon(app.icon))
                            }
                        }
                    }
                }
            }
            Button("从「应用程序」中选择…", action: chooseFromApplications)
        } label: {
            Label("添加应用", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
    }

    private var runningApps: [NSRunningApplication] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular,
                      app.processIdentifier != selfPID,
                      app.bundleURL != nil,
                      let bundleID = app.bundleIdentifier else { return false }
                return !excludedBundleIDs.contains(bundleID)
            }
            .sorted {
                ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
            }
    }

    private func chooseFromApplications() {
        let panel = NSOpenPanel()
        panel.title = "选择要单独配置手势的 App"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPick(url)
    }

    /// 菜单项图标要自己缩到 16pt,否则按原图尺寸撑开菜单行。
    private static func menuIcon(_ icon: NSImage?) -> NSImage {
        let source = icon ?? NSWorkspace.shared.icon(for: .application)
        let resized = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        return resized
    }
}

// MARK: - BottomToolbar 保存栏
//
// 只在有改动、冲突或保存失败时出现;状态在左,[丢弃更改] [保存] 在右。

private struct BottomToolbar: View {
    let hasUnsavedChanges: Bool
    let statusMessage: String
    /// 非空 = 存在冲突,阻止保存(红色提示 + 禁用保存按钮)。
    let saveBlockReason: String?
    /// 非空 = 半配置手势,不阻止保存(橙色提示)。
    let saveWarning: String?
    let onDiscard: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusArea

            Spacer()

            Button("丢弃更改", action: onDiscard)
                .buttonStyle(.borderless)
                .disabled(!hasUnsavedChanges)

            Button("保存", action: onSave)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(!hasUnsavedChanges || saveBlockReason != nil)
        }
        .padding(.horizontal, 32)
        .frame(height: 54)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.mgHair)
                .frame(height: 0.5)
        }
        .glassEffect(.regular, in: Rectangle())
    }

    @ViewBuilder
    private var statusArea: some View {
        if let block = saveBlockReason {
            // 冲突优先,红色,且会禁用保存。
            label(text: block, dot: .red, color: .red)
        } else if let warning = saveWarning {
            label(text: warning, dot: .orange, color: Color.mgText2)
        } else if hasUnsavedChanges {
            label(text: "有未保存的更改", dot: .orange, color: Color.mgText2)
        } else if !statusMessage.isEmpty {
            Text(statusMessage)
                .font(.mgMeta)
                .foregroundStyle(Color.mgText2)
        }
    }

    private func label(text: String, dot: Color, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text)
                .font(.mgMeta)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}
