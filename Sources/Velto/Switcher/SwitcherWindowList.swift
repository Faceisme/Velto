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
    let hasOnlyWindowChromeChildren: Bool

    func hasUserVisibleTitle(appLocalizedName: String?) -> Bool {
        if Self.normalizedTitle(cgTitle) != nil { return true }
        guard let title = Self.normalizedTitle(title) else { return false }
        return !Self.isSyntheticWindowTitle(title, appLocalizedName: appLocalizedName)
    }

    func shouldHideSyntheticSwitcherWindow(bundleIdentifier: String?, appLocalizedName: String?) -> Bool {
        guard !isMinimized,
              Self.normalizedTitle(cgTitle) == nil,
              AppQuirks.hidesSyntheticSwitcherWindows(
                bundleIdentifier: bundleIdentifier,
                appName: appLocalizedName
              )
        else {
            return false
        }

        if let title = Self.normalizedTitle(title) {
            return Self.isSyntheticWindowTitle(title, appLocalizedName: appLocalizedName)
        }

        return hasOnlyWindowChromeChildren
    }

    static func hasNoTitle(axTitle: String?, cgTitle: String?) -> Bool {
        normalizedTitle(axTitle) == nil && normalizedTitle(cgTitle) == nil
    }

    static func hasOnlyWindowChromeChildren(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let children = value as? [AXUIElement] else { return false }
        guard !children.isEmpty else { return true }
        return children.allSatisfy(isChromeOnlyChild)
    }

    private static func isChromeOnlyChild(_ child: AXUIElement) -> Bool {
        let attrs = SwitcherAxRead.multiAttributes(child, [
            kAXRoleAttribute as String,
            kAXSubroleAttribute as String,
            kAXTitleAttribute as String,
            kAXValueAttribute as String,
            kAXSizeAttribute as String,
        ])
        let role = attrs[kAXRoleAttribute as String] as? String
        if role == kAXButtonRole as String,
           let subrole = attrs[kAXSubroleAttribute as String] as? String,
           windowChromeButtonSubroles.contains(subrole)
        {
            return true
        }
        // 微信 4.x 在合成空窗里塞了一个 10x16 的无字 AXStaticText 占位元素。
        // 视为 chrome 一类 —— 真主窗不会出现"全是 chrome + 微型空文本"的组合。
        if role == kAXStaticTextRole as String,
           let raw = attrs[kAXSizeAttribute as String],
           let size = SwitcherAxRead.axValueSize(raw),
           size.width < 40, size.height < 40
        {
            let title = (attrs[kAXTitleAttribute as String] as? String) ?? ""
            let valueStr = (attrs[kAXValueAttribute as String] as? String) ?? ""
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = valueStr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTitle.isEmpty && trimmedValue.isEmpty
        }
        return false
    }

    private static let windowChromeButtonSubroles: Set<String> = [
        kAXCloseButtonSubrole as String,
        kAXMinimizeButtonSubrole as String,
        kAXZoomButtonSubrole as String,
        "AXFullScreenButton",
        "AXToolbarButton",
    ]

    var isUntitledPlaceholderCandidate: Bool {
        Self.normalizedTitle(title) == nil && Self.normalizedTitle(cgTitle) == nil && !isMinimized
    }

    private static func normalizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isSyntheticWindowTitle(_ title: String, appLocalizedName: String?) -> Bool {
        AppQuirks.isSyntheticSwitcherWindowTitle(title, appName: appLocalizedName)
    }
}

/// AX 字符串常量 —— 这两个在某些 SDK 版本里没桥接成 Swift 常量,直接用字符串。
private let kAXFullScreenAttribute = "AXFullScreen"

/// 缺失窗口的删除策略。
///
/// 普通 AX 扫描可能因为目标 app 短暂无响应漏掉窗口,所以保留两次 miss 才删。
/// 但关闭 / 最小化这类明确窗口状态通知已经说明窗口集合或可见性发生变化,
/// 这时继续等第二次扫描会让 Cmd+Tab 列表残留一次。
enum SwitcherWindowMissPolicy {
    case routineScan
    case explicitWindowStateChange

    var removalThreshold: Int {
        switch self {
        case .routineScan:
            return 2
        case .explicitWindowStateChange:
            return 1
        }
    }
}

struct SwitcherWindowMissState {
    private(set) var count: Int

    init(count: Int = 0) {
        self.count = max(0, count)
    }

    mutating func markSeen() {
        count = 0
    }

    mutating func recordMiss(using policy: SwitcherWindowMissPolicy) -> Bool {
        count += 1
        return count >= policy.removalThreshold
    }
}

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

    /// 是否维护窗口索引。切换器关闭时置 false —— 跳过 AX 全量扫描与缩略图预热这些重活
    /// (观察者仍在,但回调里直接 return,几乎零开销);重新开启时全量补一次。
    /// 只在主线程(AX 回调 / 偏好变更都在主线程)读写。
    private(set) var maintainsIndex = true

    private var didInitialize = false
    private var lastGhostProbeTime: TimeInterval = 0
    /// 已经派发了 ghost probe 还没回来。AXCallQueue 串行所以不会真并发,
    /// 但 in-flight 期间再派只会让 probe 堆积在队尾 —— 用这个旗子直接挡掉。
    private var ghostProbeInFlight = false

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
        // 首次发现这个 app:跑一次暴力枚举,把它在所有 Space 上的窗口一次性收齐。
        syncWindowsForApp(pid: pid, includeBruteForce: true)
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
        }
    }

    // MARK: - 窗口同步

    /// 由 SwitcherController 按"切换器是否启用"驱动。关闭时停掉后台扫描/缩略图预热;
    /// 重新开启时全量补一次(把禁用期间漏掉的窗口变化补回来)。主线程调用。
    func setMaintainsIndex(_ enabled: Bool) {
        guard maintainsIndex != enabled else { return }
        maintainsIndex = enabled
        if enabled {
            for pid in apps.keys {
                syncWindowsForApp(pid: pid, includeBruteForce: true)
            }
        }
    }

    private func syncWindowsForApp(
        pid: pid_t,
        includeBruteForce: Bool = false,
        missingWindowPolicy: SwitcherWindowMissPolicy = .routineScan
    ) {
        guard maintainsIndex else { return }
        guard let app = apps[pid] else { return }
        AXCallQueue.shared.schedule("sync-\(pid)") { [weak self] in
            guard let axWindows = app.copyAxWindows(includeBruteForce: includeBruteForce) else { return }
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
                let cgTitle = SwitcherAxRead.cgTitle(for: wid)
                let hasOnlyWindowChromeChildren: Bool
                if AppQuirks.hidesSyntheticSwitcherWindows(
                    bundleIdentifier: app.bundleIdentifier,
                    appName: app.localizedName
                ),
                   SwitcherWindowProbe.hasNoTitle(axTitle: axTitle, cgTitle: cgTitle)
                {
                    hasOnlyWindowChromeChildren = SwitcherWindowProbe.hasOnlyWindowChromeChildren(ax)
                } else {
                    hasOnlyWindowChromeChildren = false
                }
                return SwitcherWindowProbe(
                    axUiElement: ax,
                    wid: wid,
                    title: axTitle,
                    cgTitle: cgTitle,
                    subrole: attrs[kAXSubroleAttribute as String] as? String,
                    role: attrs[kAXRoleAttribute as String] as? String,
                    size: size,
                    position: position,
                    isMinimized: (attrs[kAXMinimizedAttribute as String] as? Bool) ?? false,
                    isFullscreen: (attrs[kAXFullScreenAttribute] as? Bool) ?? false,
                    hasOnlyWindowChromeChildren: hasOnlyWindowChromeChildren
                )
            }
            let spaceMap = SwitcherSpaces.spaces(forWindowIds: probes.map(\.wid))
            Task { @MainActor [weak self] in
                self?.applyProbes(
                    probes,
                    for: pid,
                    spaceMap: spaceMap,
                    missingWindowPolicy: missingWindowPolicy
                )
            }
        }
    }

    private func applyProbes(
        _ probes: [SwitcherWindowProbe],
        for pid: pid_t,
        spaceMap: [CGWindowID: [CGSSpaceID]],
        missingWindowPolicy: SwitcherWindowMissPolicy = .routineScan
    ) {
        guard let app = apps[pid] else { return }
        // 窗口集合变化(新增 / 删除)—— 仅这种情况需要重排 lastFocusOrder。
        // 字段更新(title/size/...)不影响 MRU 序,不触发 compact。
        var setChanged = false
        var seenWids = Set<CGWindowID>()
        let traceApp = SwitcherDebugLog.shouldTrace(bundleIdentifier: app.bundleIdentifier, appName: app.localizedName)
        let actualProbes = probes.filter { probe in
            let keep = SwitcherWindowDiscriminator.isActualWindow(
                bundleIdentifier: app.bundleIdentifier,
                wid: probe.wid,
                title: probe.title,
                subrole: probe.subrole,
                role: probe.role,
                size: probe.size
            )
            if traceApp && !keep {
                SwitcherDebugLog.log("  applyProbes DROP wid=\(probe.wid) reason=isActualWindow=false subrole=\(probe.subrole ?? "-") size=\(probe.size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-")")
            }
            return keep
        }
        let appHasTitledWindow = actualProbes.contains { $0.hasUserVisibleTitle(appLocalizedName: app.localizedName) }
        if traceApp {
            SwitcherDebugLog.log("  applyProbes pid=\(pid) actualCount=\(actualProbes.count) appHasTitledWindow=\(appHasTitledWindow)")
        }
        for probe in actualProbes {
            if probe.shouldHideSyntheticSwitcherWindow(
                bundleIdentifier: app.bundleIdentifier,
                appLocalizedName: app.localizedName
            ) {
                if traceApp { SwitcherDebugLog.log("    DROP wid=\(probe.wid) reason=shouldHideSyntheticSwitcherWindow") }
                continue
            }
            if appHasTitledWindow && probe.isUntitledPlaceholderCandidate {
                if traceApp { SwitcherDebugLog.log("    DROP wid=\(probe.wid) reason=untitledPlaceholderCandidate") }
                continue
            }
            if traceApp { SwitcherDebugLog.log("    KEEP wid=\(probe.wid) axTitle=\"\(probe.title ?? "<nil>")\" cgTitle=\"\(probe.cgTitle ?? "<nil>")\"") }
            seenWids.insert(probe.wid)
            let resolvedTitle = SwitcherAxRead.bestEffortTitle(
                axTitle: probe.title,
                cgTitle: probe.cgTitle,
                appLocalizedName: app.localizedName
            )
            if let existing = windows[probe.wid] {
                var missState = SwitcherWindowMissState(count: existing.missCount)
                missState.markSeen()
                existing.missCount = missState.count   // 本轮扫描到了 → 清零移除计数
                if existing.title != resolvedTitle { existing.title = resolvedTitle }
                if existing.isMinimized != probe.isMinimized { existing.isMinimized = probe.isMinimized }
                if existing.isFullscreen != probe.isFullscreen { existing.isFullscreen = probe.isFullscreen }
                if existing.position != probe.position { existing.position = probe.position }
                if existing.size != probe.size { existing.size = probe.size }
                let newSpaces = spaceMap[probe.wid] ?? []
                if existing.spaceIds != newSpaces { existing.spaceIds = newSpaces }
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
                setChanged = true
            }
        }
        // 移除策略:
        // - 例行扫描:连续两次 miss 才删,防 AX 瞬时漏报。
        // - 明确窗口状态变化:一次 miss 就删,防关闭/最小化后 Cmd+Tab 列表残留。
        let missed = windows.values.filter { $0.application.pid == pid && !seenWids.contains($0.cgWindowId) }
        for w in missed {
            var missState = SwitcherWindowMissState(count: w.missCount)
            if missState.recordMiss(using: missingWindowPolicy) {
                removeWindow(w, compact: false)
                setChanged = true
            } else {
                w.missCount = missState.count
            }
        }
        if setChanged {
            compactMRUOrdering()
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

    private func window(matching element: AXUIElement) -> SwitcherWindow? {
        if let wid = SwitcherAxRead.cgWindowId(of: element),
           let window = windows[wid]
        {
            return window
        }
        return windows.values.first { CFEqual($0.axUiElement, element) }
    }

    @discardableResult
    private func removeWindow(_ window: SwitcherWindow, compact: Bool = true) -> Bool {
        guard windows[window.cgWindowId] === window else { return false }
        unsubscribeWindowNotifications(window)
        windows.removeValue(forKey: window.cgWindowId)
        if compact {
            compactMRUOrdering()
        }
        return true
    }

    @discardableResult
    private func updateMinimizedState(for element: AXUIElement, isMinimized: Bool) -> Bool {
        guard let window = window(matching: element) else { return false }
        window.missCount = 0
        if window.isMinimized != isMinimized {
            window.isMinimized = isMinimized
        }
        return true
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

    /// 取触发通知的 AX element 所属进程 pid。AXObserver 是按 app 装的,element 归属
    /// 哪个 app 是确定的 —— 用它而不是 frontmostPid,后台 app 建/删窗口才不会同步错对象。
    /// `AXUIElementGetPid` 只读 element 内部 token,不向 app 发消息,销毁的 element 也能拿到。
    private func pidOfElement(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private func handleAxNotification(_ type: String, element: AXUIElement) {
        // 只处理 SwitcherApp.observedNotifications / SwitcherWindow.observedNotifications
        // 里明确订阅的通知,其他都不可能到这。不写 default 分支,免得未来加新订阅
        // 时忘了在这补 case 还以为有兜底。
        switch type {
        // ---- 窗口级别通知 ----
        case kAXWindowMiniaturizedNotification:
            if !updateMinimizedState(for: element, isMinimized: true),
               let pid = pidOfElement(element) ?? frontmostPid
            {
                syncWindowsForApp(pid: pid, missingWindowPolicy: .explicitWindowStateChange)
            }
        case kAXWindowDeminiaturizedNotification:
            if !updateMinimizedState(for: element, isMinimized: false),
               let pid = pidOfElement(element) ?? frontmostPid
            {
                syncWindowsForApp(pid: pid, missingWindowPolicy: .explicitWindowStateChange)
            }
        case kAXUIElementDestroyedNotification:
            // 销毁的 element 可能拿不到 wid(它已经从 CGS 里消失),退化到全量 sync
            if let window = window(matching: element) {
                removeWindow(window)
            } else if let pid = pidOfElement(element) ?? frontmostPid {
                syncWindowsForApp(pid: pid, missingWindowPolicy: .explicitWindowStateChange)
            }
        case kAXTitleChangedNotification:
            // 标题更新 —— Chrome / Slack / Xcode 改一个 tab 的标题就触发,频率
            // 极高。走轻量路径:只读这一个窗口的 title,不走全量 sync(就不会
            // 触发 100ms 暴力枚举 + 全 app 窗口属性读取)。
            updateTitleForWindow(element)

        // ---- 应用级别通知 ----
        case kAXFocusedWindowChangedNotification, kAXApplicationActivatedNotification:
            updateFocusedWindowMRU()
            if let pid = pidOfElement(element) ?? frontmostPid {
                syncWindowsForApp(pid: pid)
            }
        case kAXApplicationHiddenNotification, kAXApplicationShownNotification:
            refreshAppHiddenStates()
        case kAXWindowCreatedNotification:
            // 新窗口有可能直接开在别的 Space 上(用户从菜单栏新建窗口时常见),
            // 标准 AX 路径只拿当前 Space —— 这种 case 必须叠上暴力枚举才能抓到。
            // 用事件来源 app 的 pid:后台 app 新建窗口也能同步到正确的 app。
            if let pid = pidOfElement(element) ?? frontmostPid {
                syncWindowsForApp(pid: pid, includeBruteForce: true)
            }

        default:
            break
        }
    }

    /// kAXTitleChangedNotification 专用的轻量更新路径。
    /// 后台只对单个 AXUIElement 读 title,完了主线程写回。
    /// 跟 syncWindowsForApp 比省掉了:全量窗口枚举、N 个 multiAttributes 读、
    /// brute force 100ms。
    private func updateTitleForWindow(_ element: AXUIElement) {
        // 主线程拿 wid:_AXUIElementGetWindow 是本进程内的查询,廉价。
        guard let wid = SwitcherAxRead.cgWindowId(of: element),
              let existing = windows[wid] else { return }
        let appLocalizedName = existing.application.localizedName
        let elementBox = SwitcherAxRefBox(element: element)
        AXCallQueue.shared.schedule("title-\(wid)") { [weak self] in
            var v: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(elementBox.element, kAXTitleAttribute as CFString, &v)
            let axTitle = (result == .success ? v as? String : nil)
            let cgTitle = SwitcherAxRead.cgTitle(for: wid)
            let resolved = SwitcherAxRead.bestEffortTitle(
                axTitle: axTitle,
                cgTitle: cgTitle,
                appLocalizedName: appLocalizedName
            )
            Task { @MainActor [weak self] in
                guard let self, let w = self.windows[wid], w === existing else { return }
                if w.title != resolved { w.title = resolved }
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
    }

    /// 切换器**确认切换**到某窗口时由 Controller 同步调用 —— 立刻把它顶到 MRU
    /// 最前并更新 frontmostPid,**不等**异步的 AX activate 通知。
    ///
    /// 为什么必须同步:`SwitcherFocus.raise` 只做 SLPS/AX 抬窗,MRU 重排全靠
    /// 异步 `kAXApplicationActivatedNotification` → `updateFocusedWindowMRU`
    /// (还依赖 `frontmostPid` 这条 NSWorkspace 通知,两条通知谁先到是竞态的)。
    /// 快速连切时,下一次 trigger 的 snapshot 往往在通知到达前就取了,MRU 还是
    /// 旧序 —— 刚切到的窗口仍排在 index 1,于是 `initialSelection = 1` 又选中它,
    /// 表现为"切了等于没切,总停在当前 app"。这里乐观地先把 MRU 改对。
    /// 万一 raise 实际失败,后续真实的 activate 通知会再纠正,可自愈。
    func promoteForConfirmedSwitch(window: SwitcherWindow) {
        frontmostPid = window.application.pid
        promoteToMostRecent(wid: window.cgWindowId)
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
        var currentOnScreenWindowIds: Set<CGWindowID>?

        func isCurrentlyOnScreen(_ wid: CGWindowID) -> Bool {
            if currentOnScreenWindowIds == nil {
                currentOnScreenWindowIds = Self.currentOnScreenWindowIds()
            }
            return currentOnScreenWindowIds?.contains(wid) ?? false
        }

        let filtered = windows.values.filter { w in
            let traceWin = SwitcherDebugLog.shouldTrace(
                bundleIdentifier: w.application.bundleIdentifier,
                appName: w.application.localizedName
            )
            // ghost 永远不显示
            if w.isInvisible {
                if traceWin { SwitcherDebugLog.log("snapshot DROP wid=\(w.cgWindowId) title=\"\(w.title)\" reason=isInvisible") }
                return false
            }
            // 部分 App 会留下 AX 能枚举到、但 WindowServer 已不再认为可见的
            // 合成标题窗口。选中它会把透明/空白壳激活出来,所以在快照时再查一次。
            if AppQuirks.hidesSyntheticSwitcherWindows(
                bundleIdentifier: w.application.bundleIdentifier,
                appName: w.application.localizedName
            ),
               AppQuirks.isSyntheticSwitcherWindowTitle(w.title, appName: w.application.localizedName),
               !w.isMinimized,
               !isCurrentlyOnScreen(w.cgWindowId)
            {
                if traceWin { SwitcherDebugLog.log("snapshot DROP wid=\(w.cgWindowId) title=\"\(w.title)\" reason=syntheticOffscreen") }
                return false
            }
            if traceWin {
                let posStr = w.position.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "-"
                let sizeStr = w.size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
                let onScreen = isCurrentlyOnScreen(w.cgWindowId)
                let isSynthetic = AppQuirks.isSyntheticSwitcherWindowTitle(w.title, appName: w.application.localizedName)
                SwitcherDebugLog.log("snapshot KEEP-candidate wid=\(w.cgWindowId) title=\"\(w.title)\" pos=\(posStr) size=\(sizeStr) minimized=\(w.isMinimized) fullscreen=\(w.isFullscreen) onScreen=\(onScreen) isSyntheticTitle=\(isSynthetic) spaces=\(w.spaceIds)")
            }
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
        let partitioned = Self.partitionShowAtEnd(sorted, prefs: prefs)
        return Self.collapsePerApp(partitioned, mode: prefs.groupBy)
    }

    /// perApp 模式:每个 app 在结果里只保留第一个出现的窗口(也就是排序后
    /// 该 app 最靠前的那个)。perWindow 模式原样返回。
    /// 选中后激活那个代表窗口,macOS 自然会带出整个 app。
    private static func collapsePerApp(_ windows: [SwitcherWindow], mode: SwitcherGroupingMode) -> [SwitcherWindow] {
        guard mode == .perApp else { return windows }
        var seen = Set<pid_t>()
        var result: [SwitcherWindow] = []
        result.reserveCapacity(windows.count)
        for w in windows where seen.insert(w.application.pid).inserted {
            result.append(w)
        }
        return result
    }

    private static func currentOnScreenWindowIds() -> Set<CGWindowID> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return Set(info.compactMap { row -> CGWindowID? in
            let value = row[kCGWindowNumber as String]
            if let id = value as? CGWindowID { return id }
            if let number = value as? NSNumber { return CGWindowID(truncating: number) }
            if let int = value as? Int { return CGWindowID(int) }
            return nil
        })
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
        guard !ghostProbeInFlight else { return }
        ghostProbeInFlight = true
        let allSpaces = SwitcherSpaces.allSpaceIds()
        let visibleSpaces = SwitcherSpaces.visibleSpaceIds()
        let snapshotWindows = Array(windows.values)
        // ghost probe 走的是 CGS API(SwitcherSpaces),不是 AX,跟 AXCallQueue
        // 的串行锁没冲突。放进 detached task,不要白白堵 AX 队列后面的 title /
        // sync 工作。in-flight 旗子已经保证不会并发多个 probe。
        Task.detached(priority: .userInitiated) { [weak self] in
            let probe = SwitcherGhostDetector.probe(across: allSpaces)
            await MainActor.run { [weak self] in
                self?.applyGhostProbe(probe, visibleSpaces: visibleSpaces, against: snapshotWindows)
            }
        }
    }

    private func applyGhostProbe(_ probe: WindowVisibilityProbe, visibleSpaces: Set<CGSSpaceID>, against snapshotWindows: [SwitcherWindow]) {
        // probe 真正回来才记时间戳 —— 节流以"上次完成"为锚,卡死的 probe 不会
        // 让我们一直派新的。
        lastGhostProbeTime = CFAbsoluteTimeGetCurrent()
        ghostProbeInFlight = false
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
            }
        }
    }

    /// 把缩略图缓存压到 top-keep 个 MRU 窗口以内。session 结束 N 分钟后由
    /// controller 调,避免 500+ 窗口场景下 thumbnail 永久驻留把内存撑到 100MB+。
    /// 被裁掉的窗口下次进入 switcher 时,SwitcherThumbnails 会重新抓。
    func trimThumbnails(keepTop: Int) {
        let ranked = windows.values.sorted { $0.lastFocusOrder < $1.lastFocusOrder }
        guard ranked.count > keepTop else { return }
        for w in ranked.dropFirst(keepTop) where w.thumbnail != nil {
            w.thumbnail = nil
        }
    }

    private func runGhostProbeIfDue() {
        guard !ghostProbeInFlight else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastGhostProbeTime > 0.5 else { return }
        runGhostProbeNow()
    }
}
