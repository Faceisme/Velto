import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class TrackpadGestureController: @unchecked Sendable {
    enum Action: Equatable {
        case maximize
        case minimize
        case close
    }

    private struct Session {
        // began 时只拿几何 candidate(零 AX);真正的 AXUIElement 等手势确认后
        // 在后台队列解析 —— 见 fire(session:at:)。
        let candidate: GestureTargetController.TitleBarBandCandidate
        var dx: Double
        var dy: Double
    }

    private let lock = NSLock()
    private var enabled = false

    private var session: Session?
    private var swallowMomentum = false

    private let phaseBegan: Int64 = 1
    private let phaseChanged: Int64 = 2
    private let phaseEnded: Int64 = 4
    private let phaseCancelled: Int64 = 8
    private let activationThreshold: Double = 35
    private let titleBarActivationBandHeight: CGFloat = 72

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }

    func handleScrollWheel(event: CGEvent) -> Bool {
        guard isEnabled else {
            reset()
            return false
        }
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else { return false }

        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

        if phase == 0 {
            if momentum != 0 {
                return swallowMomentum
            }
            return session != nil
        }

        switch phase {
        case phaseBegan:
            return begin(event: event)
        case phaseChanged:
            return change(event: event)
        case phaseEnded:
            return end(event: event)
        case phaseCancelled:
            let owned = session != nil
            reset()
            swallowMomentum = owned
            return owned
        default:
            return session != nil
        }
    }

    static func classify(dx: Double, dy: Double, threshold: Double) -> Action? {
        guard max(abs(dx), abs(dy)) >= threshold else { return nil }
        if abs(dy) >= abs(dx) {
            return dy < 0 ? .maximize : .minimize
        }
        return dx < 0 ? .close : nil
    }

    private var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    private func begin(event: CGEvent) -> Bool {
        swallowMomentum = false
        let point = event.location
        // 本函数跑在滚动 tap 线程,与平滑滚动动画器同线程 —— 只做缓存几何
        // 命中,不碰 AX,否则卡死的目标 app 会冻结整条滚动链路(上界 1s/次)。
        guard let candidate = GestureTargetController.titleBarBandCandidate(
            at: point,
            bandHeight: titleBarActivationBandHeight
        ) else {
            session = nil
            TrackpadGestureDebugLog.log("began ignore outside-titlebar-band x=\(Int(point.x)) y=\(Int(point.y)) band=\(Int(titleBarActivationBandHeight))")
            return false
        }
        var next = Session(candidate: candidate, dx: 0, dy: 0)
        accumulate(into: &next, event: event)
        session = next
        TrackpadGestureDebugLog.log("began own x=\(Int(point.x)) y=\(Int(point.y)) band=\(Int(titleBarActivationBandHeight)) \(candidate.debugSummary)")
        return true
    }

    private func change(event: CGEvent) -> Bool {
        guard var current = session else { return false }
        accumulate(into: &current, event: event)
        session = current
        return true
    }

    private func end(event: CGEvent) -> Bool {
        guard let current = session else { return false }
        session = nil
        swallowMomentum = true
        fire(session: current, at: event.location)
        return true
    }

    private func reset() {
        session = nil
        swallowMomentum = false
    }

    private func accumulate(into session: inout Session, event: CGEvent) {
        session.dy += Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        session.dx += Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
    }

    private func fire(session: Session, at point: CGPoint) {
        guard let action = Self.classify(dx: session.dx, dy: session.dy, threshold: activationThreshold) else {
            TrackpadGestureDebugLog.log("ended ignored dx=\(Int(session.dx)) dy=\(Int(session.dy))")
            return
        }

        TrackpadGestureDebugLog.log("ended dx=\(Int(session.dx)) dy=\(Int(session.dy)) action=\(action) \(session.candidate.debugSummary)")
        let candidate = session.candidate
        DispatchQueue.global(qos: .userInteractive).async {
            // AX 解析放在这里:对卡死 app 最长 1s 超时,最坏只丢这次动作,
            // 不会反向冻结滚动线程。健康 app 的解析在几十 ms 内,体感无差。
            guard let target = GestureTargetController.resolveTitleBarTarget(from: candidate) else {
                TrackpadGestureDebugLog.log("fire abort resolve-failed \(candidate.debugSummary)")
                return
            }
            switch action {
            case .maximize:
                GestureTargetController.maximizeWindow(target.window, containingEventLocation: point)
            case .minimize:
                _ = GestureTargetController.minimizeWindow(target.window)
            case .close:
                _ = GestureTargetController.closeWindow(target.window)
            }
        }
    }
}
