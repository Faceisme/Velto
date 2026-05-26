import AppKit
import ApplicationServices
@preconcurrency import CoreFoundation
import CoreGraphics
import Foundation

/// Owns the global CGEventTap, the dedicated tap-callback thread, and the four
/// sub-controllers that act on events:
/// - `GestureEngine`        right-click gesture state machine
/// - `WindowDragController` modifier+drag move/resize
/// - `ContentZoomController` modifier+scroll content zoom
/// - `WindowShortcutController` shortcut-triggered window actions
///
/// The tap callback runs on a private high-QoS thread+runloop. State that's
/// only touched in the callback (gesture state machine, drag session) lives
/// inside the sub-controllers on that thread — no cross-thread sync per
/// event. The few fields read from the callback that are also written by the
/// main-thread preferences observer (modifier snapshots) use short NSLocks.
private let mouseGestureEventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handle(proxy: proxy, type: type, event: event)
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
    private let windowDragController = WindowDragController()
    private let contentZoomController = ContentZoomController()
    private let windowShortcutController = WindowShortcutController()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
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

        let mask = eventMask(for: .rightMouseDown)
            | eventMask(for: .rightMouseDragged)
            | eventMask(for: .rightMouseUp)
            | eventMask(for: .mouseMoved)
            | eventMask(for: .scrollWheel)
            | eventMask(for: .flagsChanged)
            | eventMask(for: .keyDown)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mouseGestureEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            onStatusChange?("事件拦截启动失败")
            return false
        }

        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            eventTap = nil
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
        thread.name = "com.face.mygestures.eventtap"
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
    }

    // MARK: - Event dispatch (tap thread)

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
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
            _ = gestureEngine.handleRightMouseDown(at: event.location)
            return nil

        case .rightMouseDragged:
            if event.getIntegerValueField(.eventSourceUserData) == gestureEngine.rightClickSyntheticMarker {
                return Unmanaged.passUnretained(event)
            }
            return gestureEngine.handleRightMouseDragged(at: event.location)
                ? nil
                : Unmanaged.passUnretained(event)

        case .rightMouseUp:
            if event.getIntegerValueField(.eventSourceUserData) == gestureEngine.rightClickSyntheticMarker {
                return Unmanaged.passUnretained(event)
            }
            return gestureEngine.handleRightMouseUp(at: event.location)
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

        case .scrollWheel:
            guard !gestureEngine.isHandlingRightMouse else {
                return Unmanaged.passUnretained(event)
            }
            if raw == 0 { return Unmanaged.passUnretained(event) }
            return contentZoomController.handleScrollWheel(event: event, normalizedFlags: raw)
                ? nil
                : Unmanaged.passUnretained(event)

        case .flagsChanged:
            guard !gestureEngine.isHandlingRightMouse else {
                return Unmanaged.passUnretained(event)
            }
            contentZoomController.handleFlagsChanged(normalizedFlags: raw)
            windowDragController.handleFlagsChanged(event: event, normalizedFlags: raw)
            return Unmanaged.passUnretained(event)

        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == ShortcutSynthesizer.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
            guard !gestureEngine.isHandlingRightMouse else {
                return Unmanaged.passUnretained(event)
            }
            return windowShortcutController.handleKeyDown(event: event, normalizedFlags: raw)
                ? nil
                : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
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
