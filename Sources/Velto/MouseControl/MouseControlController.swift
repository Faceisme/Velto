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

final class MouseControlController: @unchecked Sendable {
    static let syntheticScrollMarker: Int64 = 0x56454C544F534352
    /// iPhone 镜像:把鼠标滚轮重新合成成带 momentum 的连续事件,需绕过触控板跳过
    /// 才能翻转方向。
    private static let iPhoneMirroringBundleID = "com.apple.ScreenContinuity"

    /// 总开关闸门:每个滚动 / 触发事件最顶端无锁读一次,关功能时一条原子 load
    /// 就返回,跳过 bundle 解析、快照与按钮匹配等全部工作。写于主线程偏好观察者。
    private let enabledFlag = Atomic<Bool>(false)

    private let lock = NSLock()
    let animator = MouseSmoothScrollAnimator()

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

    func handleScrollWheel(event: CGEvent, captureLocked: Bool = false) -> Bool {
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
        let shouldShiftVertical = !captureLocked && state.directionToggle && hasY && !hasX
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
