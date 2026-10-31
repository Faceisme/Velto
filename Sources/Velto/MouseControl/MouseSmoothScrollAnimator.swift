import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import Synchronization

struct MouseAxisData {
    var fixedDelta: Int64 = 0
    var pointDelta = 0.0
    var fixedPointDelta = 0.0
    var isFixed = false
    var isValid = false
    var usableValue = 0.0
}

struct MouseScrollEvent {
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
enum MouseScrollPhase {
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

enum MouseScrollPhaseItem {
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

final class MouseScrollPhaseState {
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

final class MouseScrollFilter {
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

final class MouseSmoothScrollAnimator: NSObject, @unchecked Sendable {
    var eventPoster: (CGEvent, pid_t) -> Void = { $0.postToPid($1) }
    private let filter = MouseScrollFilter()
    private let phaseState = MouseScrollPhaseState()
    private var displayLink: CADisplayLink?

    /// 单一可变投递上下文:由物理滚动事件拷贝而来,后续每帧合成都复用同一个
    /// CGEvent、就地改写 delta/phase/marker 后投递,避免每帧 clone。仅滚动线程读写。
    private var templateEvent: CGEvent?
    private var targetPID: pid_t = 0
    // 每段动画绑定输入时的截图会话,会话切换后绝不复用旧惯性。
    private var captureSession: ScrollCaptureKeyTap?

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
        let session = ScrollCaptureKeyTap.current
        if captureSession !== session { resetState() }
        captureSession = session
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
        captureSession = nil
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

    func processing(dt: CFTimeInterval) {
        // 进入/退出截图、扩展选区或完成期间停止旧动画;截图内仍保留竖向平滑。
        if captureSession !== ScrollCaptureKeyTap.current || captureSession?.scrollInputEnabled == false {
            stop()
            return
        }
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
        // postToPid 绕过 HID tap:在这里复用同一输入锁,并通知捕获器每一帧的实际滚动。
        guard captureSession === ScrollCaptureKeyTap.current else { return false }
        if let captureSession, captureSession.handle(type: .scrollWheel, event: event) == nil {
            return false
        }
        eventPoster(event, targetPID)
        phaseState.didDeliverFrame()
        MouseScrollDebugLogger.shared.log("#\(activeDebugID) post value=(\(mouseDebugPair(value))) phaseBefore=\(phaseBefore) phaseAfter=\(phaseState.phase) phaseOverride=\(String(describing: phaseOverride)) fallback=\(fallbackToCurrentPhase) simulateTrackpad=\(simulateTrackpad) scrollPhase=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventScrollPhase))) momentumPhase=\(mouseDebugNumber(event.getDoubleValueField(.scrollWheelEventMomentumPhase))) targetPID=\(targetPID)")
        return true
    }
}
