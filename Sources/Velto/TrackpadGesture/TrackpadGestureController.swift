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
        let target: GestureTargetController.TitleBarTarget
        var dx: Double
        var dy: Double
    }

    private struct WindowBox: @unchecked Sendable {
        let window: AXUIElement
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
        guard let target = GestureTargetController.titleBarTarget(
            at: point,
            titleBarHeight: titleBarActivationBandHeight
        ) else {
            session = nil
            TrackpadGestureDebugLog.log("began ignore outside-titlebar-band x=\(Int(point.x)) y=\(Int(point.y)) band=\(Int(titleBarActivationBandHeight))")
            return false
        }
        var next = Session(target: target, dx: 0, dy: 0)
        accumulate(into: &next, event: event)
        session = next
        TrackpadGestureDebugLog.log("began own x=\(Int(point.x)) y=\(Int(point.y)) band=\(Int(titleBarActivationBandHeight)) \(target.debugSummary)")
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

        TrackpadGestureDebugLog.log("ended dx=\(Int(session.dx)) dy=\(Int(session.dy)) action=\(action) \(session.target.debugSummary)")
        let box = WindowBox(window: session.target.window)
        DispatchQueue.global(qos: .userInteractive).async {
            switch action {
            case .maximize:
                GestureTargetController.maximizeWindow(box.window, containingEventLocation: point)
            case .minimize:
                _ = GestureTargetController.minimizeWindow(box.window)
            case .close:
                _ = GestureTargetController.closeWindow(box.window)
            }
        }
    }
}
