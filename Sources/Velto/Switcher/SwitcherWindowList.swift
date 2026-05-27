import ApplicationServices
import Cocoa

/// 一次后台 AX 扫描的结果。从后台线程封装好,交给主线程合并到 windows 字典。
///
/// `@unchecked Sendable`:`AXUIElement` 是 CF 类型,线程间传引用是安全的(它
/// 自己有内部锁),Swift 看不出来 —— 我们对这个边界负责。
/// 把单个 AXUIElement 包成可跨线程传递的 Sendable 容器。
/// 我们对线程安全负责:AXUIElement 是 CF 类型,引用传递本身就是线程安全的。
struct SwitcherAxRefBox: @unchecked Sendable {
    let element: AXUIElement
}

struct SwitcherWindowProbe: @unchecked Sendable {
    let axUiElement: AXUIElement
    let wid: CGWindowID
    let title: String?
    let cgTitle: String?
    let subrole: String?
    let role: String?
    let size: CGSize?
    let position: CGPoint?
    let isMinimized: Bool
    let isFullscreen: Bool

    var hasExplicitTitle: Bool {
        Self.isNonEmptyTitle(title) || Self.isNonEmptyTitle(cgTitle)
    }

    var isUntitledPlaceholderCandidate: Bool {
        !hasExplicitTitle && !isMinimized
    }

    private static func isNonEmptyTitle(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// AX 字符串常量 —— 这两个在某些 SDK 版本里没桥接成 Swift 常量,直接用字符串。
private let kAXFullScreenAttribute = "AXFullScreen"

/// 全局窗口清单。所有读写都在主线程上,AX 调用通过 `AXCallQueue` 后台化。
@MainActor
final class SwitcherWindowList {
    static let shared = SwitcherWindowList()

    /// 跟踪中的 app
    private var apps: [pid_t: SwitcherApp] = [:]

    /// 跟踪中的窗口
    private(set) var windows: [CGWindowID: SwitcherWindow] = [:]

    /// 当前最前台 app 的 pid
    var frontmostPid: pid_t?

    /// 列表发生变化(增删/MRU/title)的回调。Controller 在切换器活跃期间订阅。
    var onListChanged: (() -> Void)?

    private var didInitialize = false
    private var lastGhostProbeTime: TimeInterval = 0

    private init() {}

    // MARK: - 生命周期

    func start() {
        guard !didInitialize else { return }
        didInitialize = true

        for app in NSWorkspace.shared.runningApplications {
            addApp(app)
        }

        let wsc = NSWorkspace.shared.notificationCenter
        wsc.addObserver(self, selector: #selector(workspaceDidLaunchApp(_:)),
                        name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        wsc.addObserver(self, selector: #selector(workspaceDidTerminateApp(_:)),
                        name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        wsc.addObserver(self, selector: #selector(workspaceDidActivateApp(_:)),
                        name: NSWorkspace.didActivateApplicationNotification, object: nil)

        frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    @objc private func workspaceDidLaunchApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        addApp(app)
    }

    @objc private func workspaceDidTerminateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        removeApp(pid: app.processIdentifier)
    }

    @objc private func workspaceDidActivateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        frontmostPid = app.processIdentifier
        syncWindowsForApp(pid: app.processIdentifier)
    }

    // MARK: - App 管理

    private func addApp(_ runningApplication: NSRunningApplication) {
        let pid = runningApplication.processIdentifier
        guard apps[pid] == nil else { return }
        let app = SwitcherApp(runningApplication)
        guard app.isEligibleForTracking else { return }
        apps[pid] = app
        app.startObserving(Self.axObserverCallback, Unmanaged.passUnretained(self).toOpaque())
        syncWindowsForApp(pid: pid)
    }

    private func removeApp(pid: pid_t) {
        guard let app = apps.removeValue(forKey: pid) else { return }
        // 先反订阅这个 app 所有窗口的窗口级通知,再让 app 自己 stopObserving
        // (后者会移除 AX runloop source,observer 整体析构)
        for w in windows.values where w.application.pid == pid {
            unsubscribeWindowNotifications(w)
        }
        app.stopObserving()
        let removedWids = windows.values.filter { $0.application.pid == pid }.map(\.cgWindowId)
        for wid in removedWids { windows.removeValue(forKey: wid) }
        if !removedWids.isEmpty {
            compactMRUOrdering()
            onListChanged?()
        }
    }

    // MARK: - 窗口同步

    private func syncWindowsForApp(pid: pid_t) {
        guard let app = apps[pid] else { return }
        AXCallQueue.shared.schedule("sync-\(pid)") { [weak self] in
            guard let axWindows = app.copyAxWindows() else { return }
            let probes: [SwitcherWindowProbe] = axWindows.compactMap { ax in
                guard let wid = SwitcherAxRead.cgWindowId(of: ax) else { return nil }
                let attrs = SwitcherAxRead.multiAttributes(ax, [
                    kAXTitleAttribute as String,
                    kAXSubroleAttribute as String,
                    kAXRoleAttribute as String,
                    kAXSizeAttribute as String,
                    kAXPositionAttribute as String,
                    kAXMinimizedAttribute as String,
                    kAXFullScreenAttribute,
                ])
                let size: CGSize? = attrs[kAXSizeAttribute as String].flatMap(SwitcherAxRead.axValueSize)
                let position: CGPoint? = attrs[kAXPositionAttribute as String].flatMap(SwitcherAxRead.axValuePoint)
                let axTitle = attrs[kAXTitleAttribute as String] as? String
                return SwitcherWindowProbe(
                    axUiElement: ax,
                    wid: wid,
                    title: axTitle,
                    cgTitle: SwitcherAxRead.cgTitle(for: wid),
                    subrole: attrs[kAXSubroleAttribute as String] as? String,
                    role: attrs[kAXRoleAttribute as String] as? String,
                    size: size,
                    position: position,
                    isMinimized: (attrs[kAXMinimizedAttribute as String] as? Bool) ?? false,
                    isFullscreen: (attrs[kAXFullScreenAttribute] as? Bool) ?? false
                )
            }
            let spaceMap = SwitcherSpaces.spaces(forWindowIds: probes.map(\.wid))
            Task { @MainActor [weak self] in
                self?.applyProbes(probes, for: pid, spaceMap: spaceMap)
            }
        }
    }

    private func applyProbes(_ probes: [SwitcherWindowProbe], for pid: pid_t, spaceMap: [CGWindowID: [CGSSpaceID]]) {
        guard let app = apps[pid] else { return }
        var changed = false
        var seenWids = Set<CGWindowID>()
        let actualProbes = probes.filter { probe in
            SwitcherWindowDiscriminator.isActualWindow(
                bundleIdentifier: app.bundleIdentifier,
                wid: probe.wid,
                title: probe.title,
                subrole: probe.subrole,
                role: probe.role,
                size: probe.size
            )
        }
        let appHasTitledWindow = actualProbes.contains(where: \.hasExplicitTitle)
        for probe in actualProbes {
            if appHasTitledWindow && probe.isUntitledPlaceholderCandidate { continue }
            seenWids.insert(probe.wid)
            let resolvedTitle = SwitcherAxRead.bestEffortTitle(
                axTitle: probe.title,
                cgTitle: probe.cgTitle,
                appLocalizedName: app.localizedName
            )
            if let existing = windows[probe.wid] {
                if existing.title != resolvedTitle { existing.title = resolvedTitle; changed = true }
                if existing.isMinimized != probe.isMinimized { existing.isMinimized = probe.isMinimized; changed = true }
                if existing.isFullscreen != probe.isFullscreen { existing.isFullscreen = probe.isFullscreen; changed = true }
                if existing.position != probe.position { existing.position = probe.position; changed = true }
                if existing.size != probe.size { existing.size = probe.size; changed = true }
                let newSpaces = spaceMap[probe.wid] ?? []
                if existing.spaceIds != newSpaces { existing.spaceIds = newSpaces; changed = true }
            } else {
                let win = SwitcherWindow(
                    application: app,
                    cgWindowId: probe.wid,
                    axUiElement: probe.axUiElement,
                    title: resolvedTitle,
                    isMinimized: probe.isMinimized,
                    isFullscreen: probe.isFullscreen,
                    spaceIds: spaceMap[probe.wid] ?? [],
                    position: probe.position,
                    size: probe.size
                )
                // 新窗口排在末尾,等真实 focus 通知再上调
                win.lastFocusOrder = windows.count
                windows[probe.wid] = win
                // 订阅窗口级 AX 通知(destroy / minimize / title)
                subscribeWindowNotifications(win)
                // 预热抓取 —— 后台立刻抓这个新窗口的缩略图存进 win.thumbnail。
                // Cmd+Tab 召唤时这张图已经就位,用户感觉不到延迟。
                SwitcherThumbnails.shared.warmThumbnail(for: win)
                changed = true
            }
        }
        let stale = windows.values.filter { $0.application.pid == pid && !seenWids.contains($0.cgWindowId) }
        for w in stale {
            unsubscribeWindowNotifications(w)
            windows.removeValue(forKey: w.cgWindowId)
            changed = true
        }
        if changed {
            compactMRUOrdering()
            onListChanged?()
        }
    }

    /// 给单个 SwitcherWindow 订阅窗口级别的 AX 通知。
    private func subscribeWindowNotifications(_ window: SwitcherWindow) {
        guard let observer = window.application.axObserver else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in SwitcherWindow.observedNotifications {
            AXObserverAddNotification(observer, window.axUiElement, notification as CFString, refcon)
        }
    }

    /// 反订阅 —— 窗口移除前调,避免泄漏到 runloop 里。
    private func unsubscribeWindowNotifications(_ window: SwitcherWindow) {
        guard let observer = window.application.axObserver else { return }
        for notification in SwitcherWindow.observedNotifications {
            AXObserverRemoveNotification(observer, window.axUiElement, notification as CFString)
        }
    }

    /// 删除窗口后,把 lastFocusOrder 压回 [0..<count] 紧凑序列。
    /// 否则会出现 0, 2, 3, ... 这种洞 —— 排序不受影响,但 MRU 数字本身看着奇怪。
    private func compactMRUOrdering() {
        let sorted = windows.values.sorted { $0.lastFocusOrder < $1.lastFocusOrder }
        for (i, w) in sorted.enumerated() {
            w.lastFocusOrder = i
        }
    }

    // MARK: - AX 事件回调

    private static let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let list = Unmanaged<SwitcherWindowList>.fromOpaque(refcon).takeUnretainedValue()
        let type = notification as String
        // notification 在 main runloop 上触发 — 已经在主线程
        list.handleAxNotification(type, element: element)
    }

    private func handleAxNotification(_ type: String, element: AXUIElement) {
        switch type {
        // ---- 窗口级别通知 ----
        case kAXWindowMiniaturizedNotification:
            if let wid = SwitcherAxRead.cgWindowId(of: element),
               let w = windows[wid], !w.isMinimized
            {
                w.isMinimized = true
                onListChanged?()
            }
            return
        case kAXWindowDeminiaturizedNotification:
            if let wid = SwitcherAxRead.cgWindowId(of: element),
               let w = windows[wid], w.isMinimized
            {
                w.isMinimized = false
                onListChanged?()
            }
            return
        case kAXUIElementDestroyedNotification:
            // 销毁的 element 可能拿不到 wid(它已经从 CGS 里消失),退化到全量 sync
            if let wid = SwitcherAxRead.cgWindowId(of: element), let w = windows[wid] {
                unsubscribeWindowNotifications(w)
                windows.removeValue(forKey: wid)
                compactMRUOrdering()
                onListChanged?()
            } else if let pid = frontmostPid {
                syncWindowsForApp(pid: pid)
            }
            return
        case kAXTitleChangedNotification:
            // 标题更新 —— 通过对应 pid 的 sync 拿最新值。该 sync 是节流的,
            // 高频改名的 app 不会把我们 IPC 打爆。
            if let pid = frontmostPid {
                syncWindowsForApp(pid: pid)
            }
            return

        // ---- 应用级别通知 ----
        case kAXFocusedWindowChangedNotification, kAXApplicationActivatedNotification:
            updateFocusedWindowMRU()
            if let pid = frontmostPid {
                syncWindowsForApp(pid: pid)
            }
            return
        case kAXApplicationHiddenNotification, kAXApplicationShownNotification:
            refreshAppHiddenStates()
            onListChanged?()
            return
        case kAXWindowCreatedNotification:
            if let pid = frontmostPid {
                syncWindowsForApp(pid: pid)
            }
            return

        default:
            // 其他未识别通知保持原有"激活的 app 重扫一遍"逻辑
            if let pid = frontmostPid {
                syncWindowsForApp(pid: pid)
            }
        }
    }

    private func updateFocusedWindowMRU() {
        guard let pid = frontmostPid, let app = apps[pid] else { return }
        let axBox = SwitcherAxRefBox(element: app.axUiElement)
        AXCallQueue.shared.schedule("focus-\(pid)") { [weak self] in
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(axBox.element, kAXFocusedWindowAttribute as CFString, &value)
            guard result == .success, let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return }
            let axWindow = v as! AXUIElement
            guard let wid = SwitcherAxRead.cgWindowId(of: axWindow) else { return }
            Task { @MainActor [weak self] in
                self?.promoteToMostRecent(wid: wid)
            }
        }
    }

    private func promoteToMostRecent(wid: CGWindowID) {
        guard let promoted = windows[wid] else { return }
        if promoted.lastFocusOrder == 0 { return }
        let oldOrder = promoted.lastFocusOrder
        for (_, w) in windows where w.lastFocusOrder < oldOrder {
            w.lastFocusOrder += 1
        }
        promoted.lastFocusOrder = 0
        // 焦点窗口刚活跃过,内容大概率变了 —— 重新预热它的缩略图
        // (背景优先级,不抢 UI 主线程)
        SwitcherThumbnails.shared.warmThumbnail(for: promoted)
        onListChanged?()
    }

    private func refreshAppHiddenStates() {
        for (_, app) in apps {
            app.isHidden = app.runningApplication.isHidden
        }
    }

    // MARK: - 快照(给 UI 用)

    /// 应用完整 SwitcherPreferences 的快照 —— 过滤 + 排序一站式完成。
    /// Controller 真正调的就是这个版本。
    ///
    /// `panelScreen`:切换器面板即将弹出的屏幕。仅当 `screensToShow == .onlySwitcherScreen`
    /// 时用到 —— 过滤出在这个屏幕上的窗口。Controller 调用前算好传进来。
    func snapshot(applying prefs: SwitcherPreferences, panelScreen: NSScreen? = nil) -> [SwitcherWindow] {
        runGhostProbeIfDue()
        let visibleSpaces = SwitcherSpaces.visibleSpaceIds()
        let frontPid = frontmostPid

        let filtered = windows.values.filter { w in
            // ghost 永远不显示
            if w.isInvisible { return false }
            // 隐藏 app
            if prefs.hiddenWindows == .hide && w.isAppHidden { return false }
            // 最小化
            if prefs.minimizedWindows == .hide && w.isMinimized { return false }
            // 全屏
            if prefs.fullscreenWindows == .hide && w.isFullscreen { return false }
            // 应用范围(前台/非前台)
            switch prefs.appsToShow {
            case .all: break
            case .onlyActive:
                if w.application.pid != frontPid { return false }
            case .onlyNonActive:
                if w.application.pid == frontPid { return false }
            }
            // Space 范围
            switch prefs.spacesToShow {
            case .all: break
            case .visible:
                if w.spaceIds.allSatisfy({ !visibleSpaces.contains($0) }) { return false }
            case .nonVisible:
                if w.spaceIds.contains(where: { visibleSpaces.contains($0) }) { return false }
            }
            // 屏幕范围
            switch prefs.screensToShow {
            case .all: break
            case .onlySwitcherScreen:
                if let panelScreen, !w.isOnScreen(panelScreen) { return false }
            }
            return true
        }

        // 主排序后做 showAtEnd 分桶 —— hide 已经在 filter 里剔除,这里只需把
        // showAtEnd 状态的窗口推到末尾(在它们自己的 sort 顺序内保持)。
        let sorted = Self.sort(Array(filtered), by: prefs.sortBy)
        return Self.partitionShowAtEnd(sorted, prefs: prefs)
    }

    /// showAtEnd 三档实现:任何匹配 showAtEnd 条件的窗口移到列表末尾。
    /// 多个类型同时配 showAtEnd 时,共用一个"末尾桶",顺序仍按 sortBy 维持。
    private static func partitionShowAtEnd(_ windows: [SwitcherWindow], prefs: SwitcherPreferences) -> [SwitcherWindow] {
        func atEnd(_ w: SwitcherWindow) -> Bool {
            if prefs.minimizedWindows == .showAtEnd && w.isMinimized { return true }
            if prefs.hiddenWindows == .showAtEnd && w.isAppHidden { return true }
            if prefs.fullscreenWindows == .showAtEnd && w.isFullscreen { return true }
            // windowlessApps 我们 P4 还没有这种类型的窗口
            return false
        }
        var normal: [SwitcherWindow] = []
        var ending: [SwitcherWindow] = []
        for w in windows {
            if atEnd(w) { ending.append(w) } else { normal.append(w) }
        }
        return normal + ending
    }

    /// 根据 sort order 排序。lastFocusOrder 是 tie-breaker。
    private static func sort(_ windows: [SwitcherWindow], by order: SwitcherSortOrder) -> [SwitcherWindow] {
        switch order {
        case .recentlyFocused:
            return windows.sorted { $0.lastFocusOrder < $1.lastFocusOrder }
        case .recentlyCreated:
            // SwitcherWindow 没有 creationOrder 字段,目前退化到 wid 倒序
            // (wid 单调递增,新窗口 wid 大)—— P4 加正式的 creationOrder
            return windows.sorted { $0.cgWindowId > $1.cgWindowId }
        case .alphabetical:
            return windows.sorted { a, b in
                let an = a.application.localizedName ?? ""
                let bn = b.application.localizedName ?? ""
                let c = an.localizedStandardCompare(bn)
                if c != .orderedSame { return c == .orderedAscending }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        case .bySpace:
            return windows.sorted { a, b in
                let aSpace = a.spaceIds.first ?? CGSSpaceID.max
                let bSpace = b.spaceIds.first ?? CGSSpaceID.max
                if aSpace != bSpace { return aSpace < bSpace }
                return a.lastFocusOrder < b.lastFocusOrder
            }
        }
    }

    /// 不看节流立刻派发一次探针。snapshot 路径用 runGhostProbeIfDue 包了 500ms 节流。
    private func runGhostProbeNow() {
        lastGhostProbeTime = CFAbsoluteTimeGetCurrent()
        let allSpaces = SwitcherSpaces.allSpaceIds()
        let visibleSpaces = SwitcherSpaces.visibleSpaceIds()
        let snapshotWindows = Array(windows.values)
        AXCallQueue.shared.submit { [weak self] in
            let probe = SwitcherGhostDetector.probe(across: allSpaces)
            Task { @MainActor [weak self] in
                self?.applyGhostProbe(probe, visibleSpaces: visibleSpaces, against: snapshotWindows)
            }
        }
    }

    private func applyGhostProbe(_ probe: WindowVisibilityProbe, visibleSpaces: Set<CGSSpaceID>, against snapshotWindows: [SwitcherWindow]) {
        var anyChanged = false
        for w in snapshotWindows {
            guard windows[w.cgWindowId] === w else { continue }
            let newValue = SwitcherGhostDetector.isInvisible(
                wid: w.cgWindowId,
                isMinimized: w.isMinimized,
                isAppHidden: w.isAppHidden,
                isTabbed: false,
                windowSpaceIds: w.spaceIds,
                visibleSpaceIds: visibleSpaces,
                probe: probe
            )
            if w.isInvisible != newValue {
                w.isInvisible = newValue
                anyChanged = true
            }
        }
        if anyChanged { onListChanged?() }
    }

    private func runGhostProbeIfDue() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastGhostProbeTime > 0.5 else { return }
        runGhostProbeNow()
    }
}
