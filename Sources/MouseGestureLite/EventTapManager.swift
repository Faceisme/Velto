import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private let mouseGestureEventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handle(proxy: proxy, type: type, event: event)
}

final class EventTapManager {
    var onStatusChange: ((String) -> Void)?
    var onGestureMatch: ((GestureMatch?) -> Void)?

    private enum InputState: String {
        case idle = "空闲"
        case pending = "等待判断"
        case gesturing = "手势中"
        case cleanupAwaitingUp = "保险重置，等待松开"
    }

    private enum WindowDragMode {
        case move
        case resize
    }

    private enum ResizeEdge {
        case min
        case max
    }

    private struct WindowDragSession {
        var mode: WindowDragMode
        var window: AXUIElement
        var startPointer: CGPoint
        var startDragPointer: CGPoint
        var usesConvertedDragPointer: Bool
        var startFrame: CGRect
        var screenFrame: CGRect
        var horizontalEdge: ResizeEdge
        var verticalEdge: ResizeEdge
    }

    private struct WindowDragUpdate {
        var mode: WindowDragMode
        var location: CGPoint
    }

    private let store: GestureStore
    private let recognizer = GestureRecognizer()
    private let overlay = GestureOverlayController()
    private let stateQueue = DispatchQueue(label: "com.face.mygestures.eventtap.state", qos: .userInteractive)
    private let stateQueueKey = DispatchSpecificKey<Void>()
    private let windowControlQueue = DispatchQueue(label: "com.face.mygestures.window-control", qos: .userInteractive)
    private let windowControlLock = NSLock()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    private var state: InputState = .idle
    private var points: [CGPoint] = []
    private var displayPoints: [CGPoint] = []
    private var startPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var gestureTimeoutToken: UUID?
    private var safetyToken: UUID?
    private var frontmostApplicationAtGestureStart: NSRunningApplication?
    private var lastFrontmostApplication: NSRunningApplication?
    private var windowDragSession: WindowDragSession?
    private var pendingWindowDragUpdate: WindowDragUpdate?
    private var windowDragUpdateScheduled = false
    private var windowMoveModifierFlags: UInt64
    private var windowResizeModifierFlags: UInt64
    private var activationObserver: NSObjectProtocol?
    private var storeObserver: NSObjectProtocol?
    private var preferences: AppPreferences

    private let movementThreshold: CGFloat = 10
    private let minimumRecordedPointDistance: CGFloat = 2
    private let maximumGesturePointCount = 512
    private let safetyTimeout: TimeInterval = 8
    private let syntheticMarker: Int64 = 0x4D474C524550

    init(store: GestureStore = .shared) {
        self.store = store
        preferences = store.preferences
        windowMoveModifierFlags = preferences.windowMoveModifierFlags
        windowResizeModifierFlags = preferences.windowResizeModifierFlags
        stateQueue.setSpecific(key: stateQueueKey, value: ())
        lastFrontmostApplication = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self.stateQueue.async {
                if self.state == .idle {
                    self.lastFrontmostApplication = application
                }
            }
        }

        storeObserver = NotificationCenter.default.addObserver(
            forName: .gestureStoreDidChange,
            object: store,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let preferences = store.preferences
            self.updateWindowControlModifierSnapshot(from: preferences)
            self.stateQueue.async {
                self.preferences = preferences
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

    func start() -> Bool {
        guard eventTap == nil else {
            return true
        }

        guard PermissionManager.isAccessibilityTrusted else {
            onStatusChange?("需要辅助功能权限")
            PermissionManager.requestAccessibilityPrompt()
            return false
        }

        let mask = eventMask(for: .rightMouseDown)
            | eventMask(for: .rightMouseDragged)
            | eventMask(for: .rightMouseUp)
            | eventMask(for: .mouseMoved)
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
            let runLoop = CFRunLoopGetCurrent()
            if let self {
                self.syncState {
                    self.tapRunLoop = runLoop
                }
            }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        thread.name = "com.face.mygestures.eventtap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        ready.wait()

        CGEvent.tapEnable(tap: tap, enable: true)
        prewarmWindowControlCaches()
        onStatusChange?("监听中（主动拦截）")
        return true
    }

    func stop() {
        let (runLoop, tap, source) = syncState {
            state = .idle
            gestureTimeoutToken = nil
            safetyToken = nil
            points = []
            displayPoints = []
            frontmostApplicationAtGestureStart = nil
            resetWindowDragSession()
            startPoint = .zero
            lastPoint = .zero
            let runLoop = tapRunLoop
            let tap = eventTap
            let source = runLoopSource
            tapRunLoop = nil
            eventTap = nil
            runLoopSource = nil
            hideOverlay()
            return (runLoop, tap, source)
        }

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

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return syncState {
                handleLocked(proxy: proxy, type: type, event: event)
            }
        }

        guard isRightMouseEvent(type) else {
            if type == .keyDown,
               event.getIntegerValueField(.eventSourceUserData) == ShortcutSynthesizer.syntheticEventMarker {
                return Unmanaged.passUnretained(event)
            }
            if type == .mouseMoved,
               ModifierFormatter.normalizedRawValue(from: event.flags) == 0 {
                return Unmanaged.passUnretained(event)
            }
            if type == .mouseMoved,
               windowDragModeSnapshot(for: event.flags) == nil {
                return Unmanaged.passUnretained(event)
            }
            if isWindowControlEvent(type) {
                return syncState {
                    handleWindowControlLocked(type: type, event: event)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        return syncState {
            handleLocked(proxy: proxy, type: type, event: event)
        }
    }

    private func handleLocked(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetTracking()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            onStatusChange?("监听中（tap 已重启）")
            return nil
        }

        guard isRightMouseEvent(type) else {
            return Unmanaged.passUnretained(event)
        }

        let location = event.location

        switch type {
        case .rightMouseDown:
            return handleRightMouseDown(at: location)
        case .rightMouseDragged:
            return handleRightMouseDragged(at: location, event: event)
        case .rightMouseUp:
            return handleRightMouseUp(at: location, event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleRightMouseDown(at location: CGPoint) -> Unmanaged<CGEvent>? {
        if state != .idle {
            resetTracking()
        }

        state = .pending
        frontmostApplicationAtGestureStart = lastFrontmostApplication ?? NSWorkspace.shared.frontmostApplication
        startPoint = location
        lastPoint = location
        points = [location]
        displayPoints = [DisplayCoordinateConverter.eventLocationToOverlayPoint(location)]
        armGestureTimeoutTimer()
        armSafetyTimer()
        return nil
    }

    private func handleRightMouseDragged(at location: CGPoint, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch state {
        case .pending:
            appendPoint(location)

            let moved = distance(startPoint, location)
            if moved >= movementThreshold {
                state = .gesturing
                if preferences.showTrail {
                    showOverlay(points: displayPoints)
                }
            }
            return nil

        case .gesturing:
            appendPoint(location)
            if preferences.showTrail {
                updateOverlay(points: displayPoints)
            }
            return nil

        case .cleanupAwaitingUp:
            return nil

        case .idle:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleRightMouseUp(at location: CGPoint, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch state {
        case .pending:
            let point = startPoint
            resetTracking()
            replayRightClickAsync(at: point)
            return nil

        case .gesturing:
            appendPoint(location)
            let capturedPoints = points
            let capturedTargetPoint = startPoint
            let capturedFrontmostApplication = frontmostApplicationAtGestureStart
            resetTracking()

            DispatchQueue.main.async { [weak self] in
                self?.runGesture(
                    points: capturedPoints,
                    targetPoint: capturedTargetPoint,
                    frontmostApplicationAtGestureStart: capturedFrontmostApplication
                )
            }
            return nil

        case .cleanupAwaitingUp:
            resetTracking()
            return nil

        case .idle:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleWindowControlLocked(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if state != .idle {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            return handleWindowShortcutLocked(event: event)
        }

        if type == .flagsChanged {
            if let mode = windowDragMode(for: event.flags) {
                prewarmWindowDragLookup(mode: mode, at: event.location)
            } else {
                resetWindowDragSession()
            }
            return Unmanaged.passUnretained(event)
        }

        guard let mode = windowDragMode(for: event.flags) else {
            resetWindowDragSession()
            return Unmanaged.passUnretained(event)
        }

        guard type == .mouseMoved else {
            return Unmanaged.passUnretained(event)
        }

        enqueueWindowDragUpdate(mode: mode, at: event.location)
        return Unmanaged.passUnretained(event)
    }

    private func prewarmWindowControlCaches() {
        DispatchQueue.global(qos: .utility).async {
            DisplayCoordinateConverter.prewarm()
        }
    }

    private func updateWindowControlModifierSnapshot(from preferences: AppPreferences) {
        windowControlLock.lock()
        windowMoveModifierFlags = preferences.windowMoveModifierFlags
        windowResizeModifierFlags = preferences.windowResizeModifierFlags
        windowControlLock.unlock()
    }

    private func windowDragModeSnapshot(for flags: CGEventFlags) -> WindowDragMode? {
        let rawValue = ModifierFormatter.normalizedRawValue(from: flags)

        windowControlLock.lock()
        let resizeFlags = windowResizeModifierFlags
        let moveFlags = windowMoveModifierFlags
        windowControlLock.unlock()

        return windowDragMode(rawValue: rawValue, moveFlags: moveFlags, resizeFlags: resizeFlags)
    }

    private func handleWindowShortcutLocked(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let shortcut = preferences.windowMaximizeShortcut,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              eventMatches(event, shortcut: shortcut) else {
            return Unmanaged.passUnretained(event)
        }

        let point = event.location
        DispatchQueue.global(qos: .userInteractive).async {
            GestureTargetController.maximizeWindowUnderPointer(at: point)
        }
        return nil
    }

    private func enqueueWindowDragUpdate(mode: WindowDragMode, at location: CGPoint) {
        windowControlLock.lock()
        pendingWindowDragUpdate = WindowDragUpdate(mode: mode, location: location)
        let shouldSchedule = !windowDragUpdateScheduled
        if shouldSchedule {
            windowDragUpdateScheduled = true
        }
        windowControlLock.unlock()

        guard shouldSchedule else {
            return
        }

        windowControlQueue.async { [weak self] in
            self?.flushWindowDragUpdates()
        }
    }

    private func flushWindowDragUpdates() {
        windowControlLock.lock()
        guard let update = pendingWindowDragUpdate else {
            windowDragUpdateScheduled = false
            windowControlLock.unlock()
            return
        }
        pendingWindowDragUpdate = nil
        windowControlLock.unlock()

        _ = updateWindowDrag(mode: update.mode, at: update.location)

        windowControlLock.lock()
        let shouldScheduleNextFlush = pendingWindowDragUpdate != nil
        if !shouldScheduleNextFlush {
            windowDragUpdateScheduled = false
        }
        windowControlLock.unlock()

        guard shouldScheduleNextFlush else {
            return
        }

        windowControlQueue.async { [weak self] in
            self?.flushWindowDragUpdates()
        }
    }

    private func resetWindowDragSession() {
        windowControlLock.lock()
        pendingWindowDragUpdate = nil
        windowDragUpdateScheduled = false
        windowControlLock.unlock()

        windowControlQueue.async { [weak self] in
            self?.windowDragSession = nil
        }
    }

    private func prewarmWindowDragLookup(mode: WindowDragMode, at location: CGPoint) {
        windowControlQueue.async { [weak self] in
            guard let self else { return }
            _ = self.beginWindowDrag(mode: mode, at: location)
        }
    }

    private func updateWindowDrag(mode: WindowDragMode, at location: CGPoint) -> Bool {
        if windowDragSession?.mode != mode {
            windowDragSession = beginWindowDrag(mode: mode, at: location)
        }

        guard let session = windowDragSession else {
            return false
        }

        let currentPointer = windowDragPoint(
            from: location,
            usesConvertedPointer: session.usesConvertedDragPointer
        )
        let dx = currentPointer.x - session.startDragPointer.x
        let dy = currentPointer.y - session.startDragPointer.y

        switch session.mode {
        case .move:
            let nextOrigin = CGPoint(
                x: session.startFrame.origin.x + dx,
                y: session.startFrame.origin.y + dy
            )
            return GestureTargetController.setPosition(nextOrigin, ofWindow: session.window)

        case .resize:
            let nextFrame = resizedFrame(from: session, dx: dx, dy: dy)
            return GestureTargetController.setFrame(nextFrame, ofWindow: session.window)
        }
    }

    private func beginWindowDrag(mode: WindowDragMode, at location: CGPoint) -> WindowDragSession? {
        guard let window = GestureTargetController.windowUnderPointer(at: location),
              let frame = GestureTargetController.frame(ofWindow: window) else {
            return nil
        }

        let pointer = location
        let dragPoint = initialWindowDragPoint(for: location, in: frame)
        let screenFrame = DisplayCoordinateConverter.visibleAccessibilityFrame(containingEventLocation: pointer)
        return WindowDragSession(
            mode: mode,
            window: window,
            startPointer: pointer,
            startDragPointer: dragPoint.point,
            usesConvertedDragPointer: dragPoint.usesConvertedPointer,
            startFrame: frame,
            screenFrame: screenFrame,
            horizontalEdge: dragPoint.point.x < frame.midX ? .min : .max,
            verticalEdge: dragPoint.point.y < frame.midY ? .min : .max
        )
    }

    private func initialWindowDragPoint(
        for location: CGPoint,
        in frame: CGRect
    ) -> (point: CGPoint, usesConvertedPointer: Bool) {
        if frame.contains(location) {
            return (location, false)
        }

        let convertedPoint = DisplayCoordinateConverter.eventLocationToAccessibilityPoint(location)
        if frame.contains(convertedPoint) {
            return (convertedPoint, true)
        }

        let rawDistance = distance(from: location, to: frame)
        let convertedDistance = distance(from: convertedPoint, to: frame)
        return rawDistance <= convertedDistance
            ? (location, false)
            : (convertedPoint, true)
    }

    private func windowDragPoint(
        from location: CGPoint,
        usesConvertedPointer: Bool
    ) -> CGPoint {
        usesConvertedPointer
            ? DisplayCoordinateConverter.eventLocationToAccessibilityPoint(location)
            : location
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        return hypot(point.x - clampedX, point.y - clampedY)
    }

    private func resizedFrame(from session: WindowDragSession, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minimumSize = CGSize(width: 160, height: 120)
        var origin = session.startFrame.origin
        var size = session.startFrame.size

        switch session.horizontalEdge {
        case .min:
            let newWidth = session.startFrame.width - dx
            if newWidth < minimumSize.width {
                origin.x = session.startFrame.maxX - minimumSize.width
                size.width = minimumSize.width
            } else {
                origin.x = session.startFrame.origin.x + dx
                size.width = newWidth
            }
        case .max:
            size.width = max(minimumSize.width, session.startFrame.width + dx)
        }

        switch session.verticalEdge {
        case .min:
            let newHeight = session.startFrame.height - dy
            if newHeight < minimumSize.height {
                origin.y = session.startFrame.maxY - minimumSize.height
                size.height = minimumSize.height
            } else {
                origin.y = session.startFrame.origin.y + dy
                size.height = newHeight
            }
        case .max:
            size.height = max(minimumSize.height, session.startFrame.height + dy)
        }

        var result = CGRect(origin: origin, size: size)
        let screenFrame = session.screenFrame
        guard !screenFrame.isEmpty else {
            return result
        }

        if result.maxX > screenFrame.maxX {
            if session.horizontalEdge == .max {
                result.size.width = screenFrame.maxX - result.origin.x
            } else {
                result.origin.x = screenFrame.maxX - result.size.width
            }
        }

        if result.minX < screenFrame.minX {
            result.origin.x = screenFrame.minX
            if session.horizontalEdge == .min {
                result.size.width = session.startFrame.maxX - screenFrame.minX
            }
        }

        if result.maxY > screenFrame.maxY {
            if session.verticalEdge == .max {
                result.size.height = screenFrame.maxY - result.origin.y
            } else {
                result.origin.y = screenFrame.maxY - result.size.height
            }
        }

        if result.minY < screenFrame.minY {
            result.origin.y = screenFrame.minY
            if session.verticalEdge == .min {
                result.size.height = session.startFrame.maxY - screenFrame.minY
            }
        }

        result.size.width = max(result.size.width, minimumSize.width)
        result.size.height = max(result.size.height, minimumSize.height)
        return result
    }

    private func windowDragMode(for flags: CGEventFlags) -> WindowDragMode? {
        let rawValue = ModifierFormatter.normalizedRawValue(from: flags)
        return windowDragMode(
            rawValue: rawValue,
            moveFlags: preferences.windowMoveModifierFlags,
            resizeFlags: preferences.windowResizeModifierFlags
        )
    }

    private func windowDragMode(rawValue: UInt64, moveFlags: UInt64, resizeFlags: UInt64) -> WindowDragMode? {
        if resizeFlags != 0, rawValue == resizeFlags {
            return .resize
        }

        if moveFlags != 0, rawValue == moveFlags {
            return .move
        }

        return nil
    }

    private func runGesture(
        points: [CGPoint],
        targetPoint: CGPoint,
        frontmostApplicationAtGestureStart: NSRunningApplication?
    ) {
        let threshold = CGFloat(store.preferences.recognitionThreshold)
        let best = recognizer.bestCandidate(points: points, commands: store.gestures)
        let match = best.flatMap { candidate in
            candidate.distance <= threshold ? candidate : nil
        }

        onGestureMatch?(match)

        if let match {
            guard let shortcut = match.command.shortcut else {
                return
            }

            resolveTargetAndExecute(
                shortcut: shortcut,
                targetPoint: targetPoint,
                frontmostApplicationAtGestureStart: frontmostApplicationAtGestureStart
            )
        }
    }

    private func resolveTargetAndExecute(
        shortcut: Shortcut,
        targetPoint: CGPoint,
        frontmostApplicationAtGestureStart: NSRunningApplication?
    ) {
        let policy = store.preferences.gestureTargetPolicy

        switch policy {
        case .activeWindow:
            let target = GestureTargetController.executionTarget(
                at: targetPoint,
                policy: policy,
                frontmostApplicationAtGestureStart: frontmostApplicationAtGestureStart
            )
            executeMatchedGesture(
                shortcut: shortcut,
                target: target,
                frontmostApplicationAtGestureStart: frontmostApplicationAtGestureStart
            )

        case .windowUnderPointer:
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                let target = GestureTargetController.executionTarget(
                    at: targetPoint,
                    policy: policy,
                    frontmostApplicationAtGestureStart: nil
                )

                DispatchQueue.main.async { [weak self] in
                    self?.executeMatchedGesture(
                        shortcut: shortcut,
                        target: target,
                        frontmostApplicationAtGestureStart: frontmostApplicationAtGestureStart
                    )
                }
            }
        }
    }

    private func executeMatchedGesture(
        shortcut: Shortcut,
        target: GestureExecutionTarget,
        frontmostApplicationAtGestureStart: NSRunningApplication?
    ) {
        GestureTargetController.prepareForExecution(target)

        DispatchQueue.main.asyncAfter(deadline: .now() + target.deliveryDelay) {
            if target.restoresOriginalFrontmostApplication {
                GestureTargetController.restoreFrontmostApplication(frontmostApplicationAtGestureStart)
            }

            if GestureTargetController.performDirectWindowCloseIfAvailable(for: target, shortcut: shortcut) {
                return
            }

            ShortcutSynthesizer.send(shortcut)

            if target.restoresOriginalFrontmostApplication {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    GestureTargetController.restoreFrontmostApplication(frontmostApplicationAtGestureStart)
                }
            }
        }
    }

    private func replayRightClick(at point: CGPoint) {
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseDown,
            mouseCursorPosition: point,
            mouseButton: .right
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseUp,
            mouseCursorPosition: point,
            mouseButton: .right
        ) else {
            return
        }

        down.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)

        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private func replayRightClickAsync(at point: CGPoint) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.replayRightClick(at: point)
        }
    }

    private func appendPoint(_ point: CGPoint) {
        lastPoint = point
        guard let previousPoint = points.last else {
            points = [point]
            displayPoints = [DisplayCoordinateConverter.eventLocationToOverlayPoint(point)]
            return
        }

        guard distance(previousPoint, point) >= minimumRecordedPointDistance else {
            return
        }

        let displayPoint = DisplayCoordinateConverter.eventLocationToOverlayPoint(point)
        if points.count >= maximumGesturePointCount {
            points[points.count - 1] = point
            displayPoints[displayPoints.count - 1] = displayPoint
        } else {
            points.append(point)
            displayPoints.append(displayPoint)
        }
    }

    private func resetTracking() {
        state = .idle
        clearTrackingState()
    }

    private func clearTrackingState() {
        gestureTimeoutToken = nil
        safetyToken = nil
        points = []
        displayPoints = []
        frontmostApplicationAtGestureStart = nil
        resetWindowDragSession()
        startPoint = .zero
        lastPoint = .zero
        hideOverlay()
    }

    private func armSafetyTimer() {
        let token = UUID()
        safetyToken = token
        let timeout = max(safetyTimeout, preferences.gestureTimeoutSeconds + 2)

        stateQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self,
                  self.safetyToken == token,
                  self.state != .idle else {
                return
            }

            self.state = .cleanupAwaitingUp
            self.clearTrackingState()
        }
    }

    private func armGestureTimeoutTimer() {
        let token = UUID()
        gestureTimeoutToken = token
        let timeout = max(0.5, preferences.gestureTimeoutSeconds)

        stateQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self,
                  self.gestureTimeoutToken == token,
                  self.state == .gesturing else {
                return
            }

            self.state = .cleanupAwaitingUp
            self.clearTrackingState()
            DispatchQueue.main.async { [weak self] in
                self?.onGestureMatch?(nil)
                self?.onStatusChange?("本次手势超时，已取消")
            }
        }
    }

    private func showOverlay(points: [CGPoint]) {
        overlay.show(points: points)
    }

    private func updateOverlay(points: [CGPoint]) {
        overlay.update(points: points)
    }

    private func hideOverlay() {
        overlay.hide()
    }

    private func syncState<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return work()
        }

        return stateQueue.sync {
            work()
        }
    }

    private func isRightMouseEvent(_ type: CGEventType) -> Bool {
        type == .rightMouseDown || type == .rightMouseDragged || type == .rightMouseUp
    }

    private func isWindowControlEvent(_ type: CGEventType) -> Bool {
        type == .mouseMoved ||
            type == .flagsChanged ||
            type == .keyDown
    }

    private func eventMask(for type: CGEventType) -> CGEventMask {
        CGEventMask(1) << CGEventMask(type.rawValue)
    }

    private func eventMatches(_ event: CGEvent, shortcut: Shortcut) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == shortcut.keyCode else {
            return false
        }

        let rawValue = ModifierFormatter.normalizedRawValue(from: event.flags)
        return rawValue == shortcut.modifierFlags
    }

    private func distance(_ left: CGPoint, _ right: CGPoint) -> CGFloat {
        hypot(left.x - right.x, left.y - right.y)
    }

}
