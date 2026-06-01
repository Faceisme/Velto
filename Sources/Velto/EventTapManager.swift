import AppKit
import ApplicationServices
@preconcurrency import CoreFoundation
import CoreGraphics
import Foundation

/// Owns the global CGEventTaps, the dedicated HID tap-callback thread, and the
/// controllers that act on events. Wheel events intentionally run through a
/// separate `.cgAnnotatedSessionEventTap`, matching Mos' routing model; the
/// annotated event carries the target PID needed by smooth-scroll replay.
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
private let veltoEventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handle(proxy: proxy, type: type, event: event)
}

private let veltoScrollEventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleAnnotatedScroll(proxy: proxy, type: type, event: event)
}

/// 右键透传白区。GestureCaptureView 之类 Velto 自己的"想吃右键"的 view 在被
/// 显示时把自己的屏幕 rect(event-tap 坐标:左上角原点,Y 向下)写进来,移除
/// 时清空。EventTapManager 的右键分支会先看一下当前光标是不是落在区域里,
/// 是就让事件透传给 NSView,而不是塞给 GestureEngine。
///
/// 用 NSLock 串行化 —— 写在主线程(view lifecycle),读在 tap 线程(每个右键
/// 事件)。读路径锁 + rect.contains,只是几条 CPU 指令,不会成为瓶颈。
enum RightClickPassThrough {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _region: CGRect?

    static func setRegion(_ region: CGRect?) {
        lock.lock(); defer { lock.unlock() }
        _region = region
    }

    static func contains(_ point: CGPoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let r = _region else { return false }
        return r.contains(point)
    }
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

    private let store: GestureStore
    private let gestureEngine: GestureEngine
    private let mouseControlController = MouseControlController()
    private let windowDragController = WindowDragController()
    private let contentZoomController = ContentZoomController()
    private let windowShortcutController = WindowShortcutController()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var scrollEventTap: CFMachPort?
    private var scrollRunLoopSource: CFRunLoopSource?
    /// 写于 tap 线程 (start 里 thread block 起步时),读于主线程 (performOnTapThread,
    /// stop)。启动期靠 `ready.wait()` 同步可见性;`stop()` 仅在主线程调用,所有
    /// `performOnTapThread` 调用点也都在主线程,串行化天然成立。类整体标
    /// `@unchecked Sendable`,Swift 6 不替我们检查这个字段的可见性,如果以后
    /// 引入从其它线程触发 `performOnTapThread` 的路径,要在这里加锁。
    private var tapRunLoop: CFRunLoop?

    private var activationObserver: NSObjectProtocol?
    private var storeObserver: NSObjectProtocol?

    @MainActor
    init(store: GestureStore = .shared) {
        self.store = store
        self.gestureEngine = GestureEngine(
            preferences: store.preferences,
            gestures: store.gestures,
            gesturesVersion: store.gesturesVersion
        )
        applyPreferenceSnapshots(store.preferences)

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
            forName: .gestureStoreDidChange,
            object: store,
            queue: .main
        ) { [weak self] _ in
            // queue: .main 保证回调在主线程,store 是 @MainActor。
            MainActor.assumeIsolated {
                guard let self else { return }
                let preferences = store.preferences
                let gestures = store.gestures
                let version = store.gesturesVersion
                self.applyPreferenceSnapshots(preferences)
                self.performOnTapThread { [weak self] in
                    self?.gestureEngine.updatePreferences(preferences)
                    self?.gestureEngine.updateGestures(gestures, version: version)
                }
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
        stop()
    }

    // MARK: - Lifecycle

    func start() -> Bool {
        guard eventTap == nil else { return true }

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
            | eventMask(for: .leftMouseUp)
            | eventMask(for: .otherMouseDown)
            | eventMask(for: .otherMouseUp)
            | eventMask(for: .mouseMoved)
            | eventMask(for: .flagsChanged)
            | eventMask(for: .keyDown)
            | eventMask(for: .keyUp)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: veltoEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            stopScrollEventTap()
            onStatusChange?("事件拦截启动失败")
            return false
        }

        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            eventTap = nil
            stopScrollEventTap()
            onStatusChange?("事件拦截启动失败")
            return false
        }

        runLoopSource = source
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let runLoop = CFRunLoopGetCurrent() else {
                ready.signal()
                return
            }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            if let self {
                self.tapRunLoop = runLoop
                self.gestureEngine.attach(runLoop: runLoop)
            }
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        thread.name = "com.face.velto.eventtap"
        thread.qualityOfService = QualityOfService.userInteractive
        tapThread = thread
        thread.start()
        ready.wait()

        CGEvent.tapEnable(tap: tap, enable: true)
        prewarmCaches()
        onStatusChange?("监听中(主动拦截)")
        return true
    }

    func stop() {
        let runLoop = tapRunLoop
        let tap = eventTap
        let source = runLoopSource

        if runLoop != nil {
            performOnTapThread { [weak self] in
                self?.gestureEngine.detach()
            }
        }

        tapRunLoop = nil
        eventTap = nil
        runLoopSource = nil
        tapThread = nil

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopSourceInvalidate(source)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        stopScrollEventTap()
    }

    // MARK: - Event dispatch (tap thread)

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            mouseControlController.resetTransientState()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            onStatusChange?("监听中(tap 已重启)")
            return nil
        }

        // Compute the normalized modifier flags exactly once for all
        // downstream checks. This is the hot path; everything else is gated
        // on event type.
        let raw = ModifierFormatter.normalizedRawValue(from: event.flags)

        switch type {
        case .rightMouseDown:
            if event.getIntegerValueField(.eventSourceUserData) == gestureEngine.rightClickSyntheticMarker {
                return Unmanaged.passUnretained(event)
            }
            // 录制手势卡片这种自己想吃右键的 view 已经把屏幕区域登记进来 ——
            // 让事件原样透传,GestureEngine 完全不介入。
            if RightClickPassThrough.contains(event.location) {
                return Unmanaged.passUnretained(event)
            }
            if mouseControlController.handleTriggerEvent(type: type, event: event) {
                return nil
            }
            _ = gestureEngine.handleRightMouseDown(at: event.location)
            return nil

        case .rightMouseDragged:
            if event.getIntegerValueField(.eventSourceUserData) == gestureEngine.rightClickSyntheticMarker {
                return Unmanaged.passUnretained(event)
            }
            if RightClickPassThrough.contains(event.location) {
                return Unmanaged.passUnretained(event)
            }
            return gestureEngine.handleRightMouseDragged(at: event.location)
                ? nil
                : Unmanaged.passUnretained(event)

        case .rightMouseUp:
            if event.getIntegerValueField(.eventSourceUserData) == gestureEngine.rightClickSyntheticMarker {
                return Unmanaged.passUnretained(event)
            }
            if RightClickPassThrough.contains(event.location) {
                return Unmanaged.passUnretained(event)
            }
            if mouseControlController.handleTriggerEvent(type: type, event: event) {
                return nil
            }
            return gestureEngine.handleRightMouseUp(at: event.location)
                ? nil
                : Unmanaged.passUnretained(event)

        case .leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp:
            return mouseControlController.handleTriggerEvent(type: type, event: event)
                ? nil
                : Unmanaged.passUnretained(event)

        case .mouseMoved:
            guard !gestureEngine.isHandlingRightMouse else {
                return Unmanaged.passUnretained(event)
            }
            if raw == 0 { return Unmanaged.passUnretained(event) }
            guard let mode = windowDragController.dragMode(forNormalizedFlags: raw) else {
                return Unmanaged.passUnretained(event)
            }
            windowDragController.handleMouseMoved(at: event.location, mode: mode)
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            guard !gestureEngine.isHandlingRightMouse else {
                return Unmanaged.passUnretained(event)
            }
            let consumed = mouseControlController.handleTriggerEvent(type: type, event: event)
            contentZoomController.handleFlagsChanged(normalizedFlags: raw)
            windowDragController.handleFlagsChanged(event: event, normalizedFlags: raw)
            return consumed ? nil : Unmanaged.passUnretained(event)

        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == ShortcutSynthesizer.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
            guard !gestureEngine.isHandlingRightMouse else {
                return Unmanaged.passUnretained(event)
            }
            if mouseControlController.handleTriggerEvent(type: type, event: event) {
                return nil
            }
            return windowShortcutController.handleKeyDown(event: event, normalizedFlags: raw)
                ? nil
                : Unmanaged.passUnretained(event)

        case .keyUp:
            if event.getIntegerValueField(.eventSourceUserData) == ShortcutSynthesizer.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
            guard !gestureEngine.isHandlingRightMouse else {
                return Unmanaged.passUnretained(event)
            }
            return mouseControlController.handleTriggerEvent(type: type, event: event)
                ? nil
                : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Annotated scroll tap (main run loop)

    func handleAnnotatedScroll(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            mouseControlController.stopSmoothScroll()
            if let scrollEventTap {
                CGEvent.tapEnable(tap: scrollEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == MouseControlController.syntheticScrollMarker {
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
        guard scrollEventTap == nil else { return true }

        let mask = eventMask(for: .scrollWheel)
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: veltoScrollEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        scrollEventTap = tap
        scrollRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopScrollEventTap() {
        mouseControlController.stopSmoothScroll()
        if let tap = scrollEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = scrollRunLoopSource {
            CFRunLoopSourceInvalidate(source)
            if CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        scrollEventTap = nil
        scrollRunLoopSource = nil
    }

    // MARK: - Cross-thread helpers

    /// Schedule `work` to run on the tap thread's runloop. Used by main-thread
    /// observers that need to mutate engine state safely. If the tap thread
    /// isn't running yet (start hasn't been called), the work is dropped.
    private func performOnTapThread(_ work: @escaping () -> Void) {
        guard let runLoop = tapRunLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    private func applyPreferenceSnapshots(_ preferences: AppPreferences) {
        mouseControlController.updatePreferences(preferences.mouseControl)
        windowDragController.updateModifierFlags(
            move: preferences.windowMoveModifierFlags,
            resize: preferences.windowResizeModifierFlags
        )
        contentZoomController.updateModifierFlag(preferences.contentZoomModifierFlags)
        windowShortcutController.updateShortcut(preferences.windowMaximizeShortcut)
    }

    private func prewarmCaches() {
        DispatchQueue.global(qos: .utility).async {
            DisplayCoordinateConverter.prewarm()
        }
    }

    private func eventMask(for type: CGEventType) -> CGEventMask {
        CGEventMask(1) << CGEventMask(type.rawValue)
    }
}
