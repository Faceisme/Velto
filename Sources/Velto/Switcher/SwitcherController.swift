import Cocoa

/// 切换器面板的确认节流状态。
///
/// 快速 `⌘+Tab` 时,`keyDown` 会被 tap 线程先吞掉,随后主线程显示 panel。
/// 如果用户马上松开 `⌘`,确认事件可能在 panel 刚显示甚至还没显示时到达。
/// 保留一个最短可见时长,保证被我们接管的快捷键一定有可见反馈。
struct SwitcherPanelVisibilityState {
    let minimumVisibleDuration: TimeInterval
    /// "release 先于 trigger 到达"的合法乱序窗口只有几毫秒;超过这个年龄的
    /// 挂起确认视为脏残留(比如 ⌘⇧+Tab 松开时两次 flagsChanged 连发两个
    /// release,第二个撞上 session==nil),消费时直接丢弃 —— 否则下一次
    /// 按住触发键想浏览时,面板会一闪立刻自动确认。
    let pendingConfirmMaxAge: TimeInterval

    private var shownAt: TimeInterval?
    private var pendingConfirmNotedAt: TimeInterval?

    init(minimumVisibleDuration: TimeInterval = 0.12, pendingConfirmMaxAge: TimeInterval = 0.3) {
        self.minimumVisibleDuration = minimumVisibleDuration
        self.pendingConfirmMaxAge = pendingConfirmMaxAge
    }

    mutating func markShown(at timestamp: TimeInterval) {
        shownAt = timestamp
    }

    mutating func clear() {
        shownAt = nil
        pendingConfirmNotedAt = nil
    }

    func confirmDelay(at timestamp: TimeInterval) -> TimeInterval {
        guard let shownAt else { return 0 }
        return max(0, minimumVisibleDuration - (timestamp - shownAt))
    }

    mutating func noteConfirmBeforeSession(at timestamp: TimeInterval) {
        pendingConfirmNotedAt = timestamp
    }

    mutating func consumePendingConfirmForShownSession(at timestamp: TimeInterval) -> Bool {
        guard let notedAt = pendingConfirmNotedAt else { return false }
        pendingConfirmNotedAt = nil
        return timestamp - notedAt <= pendingConfirmMaxAge
    }
}

/// 切换器总指挥。它把所有子系统粘起来:
///
///   KeyTap ──事件──→ Controller ──┬──→ WindowList(取快照)
///                                 ├──→ Session(选中下标)
///                                 ├──→ Panel(显示 / 隐藏 / 选中态)
///                                 └──→ Focus(松开后切换)
///
/// 状态机:
///
///   idle ──.trigger──→ active(panel 显示,session.selectedIndex 已挪到下一个)
///   active ──.step──→ active(selectedIndex 移动)
///   active ──.releaseModifier──→ idle(focus 选中窗口,panel 隐)
///   active ──.cancel──→ idle(panel 直接隐,不切窗口)
///
/// 单例,AppDelegate 持有。
@MainActor
final class SwitcherController {
    static let shared = SwitcherController()

    private let keyTap = SwitcherKeyTap()
    private let windowList = SwitcherWindowList.shared
    /// 第一次 trigger 时探一下 Screen Recording 权限 —— 没有就引导用户授权。
    /// 只探一次,授权后需要重启才生效,所以多次 prompt 没意义。
    private var didPromptForScreenRecording = false
    /// session 结束后挂起的 thumbnail 裁剪任务 —— 2 分钟没新 session 就把 MRU
    /// 之外的窗口缩略图清掉。下次 trigger 会取消它。
    private var thumbnailTrimTask: Task<Void, Never>?
    private static let thumbnailTrimDelayNanos: UInt64 = 120 * 1_000_000_000
    private static let thumbnailTrimKeepTop = 100
    /// 确认节流状态。minimumVisibleDuration 置 0 —— 松手即刻 raise(Win11 同款
    /// 体感)。曾经的 120ms"最短可见"会让快速 tap-tap(间隔 <120ms)的第二次
    /// trigger 撞上未开火的 pendingConfirm:确认被取消、在**旧快照**里 step 到
    /// index 2,表现为"想 A↔B 却切到第三个 app / 概率切换失败"。即时确认后每次
    /// tap-release 独立完成,MRU 同步推进,快速交替永远正确。
    /// struct 本身保留:pendingConfirmMaxAge 的乱序 latch(release 先于 trigger
    /// 到达)仍然在用,那是独立机制,不回退。
    private var panelVisibility = SwitcherPanelVisibilityState(minimumVisibleDuration: 0)
    private var pendingConfirmTask: Task<Void, Never>?
    /// panel 是 lazy 创建 —— 第一次 trigger 时才实例化,避免拖慢启动
    private var _panel: SwitcherPanel?
    private var panel: SwitcherPanel {
        if let _panel { return _panel }
        let p = SwitcherPanel.shared
        // 接收 panel 内的 hover / click 事件
        p.tilesView.onHover = { [weak self] index in
            self?.handleHover(index)
        }
        p.tilesView.onClick = { [weak self] index in
            self?.handleClick(index)
        }
        _panel = p
        return p
    }

    private init() {}

    // MARK: - 生命周期

    @discardableResult
    func start() -> Bool {
        // 在 windowList.start() 之前定好维护开关:切换器禁用时连首次全量扫描都跳过。
        windowList.setMaintainsIndex(GestureStore.shared.preferences.switcher.enabled)
        windowList.start()
        keyTap.onEvent = { [weak self] event in
            // KeyTap 回调在 tap 线程,所有 UI / 状态修改必须跳回 main
            Task { @MainActor [weak self] in
                self?.handleKeyEvent(event)
            }
        }
        let started = keyTap.start()
        // 预热 panel:玻璃视图 + NSPanel 的构造有可感知成本,懒加载会把它记在
        // 首次 ⌘Tab 的账上("第一下特别慢")。启动后空转一圈 runloop 再实例化,
        // 不挡 start() 本身。
        Task { @MainActor [weak self] in
            _ = self?.panel
        }
        // 同步偏好里的开关 + 触发快捷键到 KeyTap,再订阅未来变化做实时同步
        applyPreferencesToKeyTap()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChanged),
            name: .gestureStoreDidChange,
            object: GestureStore.shared
        )
        return started
    }

    @objc private func handleStoreChanged(_ note: Notification) {
        // 关心的只是 preferences 变化(手势列表变化跟我们无关)
        guard note.gestureStoreChangeReason == .preferences ||
                note.gestureStoreChangeReason == .backupImport else { return }
        applyPreferencesToKeyTap()
    }

    private func applyPreferencesToKeyTap() {
        let prefs = GestureStore.shared.preferences.switcher
        keyTap.setSwitcherEnabled(prefs.enabled)
        keyTap.setTriggerShortcut(prefs.triggerShortcut)
        SwitcherDebugLog.setEnabled(prefs.debugLoggingEnabled)
        // 禁用时停后台 AX 扫描 / 缩略图预热;重新启用时全量补一次。
        windowList.setMaintainsIndex(prefs.enabled)
    }

    /// 按用户偏好算 panel 即将出现的屏幕 —— 用于"屏幕过滤"过滤窗口、以及
    /// panel 自己定位。
    static func resolvePanelScreen(for choice: SwitcherScreenChoice) -> NSScreen {
        switch choice {
        case .mouse:
            return NSScreen.screenContainingMouse() ?? NSScreen.main ?? NSScreen.screens.first!
        case .active:
            // "活跃屏幕" = 有 active menubar 的屏幕,简化为前台 app 的 key window 所在屏幕
            return NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first!
        case .main:
            return NSScreen.main ?? NSScreen.screens.first!
        }
    }

    /// app 退出时**必须**调,否则系统 Cmd+Tab 一直处于关闭状态。
    func stop() {
        keyTap.stop()
        // 如果切换器正显示,直接结束 session
        hidePanelIfShown()
    }

    // MARK: - 事件处理

    private func handleKeyEvent(_ event: SwitcherKeyEvent) {
        switch event {
        case .trigger(let reverse):
            triggerOrCycle(reverse: reverse)
        case .step(let reverse):
            stepSelection(reverse: reverse)
        case .releaseModifier:
            confirmAndDismiss()
        case .cancel:
            cancelAndDismiss()
        }
    }

    private func triggerOrCycle(reverse: Bool) {
        let prefs = GestureStore.shared.preferences.switcher
        // 总开关关掉时,直接不响应触发 —— 让 KeyTap 把事件透传给系统。
        // 注意:KeyTap 本身已经禁了系统 Cmd+Tab,所以"透传"在用户视角就是
        // ⌘+Tab 没反应。P3 第一版接受这个行为;P4 可以加"切回系统 switcher"。
        guard prefs.enabled else { return }
        SwitcherDebugLog.log("trigger reverse=\(reverse) sessionActive=\(SwitcherSession.isActive)")

        if SwitcherSession.isActive {
            // 用户在延迟确认生效前又按下了触发键 —— 重新进入浏览。旧的挂起
            // 确认作废,等这一次的松手重新确认;否则它会在用户按着触发键看
            // 面板时到点开火,把 session 收掉。此刻触发键的 modifier 必然是
            // 按下的,后续一定会有 release 来重新走确认,不会挂起。
            pendingConfirmTask?.cancel()
            pendingConfirmTask = nil
            stepSelection(reverse: reverse)
            return
        }
        // 新 session 起来了 —— 把上次 dismiss 后挂的"清缩略图"任务取消,
        // 避免它在 session 进行中把 MRU 之外的窗口缩略图清掉。
        cancelThumbnailTrim()
        // 首次召唤:取快照、起 session、显示 panel。
        // snapshot(applying:) 把过滤 + 排序全部按 prefs 跑完。
        let panelScreen = Self.resolvePanelScreen(for: prefs.showOnScreen)
        // 取快照前以系统前台 app 为权威同步校正 MRU —— 鼠标/Dock 切换焦点后的
        // MRU 提升走异步 AX 链,快速触发时往往还没落地,index 1 会仍是当前
        // 窗口,确认后表现为"切了等于没切"。
        windowList.reconcileFrontmostWithSystem()
        let snapshot = windowList.snapshot(applying: prefs, panelScreen: panelScreen)
        guard !snapshot.isEmpty else {
            SwitcherDebugLog.log("summon aborted: 没有可切换的窗口")
            panelVisibility.clear()
            NSSound.beep()
            return
        }
        SwitcherDebugLog.log("summon windowCount=\(snapshot.count) style=\(prefs.appearanceStyle) groupBy=\(prefs.groupBy) screen=\(prefs.showOnScreen)")
        // snapshot 已经把"当前正在用的这个"从候选里去掉(dropCurrent),列表里
        // 全是能切过去的目标 —— 正向选第一格(最近用过的上一个 app),反向选
        // 最后一格(最久没用的)。count==1 时两者都落 0。
        let initialSelection = reverse ? snapshot.count - 1 : 0
        // 诊断:打印 snapshot 的 MRU 序与初始选中。用来确认"切了等于没切"是不是
        // 因为 MRU 还没更新到位(刚切到的窗口仍排在 index 1)。
        SwitcherDebugLog.log("summon order selected=\(initialSelection) [" +
            snapshot.enumerated().map { idx, w in
                "\(idx):\(w.application.localizedName ?? "?")#\(w.lastFocusOrder)"
            }.joined(separator: ", ") + "]")
        let session = SwitcherSession(windows: snapshot, initialSelection: initialSelection)
        SwitcherSession.current = session
        keyTap.isActive = true
        panel.show(
            with: snapshot,
            style: prefs.appearanceStyle,
            hideWindowTitle: prefs.groupBy == .perApp,
            on: panelScreen
        )
        panelVisibility.markShown(at: ProcessInfo.processInfo.systemUptime)
        panel.tilesView.setSelectedIndex(session.selectedIndex)

        // 启动缩略图抓取 —— 异步,抓到一张更新一张 tile,不阻塞 panel 显示。
        // 没有 Screen Recording 权限就直接什么也不做,UI 保持纯图标态。
        startThumbnailCapture(for: session)

        if panelVisibility.consumePendingConfirmForShownSession(at: ProcessInfo.processInfo.systemUptime) {
            confirmAndDismiss()
        }
    }

    /// 开始这次 session 的缩略图抓取。抓到一张就找对应 tile 更新一张。
    private func startThumbnailCapture(for session: SwitcherSession) {
        // 第一次 trigger 时,如果还没拿 Screen Recording 权限就弹一次。
        // 弹完用户也得重启 app 才生效,所以这里我们仍然继续往下走 —— 这次
        // session 用 P1 退化样式(只 app 图标),下次启动后才真有缩略图。
        if !didPromptForScreenRecording && !PermissionManager.isScreenRecordingTrusted {
            didPromptForScreenRecording = true
            _ = PermissionManager.requestScreenRecordingPrompt()
        }

        let panelRef = panel
        SwitcherThumbnails.shared.captureThumbnails(
            for: session.windows,
            onThumbnailReady: { window, contents in
                // 永远写回 window.thumbnail —— 哪怕 session 已经结束,这张图也是
                // 下次召唤的预热缓存,丢了就得再抓一次。
                window.thumbnail = contents
                // 但只有 panel 仍是这次 session 时才更新 tile,避免改到下一轮的 UI。
                guard SwitcherSession.current === session else { return }
                if let tile = panelRef.tilesView.tiles.first(where: { $0.window_ === window }) {
                    tile.updateThumbnail(contents)
                }
            },
            completion: {}
        )
    }

    private func stepSelection(reverse: Bool) {
        guard let session = SwitcherSession.current else { return }
        session.cycleSelection(reverse ? -1 : 1)
        panel.tilesView.setSelectedIndex(session.selectedIndex)
    }

    private func handleHover(_ index: Int) {
        guard let session = SwitcherSession.current else { return }
        session.hoveredIndex = index
        panel.tilesView.setHoveredIndex(index)
        // hover 也改 selected —— 鼠标和键盘共享一个选中态(用户希望可以混用)
        if index >= 0 && index != session.selectedIndex {
            session.selectedIndex = index
            panel.tilesView.setSelectedIndex(index)
        }
    }

    private func handleClick(_ index: Int) {
        guard let session = SwitcherSession.current else { return }
        guard index >= 0, index < session.windows.count else { return }
        session.selectedIndex = index
        confirmAndDismiss(delayingFastRelease: false)
    }

    private func confirmAndDismiss(delayingFastRelease: Bool = true) {
        guard let session = SwitcherSession.current else {
            panelVisibility.noteConfirmBeforeSession(at: ProcessInfo.processInfo.systemUptime)
            return
        }
        guard delayingFastRelease else {
            confirmAndDismissImmediately(for: session)
            return
        }
        let delay = panelVisibility.confirmDelay(at: ProcessInfo.processInfo.systemUptime)
        guard delay > 0 else {
            confirmAndDismissImmediately(for: session)
            return
        }
        pendingConfirmTask?.cancel()
        pendingConfirmTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  let session,
                  SwitcherSession.current === session else { return }
            self.pendingConfirmTask = nil
            self.confirmAndDismissImmediately(for: session)
        }
    }

    private func confirmAndDismissImmediately(for session: SwitcherSession) {
        guard SwitcherSession.current === session else { return }
        let target = session.selectedWindow
        hidePanelIfShown()
        if let target {
            SwitcherDebugLog.log("confirm raise app=\(target.application.localizedName ?? "?") wid=\(target.cgWindowId)")
            // 先把 MRU 同步顶到这个窗口,再 raise —— 这样紧接着的下一次 trigger
            // 即便 AX activate 通知还没回来,snapshot 的 MRU 序也已经是新的,
            // 刚切到的这个才会被 dropCurrent 从候选里去掉,index 0 落在
            // "真正的上一个 app"而不是它自己。
            windowList.promoteForConfirmedSwitch(window: target)
            SwitcherFocus.raise(window: target)
        }
    }

    private func cancelAndDismiss() {
        hidePanelIfShown()
    }

    private func hidePanelIfShown() {
        guard SwitcherSession.isActive else { return }
        pendingConfirmTask?.cancel()
        pendingConfirmTask = nil
        panelVisibility.clear()
        SwitcherSession.current = nil
        keyTap.isActive = false
        _panel?.hidePanel()
        scheduleThumbnailTrim()
    }

    // MARK: - Thumbnail LRU 清

    /// 排个延迟任务,N 分钟没新 session 就把非 top-MRU 的窗口缩略图清掉。
    /// 用户连续 Cmd+Tab 多次时,每次 trigger 都会取消并重排,实际不会真清。
    /// 这是个软上限:闲置 N 分钟后释放,而不是每次 dismiss 立刻丢图。
    private func scheduleThumbnailTrim() {
        thumbnailTrimTask?.cancel()
        thumbnailTrimTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.thumbnailTrimDelayNanos)
            if Task.isCancelled { return }
            SwitcherWindowList.shared.trimThumbnails(keepTop: Self.thumbnailTrimKeepTop)
            self?.thumbnailTrimTask = nil
        }
    }

    private func cancelThumbnailTrim() {
        thumbnailTrimTask?.cancel()
        thumbnailTrimTask = nil
    }
}
