import AppKit
import ApplicationServices
import Carbon
@preconcurrency import CoreFoundation
import CoreGraphics
import Foundation
import betterfinder

/// Owns the global CGEventTaps, the dedicated HID tap-callback thread, and the
/// controllers that act on events. Wheel events intentionally run through a
/// separate `.cgAnnotatedSessionEventTap`, matching Mos' routing model; the
/// annotated event carries the target PID needed by smooth-scroll replay.
///
/// 事件交给哪些模块、按什么顺序,在 `InputDispatcher` 里;这里只管 tap 的生命周期和
/// 把配置推到 tap 线程。
///
/// Sub-controllers:
/// - `GestureEngine`        right-click gesture state machine
/// - `MouseControlController` smooth scroll / scroll hotkeys / button bindings
/// - `WindowDragController` modifier+drag move/resize
/// - `ContentZoomController` modifier+scroll content zoom
/// - `WindowShortcutController` shortcut-triggered window actions
///
/// The tap callback runs on a private high-QoS thread+runloop. State that's
/// only touched in the callback (gesture state machine, drag session) lives
/// inside the sub-controllers on that thread — no cross-thread sync per
/// event. The few fields read from the callback that are also written by the
/// main-thread preferences observer (modifier snapshots) use short NSLocks.

/// 右键透传白区。GestureCaptureView 之类 Velto 自己的"想吃右键"的 view 在被
/// 显示时把自己的屏幕 rect(event-tap 坐标:左上角原点,Y 向下)写进来,移除
/// 时清空。EventTapManager 的右键分支会先看一下当前光标是不是落在区域里,
/// 是就让事件透传给 NSView,而不是塞给 GestureEngine。
///
/// 用 NSLock 串行化 —— 写在主线程(view lifecycle),读在 tap 线程(每个右键
/// 事件)。读路径锁 + rect.contains,只是几条 CPU 指令,不会成为瓶颈。
enum RightClickPassThrough {
    private static let lock = NSLock()
    private static let selfPID = pid_t(getpid())
    nonisolated(unsafe) private static var _region: CGRect?
    nonisolated(unsafe) private static var _windowNumber: Int?
    nonisolated(unsafe) private static var _owner: ObjectIdentifier?

    /// 注册透传区并标记归属者。SwiftUI 切换/新建手势时,新旧 `GestureCaptureView`
    /// 实例的创建与销毁会交错(常常旧实例的销毁晚于新实例的创建);用 owner 标识
    /// "当前有效注册者",销毁旧实例时只能清掉自己的注册(见 `clear(owner:)`),
    /// 不会误抹掉新实例刚注册的区域。
    static func setRegion(_ region: CGRect, windowNumber: Int?, owner: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        _region = region
        _windowNumber = windowNumber
        _owner = owner
    }

    /// 撤销注册:仅当 `owner` 正是当前注册者时才真正清空 —— 避免旧实例 teardown
    /// 抹掉新实例的注册。
    static func clear(owner: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        if _owner == owner {
            _region = nil
            _windowNumber = nil
            _owner = nil
        }
    }

    static func contains(
        _ point: CGPoint,
        eventTargetPID: pid_t,
        eventWindowNumber: Int64,
        eventWindowThatCanHandleNumber: Int64
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return shouldPassThrough(
            point: point,
            region: _region,
            eventTargetPID: eventTargetPID,
            selfPID: selfPID,
            eventWindowNumber: eventWindowNumber,
            eventWindowThatCanHandleNumber: eventWindowThatCanHandleNumber,
            registeredWindowNumber: _windowNumber
        )
    }

    static func contains(_ event: CGEvent) -> Bool {
        contains(
            event.location,
            eventTargetPID: pid_t(event.getIntegerValueField(.eventTargetUnixProcessID)),
            eventWindowNumber: event.getIntegerValueField(.mouseEventWindowUnderMousePointer),
            eventWindowThatCanHandleNumber: event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        )
    }

    static func shouldPassThrough(
        point: CGPoint,
        region: CGRect?,
        eventTargetPID: pid_t,
        selfPID: pid_t,
        eventWindowNumber: Int64 = 0,
        eventWindowThatCanHandleNumber: Int64 = 0,
        registeredWindowNumber: Int? = nil
    ) -> Bool {
        guard let region, region.contains(point) else { return false }
        if eventTargetPID == selfPID { return true }
        guard let registeredWindowNumber else { return false }
        let registered = Int64(registeredWindowNumber)
        return eventWindowNumber == registered || eventWindowThatCanHandleNumber == registered
    }

    /// 仅供调试日志读取当前透传区(可能为 nil)。
    static func regionForDebug() -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        return _region
    }

    static func windowNumberForDebug() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return _windowNumber
    }
}

/// 把非 Sendable 值一次性越过 `@Sendable` 闭包边界用的盒子。仅用于"主线程创建、
/// 交给另一条线程独占"的单向交接,调用方负责保证之后不再从原线程触碰该值。
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// 跨线程协调器:主线程 (lifecycle / preferences observer) ↔ tap 线程
/// (CGEvent callback)。因为存在主线程拥有的字段 (eventTap/tapRunLoop) 和
/// tap-thread callback (`handle`) 同时存在,整类标 `@unchecked Sendable`,
/// 各字段的同步约束写在邻近注释里。
final class EventTapManager: @unchecked Sendable {
    /// Status callback. 从 tap 线程或主线程都可能调用,闭包自身需 `@Sendable`,
    /// 调用方负责把对 UI 状态的修改 hop 回 main actor。
    var onStatusChange: (@Sendable (String) -> Void)? {
        didSet { gestureEngine.onStatusChange = onStatusChange }
    }
    var onGestureMatch: (@Sendable (GestureMatch?) -> Void)? {
        didSet { gestureEngine.onGestureMatch = onGestureMatch }
    }

    private let store: ConfigStore
    private let gestureEngine: GestureEngine
    private let mouseControlController = MouseControlController()
    private let windowDragController = WindowDragController()
    private let contentZoomController = ContentZoomController()
    private let windowShortcutController = WindowShortcutController()
    private let betterFinderShortcutController = BetterFinderGlobalShortcutController()
    private let keyRemapController = KeyRemapController()
    private let screenshotShortcutController = ScreenshotShortcutController()
    private let inputSourcePunctuationController = InputSourcePunctuationController()

    private let dispatcher: InputDispatcher

    /// HID tap。回调、手势状态机都在它的线程上。写在主线程(start / stop),
    /// 所有 `performOnTapThread` 调用点也都在主线程,串行化天然成立。
    private var hidTap: EventTapHost?
    /// 滚动链路的专用 tap。scroll tap 回调、平滑滚动动画(CADisplayLink)与引擎可变状态
    /// 都 affine 到这条线程,与 HID tap 线程对称,把最高频的滚动处理彻底移出主线程。
    private var scrollTap: EventTapHost?

    private var activationObserver: NSObjectProtocol?
    private var storeObserver: NSObjectProtocol?
    private var betterFinderObserver: NSObjectProtocol?
    private var keyRemapObserver: NSObjectProtocol?

    @MainActor
    init(store: ConfigStore = .shared) {
        self.store = store
        self.gestureEngine = GestureEngine(
            preferences: store.preferences,
            gestures: store.gestures,
            appProfiles: store.appProfiles,
            buttonMap: Self.buttonMap(for: store),
            gesturesVersion: store.gesturesVersion
        )
        self.dispatcher = InputDispatcher(modules: .init(
            keyRemap: keyRemapController,
            punctuation: inputSourcePunctuationController,
            mouseControl: mouseControlController,
            gesture: gestureEngine,
            betterFinder: betterFinderShortcutController,
            screenshot: screenshotShortcutController,
            windowShortcut: windowShortcutController,
            windowDrag: windowDragController,
            contentZoom: contentZoomController
        ))
        applyPreferenceSnapshots(store.preferences)
        dispatcher.gesturesEnabled = store.preferences.gesturesEnabled
        dispatcher.windowManagementEnabled = store.preferences.windowManagementEnabled
        // start() 之前于主线程设初值,此时无并发(同上两个快照)。调试日志开关先于
        // setActive 同步,否则 InputSourceSwitchController.start() 还没跑,首条
        // "active=true" 日志会被吞掉,排查时误以为功能没启用。
        InputSourceSwitchDebugLog.setEnabled(store.preferences.inputSourceSwitch.debugLoggingEnabled)
        inputSourcePunctuationController.setActive(
            store.preferences.inputSourceSwitch.forceEnglishPunctuationEnabled
        )
        let punctuationSnapshot = Self.currentPunctuationSnapshot()
        inputSourcePunctuationController.setCurrentInputSourceIsCJKV(punctuationSnapshot.isCJKV)
        inputSourcePunctuationController.setCurrentInputSourceProcessID(punctuationSnapshot.imePID)

        // 必须 deliverImmediately:block 版 addObserver 默认 coalesce,而 AppKit 在 Velto 失活时
        // 挂起分布式通知 —— 打开过一次设置窗口再切走,输入法变更就再也收不到,CJKV 快照冻结在
        // 旧值,强制英文标点时灵时不灵(2026-10 探针实测)。回调在注册所在的主线程。
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(syncPunctuationInputSourceSnapshot),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self.performOnTapThread { [weak self] in
                self?.gestureEngine.updateLastFrontmostApplication(app)
            }
        }

        storeObserver = NotificationCenter.default.addObserver(
            forName: .configStoreDidChange,
            object: store,
            queue: .main
        ) { [weak self] note in
            let reason = note.configStoreChangeReason
            let change = note.preferencesChange
            // queue: .main 保证回调在主线程,store 是 @MainActor。
            MainActor.assumeIsolated {
                guard let self else { return }
                if reason != .preferences {
                    self.pushGestures()
                }
                if let change {
                    self.pushPreferences(change)
                }
            }
        }

        betterFinderShortcutController.updatePreferences(BetterFinderPreferencesStore.shared.preferences)
        betterFinderShortcutController.updateHotKeys(BetterFinderPreferencesStore.shared.preferences)
        betterFinderObserver = NotificationCenter.default.addObserver(
            forName: BetterFinderPreferencesStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let preferences = BetterFinderPreferencesStore.shared.preferences
            self?.betterFinderShortcutController.updateHotKeys(preferences)
            self?.performOnTapThread { [weak self] in
                self?.betterFinderShortcutController.updatePreferences(preferences)
            }
        }

        // 调试开关先于首次 update 设好,启动期的查找表构建过程才会被记录。
        KeyRemapDebugLog.setEnabled(KeyRemapStore.shared.debugLoggingEnabled)
        // 总开关关闭时喂空规则,等于整个按键映射特性暂停(查找表为空,所有事件透传)。
        KeyRemapDebugLog.log("EventTapManager init: masterEnabled=\(KeyRemapStore.shared.masterEnabled), " +
            "规则数=\(KeyRemapStore.shared.rules.count)")
        keyRemapController.update(
            rules: KeyRemapStore.shared.masterEnabled ? KeyRemapStore.shared.rules : []
        )
        // Caps Lock 这类 toggle 源走 HID 层重映射(hidutil),从根上消除「闪灯」;
        // 其余键仍由上面的 tap 查找表处理。
        KeyRemapHIDRemap.setMappings(Self.capsHIDPairs(
            masterEnabled: KeyRemapStore.shared.masterEnabled,
            rules: KeyRemapStore.shared.rules
        ))
        keyRemapObserver = NotificationCenter.default.addObserver(
            forName: .keyRemapStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main 保证回调在主线程,KeyRemapStore 是 @MainActor。
            MainActor.assumeIsolated {
                let store = KeyRemapStore.shared
                let rules = store.masterEnabled ? store.rules : []
                KeyRemapDebugLog.log("keyRemapStoreDidChange: masterEnabled=\(store.masterEnabled), " +
                    "下发 \(rules.count) 条规则 → 重建查找表")
                self?.performOnTapThread { [weak self] in
                    self?.keyRemapController.update(rules: rules)
                }
                // caps 等 toggle 源的 HID 层重映射随规则同步。
                KeyRemapHIDRemap.setMappings(Self.capsHIDPairs(
                    masterEnabled: store.masterEnabled, rules: store.rules
                ))
            }
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
        if let betterFinderObserver {
            NotificationCenter.default.removeObserver(betterFinderObserver)
        }
        if let keyRemapObserver {
            NotificationCenter.default.removeObserver(keyRemapObserver)
        }
        DistributedNotificationCenter.default().removeObserver(self)
        stop()
    }

    // MARK: - Lifecycle

    func start() -> Bool {
        guard hidTap == nil else { return true }

        guard PermissionManager.isAccessibilityTrusted else {
            onStatusChange?("需要辅助功能权限")
            PermissionManager.requestAccessibilityPrompt()
            return false
        }

        guard startScrollEventTap() else {
            onStatusChange?("滚轮拦截启动失败")
            return false
        }

        let mask = eventMask(for: .rightMouseDown)
            | eventMask(for: .rightMouseDragged)
            | eventMask(for: .rightMouseUp)
            | eventMask(for: .leftMouseDown)
            | eventMask(for: .leftMouseDragged)
            | eventMask(for: .leftMouseUp)
            | eventMask(for: .otherMouseDown)
            | eventMask(for: .otherMouseDragged)
            | eventMask(for: .otherMouseUp)
            | eventMask(for: .mouseMoved)
            | eventMask(for: .flagsChanged)
            | eventMask(for: .keyDown)
            | eventMask(for: .keyUp)

        let tap = EventTapHost(
            name: "com.face.velto.eventtap",
            location: .cghidEventTap,
            place: .headInsertEventTap,
            mask: mask
        ) { [unowned self] type, event in
            self.handle(type: type, event: event)
        }
        tap.onThreadStart = { [weak self] runLoop in
            self?.gestureEngine.attach(runLoop: runLoop)
        }
        tap.onDisabled = { [weak self] type in
            self?.handleTapDisabled(type)
        }

        guard tap.start() else {
            stopScrollEventTap()
            onStatusChange?("事件拦截启动失败")
            return false
        }

        hidTap = tap
        prewarmCaches()
        onStatusChange?("监听中(主动拦截)")
        return true
    }

    func stop() {
        performOnTapThread { [weak self] in
            self?.gestureEngine.detach()
        }
        hidTap?.stop()
        hidTap = nil
        stopScrollEventTap()
    }

    /// 低频健康检查,主线程调用。启动时没权限的话授权后自动启动,不用手动点「重启监听」;
    /// tap 被系统废掉后重建。返回监听是否在跑。
    @discardableResult
    func checkHealth() -> Bool {
        let running = hidTap != nil
        let tapsEnabled = (hidTap?.ensureEnabled() ?? false) && (scrollTap?.ensureEnabled() ?? false)
        let action = EventTapHost.healthAction(
            running: running,
            tapsEnabled: tapsEnabled,
            trusted: PermissionManager.isAccessibilityTrusted
        )
        switch action {
        case .keep:
            return running
        case .start:
            break
        case .restart:
            stop()
        case .stop:
            stop()
            onStatusChange?("需要辅助功能权限")
            return false
        }
        WindowManagementDebugLog.log("健康检查:\(action)")
        return start()
    }

    // MARK: - Event dispatch (tap thread)

    /// 水位计阈值:tap 回调单次超过此耗时即落 `tapSlow` 日志。本 tap 监听着
    /// mouseMoved / 键盘事件,回调一阻塞整个系统的光标和键盘都会冻住;30ms
    /// 已是肉眼可感的卡顿下限,正常回调在微秒级,不会误报。
    private static let slowCallbackThresholdMs: Double = 30

    private static func eventTypeName(_ type: CGEventType) -> String {
        switch type {
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseDragged: return "rightMouseDragged"
        case .rightMouseUp: return "rightMouseUp"
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseDragged: return "leftMouseDragged"
        case .leftMouseUp: return "leftMouseUp"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseDragged: return "otherMouseDragged"
        case .otherMouseUp: return "otherMouseUp"
        case .mouseMoved: return "mouseMoved"
        case .flagsChanged: return "flagsChanged"
        case .keyDown: return "keyDown"
        case .keyUp: return "keyUp"
        default: return "type\(type.rawValue)"
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 水位计:量化"哪类事件在 tap 线程卡了多久"。`DebugLog.event` 内部自判
        // 开关,慢事件才走到那一步;快路径只多两次读时钟,开销可忽略。
        let watermarkStart = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - watermarkStart) * 1000
            if elapsedMs >= Self.slowCallbackThresholdMs {
                DebugLog.event("tapSlow", [
                    "type": Self.eventTypeName(type),
                    "ms": elapsedMs
                ])
            }
        }

        return dispatcher.dispatch(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
    }

    /// tap 被系统禁用期间事件全丢(含 rightMouseUp)。重启后所有模块都要复位,
    /// 否则手势会卡在 .gesturing 半路,之后的手势连环判为 abandoned、整片失灵。
    /// 留痕方便对照"resize 拖错窗口"之类的问题是不是赶上了 tap 被禁用。
    private func handleTapDisabled(_ type: CGEventType) {
        dispatcher.resetTransientState()
        let timedOut = type == .tapDisabledByTimeout
        WindowManagementDebugLog.log("⚠️ event tap 被系统禁用(\(timedOut ? "超时" : "用户输入")),已重启")
        if DebugLog.isEnabled {
            DebugLog.event("tap", ["event": "reenabled", "kind": timedOut ? "timeout" : "userInput"])
        }
        onStatusChange?("监听中(tap 已重启)")
    }

    // MARK: - Annotated scroll tap (scroll thread)

    func handleAnnotatedScroll(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }

        // 截图保留鼠标的竖向平滑和速度设置,跳过缩放及横向手势。
        if ScrollCaptureKeyTap.isCapturing {
            return mouseControlController.handleScrollWheel(event: event, captureLocked: true)
                ? nil : Unmanaged.passUnretained(event)
        }

        if InputEventOrigin(event) == .smoothScroll {
            return Unmanaged.passUnretained(event)
        }

        let raw = ModifierFormatter.normalizedRawValue(from: event.flags)
        if raw != 0,
           contentZoomController.handleScrollWheel(event: event, normalizedFlags: raw) {
            return nil
        }

        return mouseControlController.handleScrollWheel(event: event)
            ? nil
            : Unmanaged.passUnretained(event)
    }

    private func startScrollEventTap() -> Bool {
        guard scrollTap == nil else { return true }

        let tap = EventTapHost(
            name: "com.face.velto.scrolltap",
            location: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            mask: eventMask(for: .scrollWheel)
        ) { [unowned self] type, event in
            self.handleAnnotatedScroll(type: type, event: event)
        }

        // CADisplayLink 必须在主线程访问 NSScreen 创建;创建后随线程一起带到滚动
        // 线程,在那条 runloop 上 add(to:),回调即在滚动线程触发。一次性交接,用
        // 盒子越过线程闭包的边界(CADisplayLink 非 Sendable)。
        let displayLinkBox = UncheckedSendableBox(mouseControlController.makeScrollDisplayLink())
        tap.onThreadStart = { [weak self] runLoop in
            self?.mouseControlController.attachScrollRunLoop(
                runLoop,
                thread: Thread.current,
                displayLink: displayLinkBox.value
            )
        }
        // runloop 已退出,在本线程打破 CADisplayLink ↔ animator 的引用环。
        tap.onThreadExit = { [weak self] in
            self?.mouseControlController.detachScrollRunLoop()
        }
        tap.onDisabled = { [weak self] _ in
            self?.mouseControlController.stopSmoothScroll()
        }

        guard tap.start() else { return false }
        scrollTap = tap
        return true
    }

    private func stopScrollEventTap() {
        mouseControlController.stopSmoothScroll()
        scrollTap?.stop()
        scrollTap = nil
    }

    // MARK: - Cross-thread helpers

    /// Schedule `work` to run on the tap thread's runloop. Used by main-thread
    /// observers that need to mutate engine state safely. If the tap thread
    /// isn't running yet (start hasn't been called), the work is dropped.
    private func performOnTapThread(_ work: @escaping @Sendable () -> Void) {
        hidTap?.perform(work)
    }

    @MainActor
    private func pushGestures() {
        let gestures = store.gestures
        let appProfiles = store.appProfiles
        let buttonMap = Self.buttonMap(for: store)
        let version = store.gesturesVersion
        performOnTapThread { [weak self] in
            self?.gestureEngine.updateGestures(
                gestures, appProfiles: appProfiles, buttonMap: buttonMap, version: version)
        }
    }

    @MainActor
    private func pushPreferences(_ change: PreferencesChange) {
        let preferences = change.current
        applyPreferenceSnapshots(preferences)
        performOnTapThread { [weak self] in
            self?.dispatcher.gesturesEnabled = preferences.gesturesEnabled
            self?.dispatcher.windowManagementEnabled = preferences.windowManagementEnabled
            self?.gestureEngine.updatePreferences(preferences)
        }

        // 强制英文标点是全局开关,一变立刻同步快照。
        guard change.changed(\.inputSourceSwitch.forceEnglishPunctuationEnabled) else { return }
        let punctuationActive = preferences.inputSourceSwitch.forceEnglishPunctuationEnabled
        let punctuationSnapshot = Self.currentPunctuationSnapshot()
        performOnTapThread { [weak self] in
            self?.inputSourcePunctuationController.setActive(punctuationActive)
            self?.inputSourcePunctuationController.setCurrentInputSourceIsCJKV(punctuationSnapshot.isCJKV)
            self?.inputSourcePunctuationController.setCurrentInputSourceProcessID(punctuationSnapshot.imePID)
        }
    }

    /// 强制英文标点需要的当前输入法快照:是否 CJKV + 宿主进程 PID(查候选窗在屏用)。
    /// 只能在主线程调(TIS + NSRunningApplication)。
    private static func currentPunctuationSnapshot() -> (isCJKV: Bool, imePID: pid_t?) {
        guard let info = InputSourceCatalog.current(), info.isCJKV else { return (false, nil) }
        let pid = info.bundleID.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier
        }
        return (true, pid)
    }

    @objc private func syncPunctuationInputSourceSnapshot() {
        let snapshot = Self.currentPunctuationSnapshot()
        performOnTapThread { [weak self] in
            self?.inputSourcePunctuationController.setCurrentInputSourceIsCJKV(snapshot.isCJKV)
            self?.inputSourcePunctuationController.setCurrentInputSourceProcessID(snapshot.imePID)
        }
    }

    private func applyPreferenceSnapshots(_ preferences: AppPreferences) {
        mouseControlController.updatePreferences(preferences.mouseControl)
        windowDragController.updateModifierFlags(
            move: preferences.windowMoveModifierFlags,
            resize: preferences.windowResizeModifierFlags
        )
        contentZoomController.updateModifierFlag(preferences.contentZoomModifierFlags)
        windowShortcutController.updateShortcut(preferences.windowMaximizeShortcut)
        windowShortcutController.updateHotKey(
            preferences.windowManagementEnabled ? preferences.windowMaximizeShortcut : nil
        )
        windowShortcutController.updateMaximizeButton(
            preferences.windowMaximizeButton,
            excludedApps: Set(preferences.windowMaximizeButtonExcludedApps)
        )
        // 截图关着就别占触发键:tap 白吞、安全输入兜底的 Carbon 热键也会抢走别人的组合键。
        screenshotShortcutController.updateShortcut(
            preferences.screenshot.enabled ? preferences.screenshot.triggerShortcut : nil
        )
    }

    private func prewarmCaches() {
        DispatchQueue.global(qos: .utility).async {
            DisplayCoordinateConverter.prewarm()
        }
    }

    private func eventMask(for type: CGEventType) -> CGEventMask {
        CGEventMask(1) << CGEventMask(type.rawValue)
    }

    /// 从规则里挑出能用 HID 层重映射(hidutil)处理的 Caps Lock 源:caps→单个普通键/
    /// 单个修饰键,无 mandatory、无附加修饰、非禁用,且源/目标都有 HID usage。
    /// 这些交给 hidutil 在驱动层直改,根除「闪灯」;其余 caps 情形(hyper/禁用/组合)
    /// 仍留给 tap 的反应式回退。
    private static func capsHIDPairs(
        masterEnabled: Bool,
        rules: [KeyRemapRule]
    ) -> [KeyRemapHIDRemap.HIDPair] {
        guard masterEnabled,
              let src = KeyRemapHIDRemap.hidUsage(forKeyCode: 57) else { return [] }
        var pairs: [KeyRemapHIDRemap.HIDPair] = []
        for rule in rules where rule.enabled {
            for m in rule.manipulators
            where m.from.keyCode == 57 && m.from.mandatory.isEmpty && m.to.count == 1 {
                let to = m.to[0]
                guard to.keyCode != 0xFFFF, to.additionalModifierCodes.isEmpty,
                      let dst = KeyRemapHIDRemap.hidUsage(forKeyCode: to.keyCode) else { continue }
                pairs.append(.init(src: src, dst: dst))
            }
        }
        return pairs
    }

    /// 鼠标按钮触发的查找表。主线程构建(覆盖判定要算轨迹签名),再交给 tap 线程。
    @MainActor
    private static func buttonMap(for store: ConfigStore) -> GestureButtonMap {
        GestureButtonMap(global: store.gestures, appProfiles: store.appProfiles) {
            GestureDirection.canonical(for: $0.templates.map { $0.map(\.cgPoint) })
        }
    }
}
