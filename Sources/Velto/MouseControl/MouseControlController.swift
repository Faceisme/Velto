import AppKit
@preconcurrency import CoreFoundation
import CoreGraphics
import Foundation
import QuartzCore
import Synchronization

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
    /// `enabled` 的无锁镜像。生产态(日志关闭)下,每事件的 nextEventID/log 只做一次
    /// 原子 load 即返回,不再加锁。开启日志时才走 stateLock 路径。
    private let enabledFlag = Atomic<Bool>(false)
    private var enabled = false
    private var eventCounter: UInt64 = 0
    private var fileHandle: FileHandle?

    private init() {}

    deinit {
        try? fileHandle?.close()
    }

    func setEnabled(_ shouldEnable: Bool) {
        enabledFlag.store(shouldEnable, ordering: .relaxed)
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
        guard enabledFlag.load(ordering: .relaxed) else { return 0 }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard enabled else { return 0 }
        eventCounter &+= 1
        return eventCounter
    }

    func log(_ message: @autoclosure () -> String) {
        guard enabledFlag.load(ordering: .relaxed) else { return }
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
    /// iPhone 镜像:把鼠标滚轮重新合成成带 momentum 的连续事件,需绕过触控板跳过
    /// 才能翻转方向。
    private static let iPhoneMirroringBundleID = "com.apple.ScreenContinuity"

    /// 总开关闸门:每个滚动 / 触发事件最顶端无锁读一次,关功能时一条原子 load
    /// 就返回,跳过 bundle 解析、快照与按钮匹配等全部工作。写于主线程偏好观察者。
    private let enabledFlag = Atomic<Bool>(false)

    private let lock = NSLock()
    private let animator = MouseSmoothScrollAnimator()

    private var preferences = MouseControlPreferences.defaults
    /// bundleID → 规则的查找索引(由 `lock` 保护)。`snapshot(for:)` 每个滚动 /
    /// 触发事件都要查一次 per-app 规则,数组线性扫描会随规则数线性退化;偏好
    /// 变更时一次性重建字典,事件路径 O(1)。重复 bundleID 取首条,与原
    /// `first(where:)` 语义一致。
    private var appRuleIndex: [String: MouseAppRule] = [:]
    private var hotkeyState = MouseScrollHotkeyState()
    private var consumedTriggers = Set<MouseRuntimeTriggerKey>()

    /// pid → bundleID 单条 memo(由 `lock` 保护)。事件按 app 聚簇,命中即免去
    /// 每事件一次 `NSRunningApplication(processIdentifier:)` 查询;pid→bundle 稳定,
    /// 切换 app 自然刷新,pid 复用属极端情形,结果与逐次查询一致。
    private var cachedPID: pid_t = 0
    private var cachedBundleID: String?

    func updatePreferences(_ preferences: MouseControlPreferences) {
        MouseScrollDebugLogger.shared.setEnabled(preferences.debugLoggingEnabled)
        enabledFlag.store(preferences.enabled, ordering: .relaxed)
        lock.lock()
        self.preferences = preferences
        appRuleIndex = Dictionary(
            preferences.appRules.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        cachedPID = 0
        cachedBundleID = nil
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

    // MARK: - 滚动线程接入(由 EventTapManager 调用)

    /// 在主线程调用:`NSScreen` 访问需主线程。返回未加入 runloop 的 CADisplayLink。
    func makeScrollDisplayLink() -> CADisplayLink? {
        animator.makeDisplayLink()
    }

    /// 在滚动线程调用:把 displayLink 装入该线程 runloop,并记录线程身份。
    func attachScrollRunLoop(_ runLoop: CFRunLoop, thread: Thread, displayLink: CADisplayLink?) {
        animator.attach(runLoop: runLoop, thread: thread, displayLink: displayLink)
    }

    /// 在滚动线程调用(runloop 退出后):invalidate displayLink,打破引用环。
    func detachScrollRunLoop() {
        animator.detach()
    }

    func handleScrollWheel(event: CGEvent) -> Bool {
        guard enabledFlag.load(ordering: .relaxed) else { return false }
        let logger = MouseScrollDebugLogger.shared
        let debugID = logger.nextEventID()
        let marker = event.getIntegerValueField(.eventSourceUserData)
        let targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        logger.log("#\(debugID) input pid=\(targetPID) marker=\(marker) rawY(point=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))) fixedPt=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))) fixed=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))) rawX(point=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))) fixedPt=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))) fixed=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))) phase=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventScrollPhase))) momentum=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventMomentumPhase))) count=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventScrollCount)))")
        guard marker != Self.syntheticScrollMarker else {
            logger.log("#\(debugID) skip reason=synthetic-marker")
            return false
        }

        let bundleID = bundleIdentifier(for: event)
        let snapshot = snapshot(for: bundleID)
        guard snapshot.preferences.enabled else {
            logger.log("#\(debugID) skip reason=preferences-disabled bundle=\(bundleID ?? "-")")
            return false
        }

        // iPhone 镜像会把鼠标滚轮重新合成成带 momentum 的连续事件,通用触控板判定会把
        // 它整段(惯性部分)挡在翻转之前。对它放行:照常翻转,但不接管平滑(它自带
        // iOS 惯性,Velto 再合成平滑会打架)。其余 app 维持"触控板一律跳过"。
        let isContinuityMirror = bundleID == Self.iPhoneMirroringBundleID
        guard isContinuityMirror || !isTrackpadLike(event) else {
            logger.log("#\(debugID) skip reason=trackpad-like phase=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventScrollPhase))) momentum=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventMomentumPhase))) count=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventScrollCount)))")
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

        // iPhone 镜像读的是 CGEvent 底层的 IOHIDEvent 滚动量,无视我们对 delta 字段的
        // 就地修改 + 透传。必须重新投递一个合成事件(无原始 HID 背书)并吃掉原事件,
        // 它才会读我们给的(已翻转)值。1:1 重投,不走平滑(它自带 iOS 惯性)。
        if isContinuityMirror {
            if (hasY && reverseY) || (hasX && reverseX) {
                event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticScrollMarker)
                event.postToPid(targetPID)
                logger.log("#\(debugID) return consumed=true reason=mirror-repost reverseY=\(reverseY) reverseX=\(reverseX)")
                return true
            }
            logger.log("#\(debugID) return consumed=false reason=mirror-no-reverse")
            return false
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

    func handleTriggerEvent(type: CGEventType, event: CGEvent, normalizedFlags: UInt64) -> Bool {
        guard enabledFlag.load(ordering: .relaxed) else { return false }
        guard event.getIntegerValueField(.eventSourceUserData) != ShortcutSynthesizer.syntheticEventMarker,
              event.getIntegerValueField(.eventSourceUserData) != Self.syntheticScrollMarker else {
            return false
        }
        guard let triggerEvent = MouseTriggerEvent(type: type, event: event, normalizedFlags: normalizedFlags) else {
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
        guard let bundleID, let rule = appRuleIndex[bundleID] else {
            return (prefs, prefs.scroll, prefs.hotkeys, prefs.buttonBindings, hotkeyState)
        }
        let profile = rule.inheritScroll ? prefs.scroll : rule.scroll
        let hotkeys = rule.inheritHotkeys ? prefs.hotkeys : rule.hotkeys
        let bindings = rule.inheritButtons ? prefs.buttonBindings : rule.buttonBindings
        return (prefs, profile, hotkeys, bindings, hotkeyState)
    }

    private func updateHotkeyStateLocked(_ event: MouseTriggerEvent, hotkeys: MouseScrollHotkeys) {
        hotkeyState.acceleration = resolvedHotkey(
            hotkeys.acceleration, event: event, current: hotkeyState.acceleration)
        hotkeyState.directionToggle = resolvedHotkey(
            hotkeys.directionToggle, event: event, current: hotkeyState.directionToggle)
        hotkeyState.disableSmooth = resolvedHotkey(
            hotkeys.disableSmooth, event: event, current: hotkeyState.disableSmooth)
    }

    /// 纯修饰键触发器走"当前 flags 有没有按齐"的判定,其余仍按事件匹配 + isDown。
    private func resolvedHotkey(
        _ trigger: MouseInputTrigger?,
        event: MouseTriggerEvent,
        current: Bool
    ) -> Bool {
        guard let trigger else { return false }
        if let active = event.modifierTriggerActive(trigger) { return active }
        return event.matches(trigger) ? event.isDown : current
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
            let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                // 保留登录 shell(-l):GUI 经 LaunchServices 启动时环境极简,-l 才能
                // 带上用户 PATH(Homebrew 等),否则依赖 PATH 的脚本会失效。
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", script]
                do {
                    try process.run()
                } catch {
                    NSLog("Velto mouse control: runScript 启动失败 — %@", String(describing: error))
                }
            }
        }
    }

    private func bundleIdentifier(for event: CGEvent) -> String? {
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        if pid > 1 {
            lock.lock()
            let hit = pid == cachedPID ? cachedBundleID : nil
            lock.unlock()
            if let hit {
                return hit
            }
            if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
                lock.lock()
                cachedPID = pid
                cachedBundleID = bundleID
                lock.unlock()
                return bundleID
            }
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

struct MouseTriggerEvent {
    let kind: MouseInputKind
    let code: UInt16
    let modifierFlags: UInt64
    let isDown: Bool
    let isMouseDown: Bool

    init?(type: CGEventType, event: CGEvent, normalizedFlags: UInt64) {
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

    /// 纯修饰键触发器(含 ⌃⌥ 这类组合)的判定:不看事件 keycode,直接问"当前 flags
    /// 是否已经按齐了触发器要求的全部修饰键"。非修饰键触发器返回 nil,交回 `matches`。
    ///
    /// 按 keycode 匹配的老写法只在触发器那一颗键的 flagsChanged 上更新状态,组合键会
    /// 废掉:先按 ⌃ 再按 ⌥ 能亮,先按 ⌥ 再按 ⌃ 永远亮不了,松开 ⌃ 也不灭。修饰键每
    /// 按下/松开都会来一次 flagsChanged,每次重算,按下顺序和松开就都天然正确了。
    func modifierTriggerActive(_ trigger: MouseInputTrigger) -> Bool? {
        guard kind == .keyboard,
              let triggerFlag = MouseKeyCodes.modifierKeyToFlag[trigger.code] else {
            return nil
        }
        let required = UInt64(triggerFlag.rawValue) | trigger.modifierFlags
        return modifierFlags & required == required
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
    // 单 tap 指数平滑(alpha=0.23),输出较状态延迟一帧 —— 与原 5 元素 curveWindow
    // 实现逐位等价(原数组里索引 2/3/4 的中间值从不被读取),但每帧零堆分配。
    private var stateY = 0.0
    private var stateX = 0.0

    func fill(with nextValue: (y: Double, x: Double)) -> (y: Double, x: Double) {
        let output = (y: stateY, x: stateX)
        stateY += 0.23 * (nextValue.y - stateY)
        stateX += 0.23 * (nextValue.x - stateX)
        return output
    }

    func reset() {
        stateY = 0.0
        stateX = 0.0
    }

    func resetY() {
        stateY = 0.0
    }

    func resetX() {
        stateX = 0.0
    }

    func primeY(with value: Double) {
        stateY = value
    }

    func primeX(with value: Double) {
        stateX = value
    }
}

private final class MouseSmoothScrollAnimator: NSObject, @unchecked Sendable {
    private let filter = MouseScrollFilter()
    private let phaseState = MouseScrollPhaseState()
    private var displayLink: CADisplayLink?

    /// 单一可变投递上下文:由物理滚动事件拷贝而来,后续每帧合成都复用同一个
    /// CGEvent、就地改写 delta/phase/marker 后投递,避免每帧 clone。仅滚动线程读写。
    private var templateEvent: CGEvent?
    private var targetPID: pid_t = 0

    /// 动画器全部可变状态都 affine 到滚动线程(scroll tap 回调 + CADisplayLink
    /// 回调同在这条 runloop),因此无锁。跨线程进来的控制调用(鼠标按下叫停、
    /// 偏好变更)统一经 `onScrollThread` 投递到这条线程串行执行。
    private weak var scrollThread: Thread?
    private var scrollRunLoop: CFRunLoop?

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

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - 生命周期(NSScreen 在主线程取,runloop 安装在滚动线程)

    /// 主线程调用:`NSScreen` 访问需主线程。返回的 link 尚未加入任何 runloop。
    func makeDisplayLink() -> CADisplayLink? {
        guard let screen = NSScreen.main else {
            NSLog("Velto mouse scroll: NSScreen.main unavailable, CADisplayLink not created")
            MouseScrollDebugLogger.shared.log("displayLink create failed reason=no-screen")
            return nil
        }
        let link = screen.displayLink(target: self, selector: #selector(frameTick(_:)))
        link.isPaused = true
        return link
    }

    /// 滚动线程调用:把 displayLink 装入本线程 runloop,回调即在本线程触发。
    func attach(runLoop: CFRunLoop, thread: Thread, displayLink: CADisplayLink?) {
        scrollRunLoop = runLoop
        scrollThread = thread
        self.displayLink = displayLink
        displayLink?.add(to: RunLoop.current, forMode: .common)
        MouseScrollDebugLogger.shared.log("displayLink attached available=\(displayLink != nil)")
    }

    /// 滚动线程调用(runloop 退出后):invalidate 打破 CADisplayLink ↔ self 引用环,
    /// 并清空动画状态,保证"停止→再启动"从干净状态开始(teardown 时 marshaled 的
    /// stop 可能来不及执行)。
    func detach() {
        displayLink?.invalidate()
        displayLink = nil
        scrollRunLoop = nil
        scrollThread = nil
        resetState()
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        // targetTimestamp - timestamp 是本帧应跨越的真实时长(一个刷新周期),
        // 用它把每帧推进量换算成帧率无关。
        processing(dt: link.targetTimestamp - link.timestamp)
    }

    /// 把控制调用投递到滚动线程串行执行;已在该线程则直接执行。
    private func onScrollThread(_ work: @escaping () -> Void) {
        if Thread.current === scrollThread {
            work()
        } else if let runLoop = scrollRunLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
            CFRunLoopWakeUp(runLoop)
        } else {
            work()
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
        guard let template = event.copy() else {
            MouseScrollDebugLogger.shared.log("#\(debugID) capture failed reason=event-copy")
            return false
        }
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        guard pid != 0 else {
            MouseScrollDebugLogger.shared.log("#\(debugID) capture failed reason=missing-target-pid")
            return false
        }
        templateEvent = template
        targetPID = pid

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

        tryStart()
        return isAvailable
    }

    func stop(_ requestedPhase: MouseScrollPhase = .momentumEnd) {
        onScrollThread { [self] in
            let wasRunning = !(displayLink?.isPaused ?? true)
            displayLink?.isPaused = true
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
            resetState()
            MouseScrollDebugLogger.shared.log("#\(debugID) stop requested=\(requestedPhase) wasRunning=\(wasRunning) oldPhase=\(oldPhase) simulateTrackpad=\(simulateTrackpad)")
        }
    }

    func reset() {
        onScrollThread { [self] in
            let debugID = activeDebugID
            resetState()
            MouseScrollDebugLogger.shared.log("#\(debugID) reset")
        }
    }

    /// 滚动线程调用:CADisplayLink 已在 attach 时装好,这里只需取消暂停。
    private func tryStart() {
        guard let displayLink else {
            MouseScrollDebugLogger.shared.log("#\(activeDebugID) displayLink start skipped reason=unavailable")
            return
        }
        if displayLink.isPaused {
            displayLink.isPaused = false
            MouseScrollDebugLogger.shared.log("#\(activeDebugID) displayLink started")
        }
    }

    private func resetState() {
        templateEvent = nil
        targetPID = 0
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
        guard templateEvent != nil, targetPID != 0 else {
            MouseScrollDebugLogger.shared.log("#\(activeDebugID) emitPhase skipped phase=\(item.0) reason=missing-context")
            phaseState.didDeliverFrame()
            return
        }
        let phaseOverride = simulateTrackpad ? phaseValues(for: item.0) : nil
        _ = post(delta, phaseOverride: phaseOverride, fallbackToCurrentPhase: false)
    }

    /// 原 frameFactor 常数(minStep/speedGain/duration)是在 120Hz 开发机上调出来的,
    /// 所以锚点取 120:在 120Hz 屏上 frameFactor 精确等于 refAlpha,完全还原原手感;
    /// 同时仍是帧率无关 —— 60Hz 外接屏会自动匹配这套 120Hz 调好的手感,而非变半速。
    private static let referenceFrameRate = 120.0

    /// 把"按参考刷新率调出来的每帧追赶系数"换算到任意帧间隔 dt:先反推时间常数 tau
    /// (alpha = 1 - exp(-Δt_ref/tau)),再用真实 dt 求 1 - exp(-dt/tau)。
    /// 这样不同刷新率下单位时间的收敛速度一致,而非每帧固定比例。
    private static func frameRateAdjustedAlpha(_ referenceAlpha: Double, dt: CFTimeInterval) -> Double {
        guard referenceAlpha > 0, referenceAlpha < 1, dt > 0 else { return referenceAlpha }
        let referenceInterval = 1.0 / referenceFrameRate
        let tau = -referenceInterval / log(1 - referenceAlpha)
        return 1 - exp(-dt / tau)
    }

    private func processing(dt: CFTimeInterval) {
        var pendingStopPhase: MouseScrollPhase?
        let debugID = activeDebugID
        let phaseBefore = phaseState.phase
        var didEndManualInput = false
        var didStartMomentum = false
        var didContinueMomentum = false
        var didScheduleMomentumEnd = false

        // referenceAlpha 是按 60Hz 调出来的每帧追赶系数,换成真实 dt 重算 → 帧率无关:
        // 60Hz 上与原来逐帧等价,120Hz 上不再快一倍。
        let referenceAlpha = manualInputEnded ? max(duration, momentumTransitionFactor) : duration
        let frameFactor = Self.frameRateAdjustedAlpha(referenceAlpha, dt: dt)
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
        MouseScrollDebugLogger.shared.log("#\(debugID) frame phase=\(phaseBefore)->\(phaseState.phase) frame=(\(mouseDebugPair(frame))) dt=\(mouseDebugNumber(dt)) refAlpha=\(mouseDebugNumber(referenceAlpha)) frameFactor=\(mouseDebugNumber(frameFactor)) current=(\(mouseDebugPair(current))) buffer=(\(mouseDebugPair(buffer))) filled=(\(mouseDebugPair(filledValue))) residual=(y=\(mouseDebugNumber(residualY)) x=\(mouseDebugNumber(residualX)) mag=\(mouseDebugNumber(residualMagnitude))) residualStop=\(mouseDebugNumber(residualStopThreshold)) outputMag=\(mouseDebugNumber(outputMagnitude)) outputDeadZone=\(mouseDebugNumber(outputDeadZone)) manualEnded=\(manualInputEnded) endedManualThisFrame=\(didEndManualInput) momentumActive=\(momentumActive) startedMomentum=\(didStartMomentum) continuedMomentum=\(didContinueMomentum) scheduledMomentumEnd=\(didScheduleMomentumEnd) momentumEndIn=\(mouseDebugOptionalNumber(momentumEndScheduledTime.map { $0 - now })) trackingEndIn=\(mouseDebugOptionalNumber(trackingEndScheduledTime.map { $0 - now })) pendingStop=\(String(describing: pendingStopPhase))")

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

    /// 复用单一 templateEvent:就地改写 delta/phase/marker 后直接 postToPid。
    /// 全程在滚动线程同步执行,投递顺序确定,无 clone、无队列跳转。
    @discardableResult
    private func post(
        _ value: (y: Double, x: Double),
        phaseOverride: (scroll: Double, momentum: Double)? = nil,
        fallbackToCurrentPhase: Bool = true
    ) -> Bool {
        guard let event = templateEvent, targetPID != 0 else {
            MouseScrollDebugLogger.shared.log("#\(activeDebugID) post skipped reason=missing-context value=(\(mouseDebugPair(value)))")
            return false
        }
        let phaseBefore = phaseState.phase
        if let phaseOverride {
            event.setDoubleValueField(.scrollWheelEventScrollPhase, value: phaseOverride.scroll)
            event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: phaseOverride.momentum)
        } else if fallbackToCurrentPhase,
                  simulateTrackpad,
                  let currentPhaseValues = phaseValues(for: phaseState.phase) {
            event.setDoubleValueField(.scrollWheelEventScrollPhase, value: currentPhaseValues.scroll)
            event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: currentPhaseValues.momentum)
        }

        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: value.y)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: value.x)
        event.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: MouseControlController.syntheticScrollMarker)
        event.postToPid(targetPID)
        phaseState.didDeliverFrame()
        MouseScrollDebugLogger.shared.log("#\(activeDebugID) post value=(\(mouseDebugPair(value))) phaseBefore=\(phaseBefore) phaseAfter=\(phaseState.phase) phaseOverride=\(String(describing: phaseOverride)) fallback=\(fallbackToCurrentPhase) simulateTrackpad=\(simulateTrackpad) scrollPhase=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventScrollPhase))) momentumPhase=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventMomentumPhase))) targetPID=\(targetPID)")
        return true
    }
}
