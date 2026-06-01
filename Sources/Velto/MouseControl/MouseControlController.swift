import AppKit
@preconcurrency import CoreFoundation
import CoreGraphics
import Foundation
import os

private struct MouseRuntimeTriggerKey: Hashable {
    let kind: MouseInputKind
    let code: UInt16
}

private struct MouseScrollHotkeyState {
    var acceleration = false
    var directionToggle = false
    var disableSmooth = false
}

private final class MouseScrollDebugLogger: @unchecked Sendable {
    static let shared = MouseScrollDebugLogger()

    private let queue = DispatchQueue(label: "com.face.velto.mouse-scroll.debug-log", qos: .utility)
    private let stateLock = NSLock()
    private var enabled = false
    private var eventCounter: UInt64 = 0
    private var fileHandle: FileHandle?

    private init() {}

    deinit {
        try? fileHandle?.close()
    }

    func setEnabled(_ shouldEnable: Bool) {
        stateLock.lock()
        let didChange = enabled != shouldEnable
        enabled = shouldEnable
        if shouldEnable {
            eventCounter = 0
        }
        stateLock.unlock()

        guard didChange else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if shouldEnable {
                self.openSession()
            } else {
                try? self.fileHandle?.close()
                self.fileHandle = nil
            }
        }
    }

    func nextEventID() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard enabled else { return 0 }
        eventCounter &+= 1
        return eventCounter
    }

    func log(_ message: @autoclosure () -> String) {
        stateLock.lock()
        let isEnabled = enabled
        stateLock.unlock()
        guard isEnabled else { return }
        let timestamp = MouseScrollDebugLogger.timestamp()
        let line = "\(timestamp) \(message())\n"
        queue.async { [weak self] in
            guard let data = line.data(using: .utf8) else { return }
            self?.fileHandle?.write(data)
        }
    }

    private func openSession() {
        try? fileHandle?.close()
        fileHandle = nil

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Velto", isDirectory: true)
        let fileURL = directory.appendingPathComponent("mouse-scroll-debug.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle.truncateFile(atOffset: 0)
        fileHandle = handle
        writeLine("session start pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "-")")
    }

    private func writeLine(_ message: String) {
        let timestamp = MouseScrollDebugLogger.timestamp()
        let line = "\(timestamp) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }

    private static func timestamp() -> String {
        String(format: "%.6f", CFAbsoluteTimeGetCurrent())
    }
}

private func mouseDebugNumber(_ value: Double) -> String {
    String(format: "%.4f", value)
}

private func mouseDebugOptionalNumber(_ value: Double?) -> String {
    guard let value else { return "-" }
    return mouseDebugNumber(value)
}

private func mouseDebugPair(_ value: (y: Double, x: Double)) -> String {
    "y=\(mouseDebugNumber(value.y)) x=\(mouseDebugNumber(value.x))"
}

final class MouseControlController: @unchecked Sendable {
    static let syntheticScrollMarker: Int64 = 0x56454C544F534352

    private let lock = NSLock()
    private let animator = MouseSmoothScrollAnimator()

    private var preferences = MouseControlPreferences.defaults
    private var hotkeyState = MouseScrollHotkeyState()
    private var consumedTriggers = Set<MouseRuntimeTriggerKey>()

    func updatePreferences(_ preferences: MouseControlPreferences) {
        MouseScrollDebugLogger.shared.setEnabled(preferences.debugLoggingEnabled)
        lock.lock()
        self.preferences = preferences
        lock.unlock()
        if !preferences.enabled {
            resetTransientState()
        }
    }

    func resetTransientState() {
        lock.lock()
        hotkeyState = MouseScrollHotkeyState()
        consumedTriggers.removeAll()
        lock.unlock()
        MouseScrollDebugLogger.shared.log("controller resetTransientState")
        animator.stop()
    }

    func stopSmoothScroll() {
        MouseScrollDebugLogger.shared.log("controller stopSmoothScroll")
        animator.stop()
    }

    func handleScrollWheel(event: CGEvent) -> Bool {
        let logger = MouseScrollDebugLogger.shared
        let debugID = logger.nextEventID()
        let marker = event.getIntegerValueField(.eventSourceUserData)
        let targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        logger.log("#\(debugID) input pid=\(targetPID) marker=\(marker) rawY(point=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))) fixedPt=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))) fixed=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))) rawX(point=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))) fixedPt=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))) fixed=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))) phase=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventScrollPhase))) momentum=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventMomentumPhase))) count=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventScrollCount)))")
        guard marker != Self.syntheticScrollMarker else {
            logger.log("#\(debugID) skip reason=synthetic-marker")
            return false
        }
        guard !isTrackpadLike(event) else {
            logger.log("#\(debugID) skip reason=trackpad-like phase=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventScrollPhase))) momentum=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventMomentumPhase))) count=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventScrollCount)))")
            return false
        }

        let bundleID = bundleIdentifier(for: event)
        let snapshot = snapshot(for: bundleID)
        guard snapshot.preferences.enabled else {
            logger.log("#\(debugID) skip reason=preferences-disabled bundle=\(bundleID ?? "-")")
            return false
        }

        var scrollEvent = MouseScrollEvent(event: event)
        let hasY = scrollEvent.y.isValid
        let hasX = scrollEvent.x.isValid
        guard hasY || hasX else {
            logger.log("#\(debugID) skip reason=no-valid-axis bundle=\(bundleID ?? "-")")
            return false
        }

        let profile = snapshot.profile
        let state = snapshot.hotkeyState
        let shouldShiftVertical = state.directionToggle && hasY && !hasX
        let reverseY = profile.reverse && (shouldShiftVertical ? profile.reverseHorizontal : profile.reverseVertical)
        let reverseX = profile.reverse && profile.reverseHorizontal

        if hasY && reverseY {
            scrollEvent.reverseY()
        }
        if hasX && reverseX {
            scrollEvent.reverseX()
        }

        let smoothAllowed = profile.smooth && !state.disableSmooth
        let smoothY = smoothAllowed && hasY && (shouldShiftVertical ? profile.smoothHorizontal : profile.smoothVertical)
        let smoothX = smoothAllowed && hasX && profile.smoothHorizontal

        var smoothValueY = 0.0
        var smoothValueX = 0.0
        if smoothY {
            scrollEvent.normalizeY(minimum: profile.minStep)
            smoothValueY = scrollEvent.y.usableValue
        }
        if smoothX {
            scrollEvent.normalizeX(minimum: profile.minStep)
            smoothValueX = scrollEvent.x.usableValue
        }
        logger.log("#\(debugID) decision bundle=\(bundleID ?? "-") hasY=\(hasY) hasX=\(hasX) smoothAllowed=\(smoothAllowed) smoothY=\(smoothY) smoothX=\(smoothX) shiftVertical=\(shouldShiftVertical) reverseY=\(reverseY) reverseX=\(reverseX) minStep=\(mouseDebugNumber(profile.minStep)) speedGain=\(mouseDebugNumber(profile.speedGain)) duration=\(mouseDebugNumber(profile.transitionFactor)) simulateTrackpad=\(profile.simulateTrackpad) accel=\(state.acceleration) dirToggle=\(state.directionToggle) disableSmooth=\(state.disableSmooth) smoothValueY=\(mouseDebugNumber(smoothValueY)) smoothValueX=\(mouseDebugNumber(smoothValueX))")

        var didSubmitSmoothEvent = false
        if smoothY || smoothX {
            didSubmitSmoothEvent = animator.submit(
                event: event,
                debugID: debugID,
                profile: profile,
                y: shouldShiftVertical ? 0.0 : smoothValueY,
                x: smoothValueX + (shouldShiftVertical ? smoothValueY : 0.0),
                speedMultiplier: state.acceleration ? 5.0 : 1.0
            )
            logger.log("#\(debugID) submit-return consumed=\(didSubmitSmoothEvent)")
        }

        let passY = hasY && !smoothY
        let passX = hasX && !smoothX
        if passY || passX {
            if smoothY { scrollEvent.clearY() }
            if smoothX { scrollEvent.clearX() }
            logger.log("#\(debugID) return consumed=false reason=pass-through passY=\(passY) passX=\(passX) clearY=\(smoothY) clearX=\(smoothX)")
            return false
        }

        logger.log("#\(debugID) return consumed=\(didSubmitSmoothEvent)")
        return didSubmitSmoothEvent
    }

    func handleTriggerEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.eventSourceUserData) != ShortcutSynthesizer.syntheticEventMarker,
              event.getIntegerValueField(.eventSourceUserData) != Self.syntheticScrollMarker else {
            return false
        }
        guard let triggerEvent = MouseTriggerEvent(type: type, event: event) else {
            return false
        }

        if triggerEvent.isMouseDown {
            animator.stop()
        }

        let bundleID = bundleIdentifier(for: event)
        var consumed = false
        let snapshot = snapshot(for: bundleID)

        lock.lock()
        if snapshot.preferences.enabled {
            updateHotkeyStateLocked(triggerEvent, hotkeys: snapshot.hotkeys)
            consumed = consumeButtonBindingLocked(triggerEvent, bindings: snapshot.bindings)
        }
        lock.unlock()

        return consumed
    }

    private func snapshot(for bundleID: String?) -> (
        preferences: MouseControlPreferences,
        profile: MouseScrollProfile,
        hotkeys: MouseScrollHotkeys,
        bindings: [MouseButtonBinding],
        hotkeyState: MouseScrollHotkeyState
    ) {
        lock.lock()
        defer { lock.unlock() }
        let prefs = preferences
        guard let rule = prefs.appRules.first(where: { $0.bundleIdentifier == bundleID }) else {
            return (prefs, prefs.scroll, prefs.hotkeys, prefs.buttonBindings, hotkeyState)
        }
        let profile = rule.inheritScroll ? prefs.scroll : rule.scroll
        let hotkeys = rule.inheritHotkeys ? prefs.hotkeys : rule.hotkeys
        let bindings = rule.inheritButtons ? prefs.buttonBindings : rule.buttonBindings
        return (prefs, profile, hotkeys, bindings, hotkeyState)
    }

    private func updateHotkeyStateLocked(_ event: MouseTriggerEvent, hotkeys: MouseScrollHotkeys) {
        if let trigger = hotkeys.acceleration,
           event.matches(trigger) {
            hotkeyState.acceleration = event.isDown
        }
        if let trigger = hotkeys.directionToggle,
           event.matches(trigger) {
            hotkeyState.directionToggle = event.isDown
        }
        if let trigger = hotkeys.disableSmooth,
           event.matches(trigger) {
            hotkeyState.disableSmooth = event.isDown
        }
    }

    private func consumeButtonBindingLocked(
        _ event: MouseTriggerEvent,
        bindings: [MouseButtonBinding]
    ) -> Bool {
        let key = MouseRuntimeTriggerKey(kind: event.kind, code: event.code)
        if !event.isDown {
            if consumedTriggers.remove(key) != nil {
                return true
            }
            return false
        }

        guard let binding = bindings.first(where: { $0.isEnabled && event.matches($0.trigger) }) else {
            return false
        }

        consumedTriggers.insert(key)
        execute(binding.action)
        return true
    }

    private func execute(_ action: MouseButtonAction) {
        switch action {
        case .system(let systemAction):
            ShortcutSynthesizer.send(systemAction.shortcut)
        case .shortcut(let shortcut):
            ShortcutSynthesizer.send(shortcut)
        case .openApplication(let path, _), .openFile(let path):
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        case .runScript(let script):
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", script]
                try? process.run()
            }
        }
    }

    private func bundleIdentifier(for event: CGEvent) -> String? {
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        if pid > 1,
           let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
            return bundleID
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func isTrackpadLike(_ event: CGEvent) -> Bool {
        if event.getDoubleValueField(.scrollWheelEventMomentumPhase) != 0 {
            return true
        }
        if event.getDoubleValueField(.scrollWheelEventScrollPhase) != 0 {
            return true
        }
        if event.getDoubleValueField(.scrollWheelEventScrollCount) != 0 {
            return true
        }
        return false
    }
}

private struct MouseTriggerEvent {
    let kind: MouseInputKind
    let code: UInt16
    let modifierFlags: UInt64
    let isDown: Bool
    let isMouseDown: Bool

    init?(type: CGEventType, event: CGEvent) {
        let normalizedFlags = ModifierFormatter.normalizedRawValue(from: event.flags)
        switch type {
        case .keyDown:
            kind = .keyboard
            code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            modifierFlags = normalizedFlags
            isDown = true
            isMouseDown = false
        case .keyUp:
            kind = .keyboard
            code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            modifierFlags = normalizedFlags
            isDown = false
            isMouseDown = false
        case .flagsChanged:
            kind = .keyboard
            code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            modifierFlags = normalizedFlags
            if let flag = MouseKeyCodes.modifierKeyToFlag[code] {
                isDown = event.flags.contains(flag)
            } else {
                isDown = normalizedFlags != 0
            }
            isMouseDown = false
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            kind = .mouse
            code = Self.mouseCode(type: type, event: event)
            modifierFlags = normalizedFlags
            isDown = true
            isMouseDown = true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            kind = .mouse
            code = Self.mouseCode(type: type, event: event)
            modifierFlags = normalizedFlags
            isDown = false
            isMouseDown = false
        default:
            return nil
        }
    }

    func matches(_ trigger: MouseInputTrigger) -> Bool {
        guard trigger.kind == kind else { return false }
        if let triggerFlag = MouseKeyCodes.modifierKeyToFlag[trigger.code],
           kind == .keyboard {
            guard let eventFlag = MouseKeyCodes.modifierKeyToFlag[code],
                  eventFlag == triggerFlag else {
                return false
            }
            return true
        }
        return trigger.code == code && trigger.modifierFlags == modifierFlags
    }

    private static func mouseCode(type: CGEventType, event: CGEvent) -> UInt16 {
        switch type {
        case .leftMouseDown, .leftMouseUp:
            return 0
        case .rightMouseDown, .rightMouseUp:
            return 1
        default:
            return UInt16(event.getIntegerValueField(.mouseEventButtonNumber))
        }
    }
}

private struct MouseAxisData {
    var fixedDelta: Int64 = 0
    var pointDelta = 0.0
    var fixedPointDelta = 0.0
    var isFixed = false
    var isValid = false
    var usableValue = 0.0
}

private struct MouseScrollEvent {
    let event: CGEvent
    var y: MouseAxisData
    var x: MouseAxisData

    init(event: CGEvent) {
        self.event = event
        y = Self.axisData(event: event, axis: .vertical)
        x = Self.axisData(event: event, axis: .horizontal)
    }

    mutating func reverseY() {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -y.fixedDelta)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -y.pointDelta)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -y.fixedPointDelta)
        y.usableValue = -y.usableValue
    }

    mutating func reverseX() {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -x.fixedDelta)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -x.pointDelta)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -x.fixedPointDelta)
        x.usableValue = -x.usableValue
    }

    mutating func normalizeY(minimum: Double) {
        y.usableValue = normalized(y.usableValue, minimum: minimum)
    }

    mutating func normalizeX(minimum: Double) {
        x.usableValue = normalized(x.usableValue, minimum: minimum)
    }

    func clearY() {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
    }

    func clearX() {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
    }

    private func normalized(_ value: Double, minimum: Double) -> Double {
        guard value != 0 else { return 0 }
        let magnitude = max(abs(value), minimum)
        return value > 0 ? magnitude : -magnitude
    }

    private enum Axis {
        case vertical
        case horizontal
    }

    private static func axisData(event: CGEvent, axis: Axis) -> MouseAxisData {
        var data = MouseAxisData()
        switch axis {
        case .vertical:
            data.fixedDelta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            data.pointDelta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            data.fixedPointDelta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        case .horizontal:
            data.fixedDelta = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            data.pointDelta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            data.fixedPointDelta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        }

        if data.pointDelta != 0 {
            data.isFixed = false
            data.isValid = true
            data.usableValue = data.pointDelta
        } else if data.fixedPointDelta != 0 {
            data.isFixed = true
            data.isValid = true
            data.usableValue = data.fixedPointDelta
        } else if data.fixedDelta != 0 {
            data.isFixed = true
            data.isValid = true
            data.usableValue = Double(data.fixedDelta)
        }
        return data
    }
}

// 滚动相位、滤波和投递策略按 Mos ScrollCore 的实现思路移植;
// Mos 使用 CC BY-NC 4.0 授权,本仓库 README 已记录授权边界。
private enum MouseScrollPhase {
    case idle
    case hold
    case trackingBegin
    case trackingOngoing
    case trackingEnd
    case momentumBegin
    case momentumOngoing
    case momentumEnd
    case leave
}

private enum MouseScrollPhaseItem {
    case scroll
    case momentum
}

private let mouseScrollPhaseValueMapping: [MouseScrollPhase: [MouseScrollPhaseItem: Double]] = [
    .idle: [.scroll: 0.0, .momentum: 0.0],
    .hold: [.scroll: 128.0, .momentum: 0.0],
    .trackingBegin: [.scroll: 1.0, .momentum: 0.0],
    .trackingOngoing: [.scroll: 2.0, .momentum: 0.0],
    .trackingEnd: [.scroll: 4.0, .momentum: 0.0],
    .momentumBegin: [.scroll: 0.0, .momentum: 1.0],
    .momentumOngoing: [.scroll: 0.0, .momentum: 2.0],
    .momentumEnd: [.scroll: 0.0, .momentum: 3.0],
    .leave: [.scroll: 8.0, .momentum: 0.0]
]

private final class MouseScrollPhaseState {
    struct TransitionPlan {
        let queue: [(MouseScrollPhase, MouseScrollPhase?)]
        let target: (MouseScrollPhase, MouseScrollPhase?)?
    }

    private(set) var phase: MouseScrollPhase = .idle
    private var pendingPhaseAfterDelivery: MouseScrollPhase?

    func reset() {
        phase = .idle
        pendingPhaseAfterDelivery = nil
    }

    func onManualInputDetected(isSeparated: Bool) -> TransitionPlan {
        if phase == .momentumBegin || phase == .momentumOngoing {
            if isSeparated {
                return plan(extra: [(.momentumEnd, .idle), (.trackingBegin, .trackingOngoing)])
            }
            return plan(
                extra: [(.momentumEnd, .idle)],
                target: (.trackingBegin, .trackingOngoing)
            )
        }
        if isSeparated {
            return plan(extra: [(.trackingBegin, .trackingOngoing)])
        }
        if phase == .trackingBegin || phase == .trackingOngoing {
            return plan(target: (.trackingOngoing, nil))
        }
        return plan(target: (.trackingBegin, .trackingOngoing))
    }

    func onManualInputEnded() -> TransitionPlan {
        switch phase {
        case .trackingBegin, .trackingOngoing:
            return plan(target: (.trackingEnd, nil))
        default:
            return plan()
        }
    }

    func onMomentumStart() -> TransitionPlan {
        switch phase {
        case .trackingEnd, .momentumEnd:
            return plan(target: (.momentumBegin, .momentumOngoing))
        case .momentumBegin:
            return plan(target: (.momentumOngoing, nil))
        default:
            return plan()
        }
    }

    func onMomentumOngoing() -> TransitionPlan {
        switch phase {
        case .momentumBegin:
            return plan(target: (.momentumOngoing, nil))
        default:
            return plan()
        }
    }

    func onMomentumFinish() -> TransitionPlan {
        switch phase {
        case .momentumBegin, .momentumOngoing:
            return plan(target: (.momentumEnd, .idle))
        case .trackingBegin, .trackingOngoing, .trackingEnd:
            return plan(target: (.trackingEnd, .idle))
        default:
            return plan()
        }
    }

    func didDeliverFrame() {
        if let nextPhase = pendingPhaseAfterDelivery {
            phase = nextPhase
            pendingPhaseAfterDelivery = nil
        }
    }

    func apply(phase next: MouseScrollPhase, autoAdvance: MouseScrollPhase? = nil) {
        phase = next
        pendingPhaseAfterDelivery = autoAdvance
    }

    private func plan(
        extra queue: [(MouseScrollPhase, MouseScrollPhase?)] = [],
        target: (MouseScrollPhase, MouseScrollPhase?)? = nil
    ) -> TransitionPlan {
        TransitionPlan(queue: queue, target: target)
    }
}

private final class MouseScrollFilter {
    private var curveWindowY = [0.0, 0.0]
    private var curveWindowX = [0.0, 0.0]

    func fill(with nextValue: (y: Double, x: Double)) -> (y: Double, x: Double) {
        curveWindowY = polish(curveWindowY, with: nextValue.y)
        curveWindowX = polish(curveWindowX, with: nextValue.x)
        return (y: curveWindowY[0], x: curveWindowX[0])
    }

    func reset() {
        curveWindowY = [0.0, 0.0]
        curveWindowX = [0.0, 0.0]
    }

    func resetY() {
        curveWindowY = [0.0, 0.0]
    }

    func resetX() {
        curveWindowX = [0.0, 0.0]
    }

    func primeY(with value: Double) {
        curveWindowY = [value, value]
    }

    func primeX(with value: Double) {
        curveWindowX = [value, value]
    }

    private func polish(_ values: [Double], with nextValue: Double) -> [Double] {
        let first = values[1]
        let diff = nextValue - first
        return [first, first + 0.23 * diff, first + 0.5 * diff, first + 0.77 * diff, nextValue]
    }
}

private final class MouseScrollDispatchContext: @unchecked Sendable {
    struct PostingSnapshot: @unchecked Sendable {
        let event: CGEvent
        let targetPID: pid_t
        let generation: UInt64
        let capturedAt: CFTimeInterval
        let debugID: UInt64
    }

    private struct SnapshotState {
        var eventTemplate: CGEvent?
        var targetPID: pid_t = 0
        var generation: UInt64 = 0
        var updatedAt: CFTimeInterval = 0
        var debugID: UInt64 = 0
    }

    private var state = SnapshotState()
    private var lock = os_unfair_lock_s()
    private let postQueue = DispatchQueue(label: "com.face.velto.mouse-scroll.post", qos: .userInteractive)
    private let eventTTL: CFTimeInterval = 5.0

    @discardableResult
    func capture(event: CGEvent, debugID: UInt64) -> Bool {
        guard let template = event.copy() else {
            MouseScrollDebugLogger.shared.log("#\(debugID) capture failed reason=event-copy")
            return false
        }
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        guard pid != 0 else {
            MouseScrollDebugLogger.shared.log("#\(debugID) capture failed reason=missing-target-pid")
            return false
        }
        os_unfair_lock_lock(&lock)
        state.eventTemplate = template
        state.targetPID = pid
        state.updatedAt = CFAbsoluteTimeGetCurrent()
        state.debugID = debugID
        let generation = state.generation
        os_unfair_lock_unlock(&lock)
        MouseScrollDebugLogger.shared.log("#\(debugID) capture ok pid=\(pid) generation=\(generation)")
        return true
    }

    func advanceGeneration() {
        os_unfair_lock_lock(&lock)
        state.generation &+= 1
        os_unfair_lock_unlock(&lock)
    }

    func clearContext() {
        os_unfair_lock_lock(&lock)
        state.eventTemplate = nil
        state.targetPID = 0
        state.updatedAt = 0
        state.debugID = 0
        os_unfair_lock_unlock(&lock)
    }

    func invalidateAll() {
        os_unfair_lock_lock(&lock)
        state.generation &+= 1
        state.eventTemplate = nil
        state.targetPID = 0
        state.updatedAt = 0
        state.debugID = 0
        os_unfair_lock_unlock(&lock)
    }

    func preparePostingSnapshot() -> PostingSnapshot? {
        os_unfair_lock_lock(&lock)
        guard state.targetPID != 0,
              let eventClone = state.eventTemplate?.copy() else {
            os_unfair_lock_unlock(&lock)
            MouseScrollDebugLogger.shared.log("prepare snapshot failed reason=missing-context")
            return nil
        }
        let snapshot = PostingSnapshot(
            event: eventClone,
            targetPID: state.targetPID,
            generation: state.generation,
            capturedAt: state.updatedAt,
            debugID: state.debugID
        )
        os_unfair_lock_unlock(&lock)
        return snapshot
    }

    func enqueue(_ snapshot: PostingSnapshot) {
        postQueue.async { [self] in
            os_unfair_lock_lock(&lock)
            let now = CFAbsoluteTimeGetCurrent()
            let stateGeneration = state.generation
            let validGeneration = snapshot.generation == state.generation
            let validTTL = now - snapshot.capturedAt <= eventTTL
            os_unfair_lock_unlock(&lock)
            let age = now - snapshot.capturedAt
            guard validGeneration && validTTL else {
                MouseScrollDebugLogger.shared.log("#\(snapshot.debugID) enqueue drop validGeneration=\(validGeneration) snapshotGeneration=\(snapshot.generation) stateGeneration=\(stateGeneration) validTTL=\(validTTL) age=\(mouseDebugNumber(age))")
                return
            }
            snapshot.event.postToPid(snapshot.targetPID)
            MouseScrollDebugLogger.shared.log("#\(snapshot.debugID) postToPid pid=\(snapshot.targetPID) generation=\(snapshot.generation) age=\(mouseDebugNumber(age))")
        }
    }
}

private final class MouseSmoothScrollAnimator: @unchecked Sendable {
    private let filter = MouseScrollFilter()
    private let phaseState = MouseScrollPhaseState()
    private let dispatchContext = MouseScrollDispatchContext()
    private var displayLink: CVDisplayLink?

    private var current = (y: 0.0, x: 0.0)
    private var delta = (y: 0.0, x: 0.0)
    private var buffer = (y: 0.0, x: 0.0)
    private var duration = MouseScrollProfile.defaults.transitionFactor
    private var simulateTrackpad = false
    private var lastManualEventTime: CFTimeInterval = 0
    private var manualInputEnded = true
    private var momentumActive = false
    private var momentumEndScheduledTime: CFTimeInterval?
    private var trackingEndScheduledTime: CFTimeInterval?
    private var activeDebugID: UInt64 = 0
    private var stateLock = os_unfair_lock_s()

    private let manualContinuationThreshold: CFTimeInterval = 0.18
    private let manualSeparationThreshold: CFTimeInterval = 0.45
    private let trackingEndAdvance: CFTimeInterval = 0.04
    private let momentumEndDelay: CFTimeInterval = 0.03
    private let deadZone = 1.0
    private let momentumTransitionFactor = 0.28
    private let momentumResidualStopThreshold = 8.0
    private let momentumOutputDeadZone = 3.0

    var isAvailable: Bool {
        displayLink != nil
    }

    init() {
        createDisplayLink()
    }

    deinit {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }

    @discardableResult
    func submit(
        event: CGEvent,
        debugID: UInt64,
        profile: MouseScrollProfile,
        y: Double,
        x: Double,
        speedMultiplier: Double
    ) -> Bool {
        guard dispatchContext.capture(event: event, debugID: debugID) else {
            return false
        }
        os_unfair_lock_lock(&stateLock)
        let oldCurrent = current
        let oldDelta = delta
        let oldBuffer = buffer
        let oldPhase = phaseState.phase
        let oldManualInputEnded = manualInputEnded
        let directionChangedY = y != 0 && oldDelta.y != 0 && y * oldDelta.y <= 0
        let directionChangedX = x != 0 && oldDelta.x != 0 && x * oldDelta.x <= 0
        let wasMomentumPhase = oldPhase == .momentumBegin || oldPhase == .momentumOngoing
        let momentumInterruptedY = y != 0 && oldManualInputEnded && wasMomentumPhase
        let momentumInterruptedX = x != 0 && oldManualInputEnded && wasMomentumPhase
        let shouldStartFreshY = directionChangedY || momentumInterruptedY
        let shouldStartFreshX = directionChangedX || momentumInterruptedX
        if shouldStartFreshY || shouldStartFreshX {
            dispatchContext.advanceGeneration()
            if shouldStartFreshY { filter.resetY() }
            if shouldStartFreshX { filter.resetX() }
        }
        duration = profile.transitionFactor
        simulateTrackpad = profile.simulateTrackpad

        let amplifiedY = y * profile.speedGain * speedMultiplier
        let amplifiedX = x * profile.speedGain * speedMultiplier
        if y * delta.y > 0 && !shouldStartFreshY {
            buffer.y += amplifiedY
        } else {
            buffer.y = amplifiedY
            current.y = 0
        }
        if x * delta.x > 0 && !shouldStartFreshX {
            buffer.x += amplifiedX
        } else {
            buffer.x = amplifiedX
            current.x = 0
        }
        delta = (y: y, x: x)
        activeDebugID = debugID

        let now = CFAbsoluteTimeGetCurrent()
        let interval = lastManualEventTime > 0 ? now - lastManualEventTime : nil
        let separatedByTime = interval == nil ? true : interval! >= manualSeparationThreshold
        let separatedPhase = (
            phaseState.phase == .idle
                || phaseState.phase == .leave
                || phaseState.phase == .momentumEnd
                || phaseState.phase == .trackingEnd
        )
        let separated = manualInputEnded || separatedByTime || separatedPhase
        let plan = phaseState.onManualInputDetected(isSeparated: separated)
        var immediateFrame = (y: 0.0, x: 0.0)
        if shouldStartFreshY {
            immediateFrame.y = (buffer.y - current.y) * duration
        }
        if shouldStartFreshX {
            immediateFrame.x = (buffer.x - current.x) * duration
        }
        let shouldEmitImmediateFrame = max(abs(immediateFrame.y), abs(immediateFrame.x)) > deadZone
        let combineTrackingBeginWithImmediateFrame = shouldEmitImmediateFrame
            && simulateTrackpad
            && oldManualInputEnded
            && wasMomentumPhase
        if combineTrackingBeginWithImmediateFrame {
            performMomentumInterruptWithoutTrackingBegin(plan)
        } else {
            perform(plan, emitTargetImmediately: false)
        }
        lastManualEventTime = now
        manualInputEnded = false
        momentumActive = false
        momentumEndScheduledTime = nil
        trackingEndScheduledTime = nil
        if shouldEmitImmediateFrame {
            if combineTrackingBeginWithImmediateFrame {
                phaseState.apply(phase: .trackingBegin, autoAdvance: .trackingOngoing)
            }
            current = (
                y: current.y + immediateFrame.y,
                x: current.x + immediateFrame.x
            )
            if shouldStartFreshY { filter.primeY(with: immediateFrame.y) }
            if shouldStartFreshX { filter.primeX(with: immediateFrame.x) }
            _ = post(immediateFrame)
        }
        MouseScrollDebugLogger.shared.log("#\(debugID) submit y=\(mouseDebugNumber(y)) x=\(mouseDebugNumber(x)) amplified=(\(mouseDebugPair((amplifiedY, amplifiedX)))) oldDelta=(\(mouseDebugPair(oldDelta))) newDelta=(\(mouseDebugPair(delta))) directionChangedY=\(directionChangedY) directionChangedX=\(directionChangedX) momentumInterruptedY=\(momentumInterruptedY) momentumInterruptedX=\(momentumInterruptedX) resetFilterY=\(shouldStartFreshY) resetFilterX=\(shouldStartFreshX) primedFilterY=\(shouldStartFreshY && shouldEmitImmediateFrame) primedFilterX=\(shouldStartFreshX && shouldEmitImmediateFrame) invalidatedQueuedFrames=\(shouldStartFreshY || shouldStartFreshX) immediateFrame=(\(mouseDebugPair(immediateFrame))) emittedImmediateFrame=\(shouldEmitImmediateFrame) combinedTrackingBegin=\(combineTrackingBeginWithImmediateFrame) oldBuffer=(\(mouseDebugPair(oldBuffer))) newBuffer=(\(mouseDebugPair(buffer))) oldCurrent=(\(mouseDebugPair(oldCurrent))) newCurrent=(\(mouseDebugPair(current))) duration=\(mouseDebugNumber(duration)) speedGain=\(mouseDebugNumber(profile.speedGain)) speedMultiplier=\(mouseDebugNumber(speedMultiplier)) interval=\(mouseDebugOptionalNumber(interval)) separatedByTime=\(separatedByTime) separatedPhase=\(separatedPhase) oldManualEnded=\(oldManualInputEnded) separated=\(separated) phase=\(oldPhase)->\(phaseState.phase) simulateTrackpad=\(simulateTrackpad)")
        os_unfair_lock_unlock(&stateLock)

        tryStart()
        return isAvailable
    }

    func stop(_ requestedPhase: MouseScrollPhase = .momentumEnd) {
        let wasRunning = displayLink.map { CVDisplayLinkIsRunning($0) } ?? false
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        dispatchContext.advanceGeneration()
        os_unfair_lock_lock(&stateLock)
        let debugID = activeDebugID
        let oldPhase = phaseState.phase

        let plan = requestedPhase == .momentumEnd
            ? phaseState.onMomentumFinish()
            : phaseState.onManualInputEnded()
        if simulateTrackpad {
            perform(plan, emitTargetImmediately: true)
        }
        manualInputEnded = true
        momentumActive = false
        resetUnlocked()
        MouseScrollDebugLogger.shared.log("#\(debugID) stop requested=\(requestedPhase) wasRunning=\(wasRunning) oldPhase=\(oldPhase) simulateTrackpad=\(simulateTrackpad)")
        os_unfair_lock_unlock(&stateLock)
    }

    func reset() {
        dispatchContext.invalidateAll()
        os_unfair_lock_lock(&stateLock)
        let debugID = activeDebugID
        resetUnlocked()
        MouseScrollDebugLogger.shared.log("#\(debugID) reset")
        os_unfair_lock_unlock(&stateLock)
    }

    private func createDisplayLink() {
        if let old = displayLink {
            CVDisplayLinkStop(old)
            displayLink = nil
        }
        var newDisplayLink: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&newDisplayLink)
        guard result == kCVReturnSuccess, let newDisplayLink else {
            NSLog("Velto mouse scroll: CVDisplayLink creation failed (%d)", result)
            MouseScrollDebugLogger.shared.log("#\(activeDebugID) displayLink create failed result=\(result)")
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(newDisplayLink, { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let animator = Unmanaged<MouseSmoothScrollAnimator>.fromOpaque(context).takeUnretainedValue()
            animator.processing()
            return kCVReturnSuccess
        }, context)
        displayLink = newDisplayLink
        MouseScrollDebugLogger.shared.log("#\(activeDebugID) displayLink created")
    }

    private func tryStart() {
        if displayLink == nil {
            createDisplayLink()
        }
        guard let displayLink, !CVDisplayLinkIsRunning(displayLink) else {
            MouseScrollDebugLogger.shared.log("#\(activeDebugID) displayLink start skipped available=\(displayLink != nil) running=\(displayLink.map { CVDisplayLinkIsRunning($0) } ?? false)")
            return
        }
        let result = CVDisplayLinkStart(displayLink)
        if result != kCVReturnSuccess {
            NSLog("Velto mouse scroll: CVDisplayLink start failed (%d)", result)
            MouseScrollDebugLogger.shared.log("#\(activeDebugID) displayLink start failed result=\(result)")
            createDisplayLink()
            if let recreatedDisplayLink = self.displayLink {
                _ = CVDisplayLinkStart(recreatedDisplayLink)
                MouseScrollDebugLogger.shared.log("#\(activeDebugID) displayLink restarted after recreate running=\(CVDisplayLinkIsRunning(recreatedDisplayLink))")
            }
        } else {
            MouseScrollDebugLogger.shared.log("#\(activeDebugID) displayLink started")
        }
    }

    private func resetUnlocked() {
        dispatchContext.clearContext()
        current = (y: 0, x: 0)
        delta = (y: 0, x: 0)
        buffer = (y: 0, x: 0)
        filter.reset()
        phaseState.reset()
        manualInputEnded = true
        momentumActive = false
        lastManualEventTime = 0
        momentumEndScheduledTime = nil
        trackingEndScheduledTime = nil
    }

    private func perform(
        _ plan: MouseScrollPhaseState.TransitionPlan,
        emitTargetImmediately: Bool,
        delta: (y: Double, x: Double) = (0, 0)
    ) {
        guard !plan.queue.isEmpty || plan.target != nil else {
            return
        }
        MouseScrollDebugLogger.shared.log("#\(activeDebugID) phase-plan phase=\(phaseState.phase) queue=\(String(describing: plan.queue)) target=\(String(describing: plan.target)) emitTargetImmediately=\(emitTargetImmediately) delta=(\(mouseDebugPair(delta)))")
        for item in plan.queue {
            emitPhase(item, delta: delta)
        }
        if let target = plan.target {
            if emitTargetImmediately {
                emitPhase(target, delta: delta)
            } else {
                phaseState.apply(phase: target.0, autoAdvance: target.1)
            }
        }
    }

    private func performMomentumInterruptWithoutTrackingBegin(
        _ plan: MouseScrollPhaseState.TransitionPlan
    ) {
        guard !plan.queue.isEmpty || plan.target != nil else {
            return
        }
        MouseScrollDebugLogger.shared.log("#\(activeDebugID) phase-plan-combined phase=\(phaseState.phase) queue=\(String(describing: plan.queue)) target=\(String(describing: plan.target))")
        for item in plan.queue where item.0 != .trackingBegin {
            emitPhase(item, delta: (0, 0))
        }
        if let target = plan.target, target.0 != .trackingBegin {
            phaseState.apply(phase: target.0, autoAdvance: target.1)
        }
    }

    private func emitPhase(_ item: (MouseScrollPhase, MouseScrollPhase?), delta: (y: Double, x: Double)) {
        phaseState.apply(phase: item.0, autoAdvance: item.1)
        guard let snapshot = dispatchContext.preparePostingSnapshot() else {
            MouseScrollDebugLogger.shared.log("#\(activeDebugID) emitPhase skipped phase=\(item.0) reason=missing-snapshot")
            phaseState.didDeliverFrame()
            return
        }
        let phaseOverride = simulateTrackpad ? phaseValues(for: item.0) : nil
        _ = post(snapshot, delta, phaseOverride: phaseOverride, fallbackToCurrentPhase: false)
    }

    private func processing() {
        var pendingStopPhase: MouseScrollPhase?
        os_unfair_lock_lock(&stateLock)
        let debugID = activeDebugID
        let phaseBefore = phaseState.phase
        var didEndManualInput = false
        var didStartMomentum = false
        var didContinueMomentum = false
        var didScheduleMomentumEnd = false

        let frameFactor = manualInputEnded ? max(duration, momentumTransitionFactor) : duration
        let frame = (
            y: (buffer.y - current.y) * frameFactor,
            x: (buffer.x - current.x) * frameFactor
        )
        current = (
            y: current.y + frame.y,
            x: current.x + frame.x
        )

        let filledValue = filter.fill(with: frame)
        let now = CFAbsoluteTimeGetCurrent()
        if !manualInputEnded,
           lastManualEventTime > 0,
           now - lastManualEventTime > manualContinuationThreshold {
            let endPlan = phaseState.onManualInputEnded()
            if !endPlan.queue.isEmpty || endPlan.target != nil {
                perform(endPlan, emitTargetImmediately: true)
            }
            manualInputEnded = true
            didEndManualInput = true
            if trackingEndScheduledTime == nil {
                trackingEndScheduledTime = now + trackingEndAdvance
            }
        }

        let residualY = buffer.y - current.y
        let residualX = buffer.x - current.x
        let residualMagnitude = max(residualY.magnitude, residualX.magnitude)
        let residualStopThreshold = manualInputEnded ? momentumResidualStopThreshold : deadZone
        if manualInputEnded && residualMagnitude > residualStopThreshold {
            if !momentumActive {
                perform(phaseState.onMomentumStart(), emitTargetImmediately: false)
                momentumActive = true
                didStartMomentum = true
            } else {
                perform(phaseState.onMomentumOngoing(), emitTargetImmediately: false)
                didContinueMomentum = true
            }
            momentumEndScheduledTime = nil
            trackingEndScheduledTime = nil
        } else if momentumActive && residualMagnitude <= residualStopThreshold {
            if momentumEndScheduledTime == nil {
                momentumEndScheduledTime = now + momentumEndDelay
                didScheduleMomentumEnd = true
            }
        } else {
            momentumEndScheduledTime = nil
            if momentumActive {
                momentumActive = false
            }
        }

        let outputMagnitude = max(abs(filledValue.y), abs(filledValue.x))
        let outputDeadZone = manualInputEnded ? momentumOutputDeadZone : deadZone
        if outputMagnitude > outputDeadZone {
            _ = post(filledValue)
        }

        if let scheduled = momentumEndScheduledTime, momentumActive, now >= scheduled {
            momentumEndScheduledTime = nil
            momentumActive = false
            pendingStopPhase = .momentumEnd
        }
        if pendingStopPhase == nil && manualInputEnded && !momentumActive && residualMagnitude <= residualStopThreshold {
            let pendingStop = trackingEndScheduledTime != nil && now >= trackingEndScheduledTime!
            let outputSettled = outputMagnitude <= outputDeadZone
            if pendingStop && outputSettled {
                trackingEndScheduledTime = nil
                pendingStopPhase = .trackingEnd
            }
        } else {
            trackingEndScheduledTime = nil
        }
        MouseScrollDebugLogger.shared.log("#\(debugID) frame phase=\(phaseBefore)->\(phaseState.phase) frame=(\(mouseDebugPair(frame))) frameFactor=\(mouseDebugNumber(frameFactor)) current=(\(mouseDebugPair(current))) buffer=(\(mouseDebugPair(buffer))) filled=(\(mouseDebugPair(filledValue))) residual=(y=\(mouseDebugNumber(residualY)) x=\(mouseDebugNumber(residualX)) mag=\(mouseDebugNumber(residualMagnitude))) residualStop=\(mouseDebugNumber(residualStopThreshold)) outputMag=\(mouseDebugNumber(outputMagnitude)) outputDeadZone=\(mouseDebugNumber(outputDeadZone)) manualEnded=\(manualInputEnded) endedManualThisFrame=\(didEndManualInput) momentumActive=\(momentumActive) startedMomentum=\(didStartMomentum) continuedMomentum=\(didContinueMomentum) scheduledMomentumEnd=\(didScheduleMomentumEnd) momentumEndIn=\(mouseDebugOptionalNumber(momentumEndScheduledTime.map { $0 - now })) trackingEndIn=\(mouseDebugOptionalNumber(trackingEndScheduledTime.map { $0 - now })) pendingStop=\(String(describing: pendingStopPhase))")
        os_unfair_lock_unlock(&stateLock)

        if let pendingStopPhase {
            stop(pendingStopPhase)
        }
    }

    private func phaseValues(for phase: MouseScrollPhase) -> (scroll: Double, momentum: Double)? {
        guard let scrollValue = mouseScrollPhaseValueMapping[phase]?[.scroll],
              let momentumValue = mouseScrollPhaseValueMapping[phase]?[.momentum] else {
            return nil
        }
        return (scroll: scrollValue, momentum: momentumValue)
    }

    @discardableResult
    private func post(
        _ snapshot: MouseScrollDispatchContext.PostingSnapshot,
        _ value: (y: Double, x: Double),
        phaseOverride: (scroll: Double, momentum: Double)? = nil,
        fallbackToCurrentPhase: Bool = true
    ) -> Bool {
        let phaseBefore = phaseState.phase
        if let phaseOverride {
            snapshot.event.setDoubleValueField(.scrollWheelEventScrollPhase, value: phaseOverride.scroll)
            snapshot.event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: phaseOverride.momentum)
        } else if fallbackToCurrentPhase,
                  simulateTrackpad,
                  let currentPhaseValues = phaseValues(for: phaseState.phase) {
            snapshot.event.setDoubleValueField(.scrollWheelEventScrollPhase, value: currentPhaseValues.scroll)
            snapshot.event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: currentPhaseValues.momentum)
        }

        snapshot.event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: value.y)
        snapshot.event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: value.x)
        snapshot.event.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1)
        snapshot.event.setIntegerValueField(.eventSourceUserData, value: MouseControlController.syntheticScrollMarker)
        dispatchContext.enqueue(snapshot)
        phaseState.didDeliverFrame()
        MouseScrollDebugLogger.shared.log("#\(snapshot.debugID) post enqueue value=(\(mouseDebugPair(value))) phaseBefore=\(phaseBefore) phaseAfter=\(phaseState.phase) phaseOverride=\(String(describing: phaseOverride)) fallback=\(fallbackToCurrentPhase) simulateTrackpad=\(simulateTrackpad) scrollPhase=\(mouseDebugNumber(snapshot.event.getDoubleValueField(.scrollWheelEventScrollPhase))) momentumPhase=\(mouseDebugNumber(snapshot.event.getDoubleValueField(.scrollWheelEventMomentumPhase))) targetPID=\(snapshot.targetPID)")
        return true
    }

    @discardableResult
    private func post(
        _ value: (y: Double, x: Double),
        phaseOverride: (scroll: Double, momentum: Double)? = nil,
        fallbackToCurrentPhase: Bool = true
    ) -> Bool {
        guard let snapshot = dispatchContext.preparePostingSnapshot() else {
            MouseScrollDebugLogger.shared.log("#\(activeDebugID) post skipped reason=missing-snapshot value=(\(mouseDebugPair(value)))")
            return false
        }
        return post(
            snapshot,
            value,
            phaseOverride: phaseOverride,
            fallbackToCurrentPhase: fallbackToCurrentPhase
        )
    }
}
