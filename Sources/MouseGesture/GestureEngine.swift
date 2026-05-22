import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// State machine that handles the right-click drawn gesture lifecycle:
/// `idle → pending → gesturing → (match | cancel) → idle`.
///
/// Designed to be driven exclusively from the event-tap runloop thread.
/// Timers run as `CFRunLoopTimer`s scheduled on that same runloop so we
/// never have to cross-thread synchronize state during a gesture.
final class GestureEngine {
    /// Snapshot of preferences fields the engine actually reads. Decoupled
    /// from `AppPreferences` so the engine doesn't pull in unrelated fields.
    struct PreferencesSnapshot {
        var showTrail: Bool
        var recognitionThreshold: Double
        var gestureTimeoutSeconds: Double
        var gestureTargetPolicy: GestureTargetPolicy

        init(from preferences: AppPreferences) {
            self.showTrail = preferences.showTrail
            self.recognitionThreshold = preferences.recognitionThreshold
            self.gestureTimeoutSeconds = preferences.gestureTimeoutSeconds
            self.gestureTargetPolicy = preferences.gestureTargetPolicy
        }
    }

    private enum InputState {
        case idle
        case pending
        case gesturing
        case cleanupAwaitingUp
    }

    var onGestureMatch: ((GestureMatch?) -> Void)?
    var onStatusChange: ((String) -> Void)?

    private let recognizer = GestureRecognizer()
    private let overlay = GestureOverlayController()

    private var preferences: PreferencesSnapshot
    private var gestures: [GestureCommand] = []
    private var gesturesVersion: UInt64 = 0

    private var state: InputState = .idle
    private var points: [CGPoint] = []
    private var displayPoints: [CGPoint] = []
    private var startPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero

    private var frontmostApplicationAtGestureStart: NSRunningApplication?
    private var lastFrontmostApplication: NSRunningApplication?

    private var gestureTimeoutTimer: CFRunLoopTimer?
    private var safetyTimer: CFRunLoopTimer?
    private weak var runLoopOwner: AnyObject?
    private var tapRunLoop: CFRunLoop?

    private let movementThreshold: CGFloat = 10
    private let minimumRecordedPointDistance: CGFloat = 2
    private let maximumGesturePointCount = 512
    private let safetyTimeout: TimeInterval = 8
    private let syntheticMarker: Int64 = 0x4D474C524550

    init(preferences: AppPreferences, gestures: [GestureCommand], gesturesVersion: UInt64) {
        self.preferences = PreferencesSnapshot(from: preferences)
        self.gestures = gestures
        self.gesturesVersion = gesturesVersion
        self.lastFrontmostApplication = NSWorkspace.shared.frontmostApplication
    }

    /// Called once on the tap thread right after the runloop is up.
    func attach(runLoop: CFRunLoop) {
        tapRunLoop = runLoop
    }

    func detach() {
        invalidateTimer(&gestureTimeoutTimer)
        invalidateTimer(&safetyTimer)
        tapRunLoop = nil
        resetTracking()
    }

    func updatePreferences(_ preferences: AppPreferences) {
        self.preferences = PreferencesSnapshot(from: preferences)
    }

    func updateGestures(_ gestures: [GestureCommand], version: UInt64) {
        self.gestures = gestures
        self.gesturesVersion = version
    }

    func updateLastFrontmostApplication(_ application: NSRunningApplication) {
        if state == .idle {
            lastFrontmostApplication = application
        }
    }

    // MARK: - Tap callback entry points (called on tap thread)

    /// `true` if the engine is mid-gesture and should swallow the right-click
    /// event so the system menu doesn't pop up.
    var isHandlingRightMouse: Bool {
        state != .idle
    }

    /// Returns whether the engine consumed the event. Tap thread.
    func handleRightMouseDown(at location: CGPoint) -> Bool {
        if state != .idle {
            resetTracking()
        }

        state = .pending
        frontmostApplicationAtGestureStart = lastFrontmostApplication ?? NSWorkspace.shared.frontmostApplication
        startPoint = location
        lastPoint = location
        points = [location]
        displayPoints = [DisplayCoordinateConverter.eventLocationToOverlayPoint(location)]
        armSafetyTimer()
        return true
    }

    func handleRightMouseDragged(at location: CGPoint) -> Bool {
        switch state {
        case .pending:
            _ = appendPoint(location)
            if distance(startPoint, location) >= movementThreshold {
                state = .gesturing
                armGestureTimeoutTimer()
                if preferences.showTrail {
                    overlay.show(points: displayPoints)
                }
            }
            return true

        case .gesturing:
            let appended = appendPoint(location)
            if appended {
                armGestureTimeoutTimer()
                if preferences.showTrail {
                    overlay.update(points: displayPoints)
                }
            }
            return true

        case .cleanupAwaitingUp:
            lastPoint = location
            return true

        case .idle:
            return false
        }
    }

    func handleRightMouseUp(at location: CGPoint) -> Bool {
        switch state {
        case .pending:
            let point = startPoint
            resetTracking()
            replayRightClickAsync(at: point)
            return true

        case .gesturing:
            _ = appendPoint(location)
            let capturedPoints = points
            let capturedTargetPoint = startPoint
            let capturedFrontmostApplication = frontmostApplicationAtGestureStart
            let capturedVersion = gesturesVersion
            let capturedGestures = gestures
            let capturedPreferences = preferences
            resetTracking()

            DispatchQueue.main.async { [weak self] in
                self?.runGesture(
                    points: capturedPoints,
                    targetPoint: capturedTargetPoint,
                    frontmostApplicationAtGestureStart: capturedFrontmostApplication,
                    gestures: capturedGestures,
                    gesturesVersion: capturedVersion,
                    preferences: capturedPreferences
                )
            }
            return true

        case .cleanupAwaitingUp:
            resetTracking()
            return true

        case .idle:
            return false
        }
    }

    // MARK: - Gesture matching

    private func runGesture(
        points: [CGPoint],
        targetPoint: CGPoint,
        frontmostApplicationAtGestureStart: NSRunningApplication?,
        gestures: [GestureCommand],
        gesturesVersion: UInt64,
        preferences: PreferencesSnapshot
    ) {
        let threshold = CGFloat(preferences.recognitionThreshold)
        let best = recognizer.bestCandidate(points: points, commands: gestures, version: gesturesVersion)
        let match = best.flatMap { $0.distance <= threshold ? $0 : nil }

        onGestureMatch?(match)

        if let match {
            guard let shortcut = match.command.shortcut else { return }
            resolveTargetAndExecute(
                shortcut: shortcut,
                targetPoint: targetPoint,
                policy: preferences.gestureTargetPolicy,
                frontmostApplicationAtGestureStart: frontmostApplicationAtGestureStart
            )
        }
    }

    private func resolveTargetAndExecute(
        shortcut: Shortcut,
        targetPoint: CGPoint,
        policy: GestureTargetPolicy,
        frontmostApplicationAtGestureStart: NSRunningApplication?
    ) {
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

    // MARK: - Right-click replay

    private func replayRightClickAsync(at point: CGPoint) {
        DispatchQueue.global(qos: .userInteractive).async { [marker = syntheticMarker] in
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
            ) else { return }
            down.setIntegerValueField(.eventSourceUserData, value: marker)
            up.setIntegerValueField(.eventSourceUserData, value: marker)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }

    /// Mark indicating events we synthesized ourselves so the tap can let them
    /// pass through without re-entering gesture logic.
    var rightClickSyntheticMarker: Int64 { syntheticMarker }

    // MARK: - Point buffer

    @discardableResult
    private func appendPoint(_ point: CGPoint) -> Bool {
        lastPoint = point
        guard let previous = points.last else {
            points = [point]
            displayPoints = [DisplayCoordinateConverter.eventLocationToOverlayPoint(point)]
            return true
        }

        guard distance(previous, point) >= minimumRecordedPointDistance else {
            return false
        }

        let displayPoint = DisplayCoordinateConverter.eventLocationToOverlayPoint(point)
        if points.count >= maximumGesturePointCount {
            points[points.count - 1] = point
            displayPoints[displayPoints.count - 1] = displayPoint
        } else {
            points.append(point)
            displayPoints.append(displayPoint)
        }
        return true
    }

    // MARK: - State reset

    private func resetTracking() {
        state = .idle
        gestureTimeoutTimer.map { CFRunLoopTimerSetNextFireDate($0, .greatestFiniteMagnitude) }
        safetyTimer.map { CFRunLoopTimerSetNextFireDate($0, .greatestFiniteMagnitude) }
        points = []
        displayPoints = []
        frontmostApplicationAtGestureStart = nil
        startPoint = .zero
        lastPoint = .zero
        overlay.hide()
    }

    private func cancelGestureAndWaitForRightMouseUp() {
        state = .cleanupAwaitingUp
        gestureTimeoutTimer.map { CFRunLoopTimerSetNextFireDate($0, .greatestFiniteMagnitude) }
        safetyTimer.map { CFRunLoopTimerSetNextFireDate($0, .greatestFiniteMagnitude) }
        points = []
        displayPoints = []
        frontmostApplicationAtGestureStart = nil
        overlay.hide()
    }

    // MARK: - Timers (CFRunLoopTimer on tap runloop)

    private func armSafetyTimer() {
        let timeout = max(safetyTimeout, preferences.gestureTimeoutSeconds + 2)
        let nextFire = CFAbsoluteTimeGetCurrent() + timeout

        if let timer = safetyTimer {
            CFRunLoopTimerSetNextFireDate(timer, nextFire)
            return
        }
        safetyTimer = makeTimer(fireDate: nextFire) { [weak self] in
            self?.fireSafetyTimer()
        }
    }

    private func armGestureTimeoutTimer() {
        let timeout = max(0.5, preferences.gestureTimeoutSeconds)
        let nextFire = CFAbsoluteTimeGetCurrent() + timeout

        if let timer = gestureTimeoutTimer {
            CFRunLoopTimerSetNextFireDate(timer, nextFire)
            return
        }
        gestureTimeoutTimer = makeTimer(fireDate: nextFire) { [weak self] in
            self?.fireGestureTimeoutTimer()
        }
    }

    private func fireSafetyTimer() {
        guard state != .idle else { return }
        cancelGestureAndWaitForRightMouseUp()
    }

    private func fireGestureTimeoutTimer() {
        guard state == .gesturing else { return }
        cancelGestureAndWaitForRightMouseUp()
        DispatchQueue.main.async { [weak self] in
            self?.onGestureMatch?(nil)
            self?.onStatusChange?("本次手势超时,已取消")
        }
    }

    private func makeTimer(fireDate: CFAbsoluteTime, handler: @escaping () -> Void) -> CFRunLoopTimer? {
        guard let runLoop = tapRunLoop else { return nil }

        let box = Unmanaged.passRetained(TimerBox(handler: handler)).toOpaque()
        var context = CFRunLoopTimerContext(
            version: 0,
            info: box,
            retain: { ptr in
                guard let ptr else { return nil }
                _ = Unmanaged<TimerBox>.fromOpaque(ptr).retain()
                return ptr
            },
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<TimerBox>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let timer = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            fireDate,
            0,   // non-repeating; we use SetNextFireDate to re-arm
            0,
            0,
            { _, info in
                guard let info else { return }
                let box = Unmanaged<TimerBox>.fromOpaque(info).takeUnretainedValue()
                box.handler()
            },
            &context
        )

        // CFRunLoopTimerContext.retain was invoked by CFRunLoopTimerCreate; release
        // our own +1 here so the box is only retained by the timer itself.
        Unmanaged<TimerBox>.fromOpaque(box).release()

        if let timer {
            CFRunLoopAddTimer(runLoop, timer, .commonModes)
        }
        return timer
    }

    private func invalidateTimer(_ timer: inout CFRunLoopTimer?) {
        if let timer {
            CFRunLoopTimerInvalidate(timer)
        }
        timer = nil
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

private final class TimerBox {
    let handler: () -> Void
    init(handler: @escaping () -> Void) {
        self.handler = handler
    }
}
