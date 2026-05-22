import CoreGraphics
import Foundation
import QuartzCore

/// Modifier + scroll-wheel → ⌘= / ⌘- key synthesis. Accumulates raw scroll
/// deltas, throttles dispatch, and reverses direction promptly when the user
/// flips scroll direction.
///
/// All `handle*` entry points run on the event-tap thread; dispatch happens on
/// a global QoS-userInteractive queue so we never block the tap callback.
final class ContentZoomController {
    private let lock = NSLock()
    private var zoomModifierFlags: UInt64 = 0

    // Following state is touched only from `queue`.
    private let queue = DispatchQueue(label: "com.face.mygestures.content-zoom", qos: .userInteractive)
    private var accumulator: Double = 0
    private var stepScheduled = false
    private var lastDispatchTime: CFTimeInterval = 0
    private var generation = 0

    private let stepThreshold: Double = 1
    private let maxBufferedSteps: Double = 4
    private let minimumStepInterval: TimeInterval = 0.055

    // MARK: - Preference snapshot

    func updateModifierFlag(_ flag: UInt64) {
        let needsReset: Bool
        lock.lock()
        needsReset = zoomModifierFlags != flag
        zoomModifierFlags = flag
        lock.unlock()

        if needsReset {
            resetSmoothing()
        }
    }

    /// Fast lock-guarded check used by the tap callback short-circuit.
    func modifierMatches(rawValue: UInt64) -> Bool {
        lock.lock()
        let flag = zoomModifierFlags
        lock.unlock()
        return flag != 0 && rawValue == flag
    }

    // MARK: - Tap-thread entry points

    func handleScrollWheel(event: CGEvent, normalizedFlags raw: UInt64) -> Bool {
        guard modifierMatches(rawValue: raw) else {
            return false
        }

        let deltaY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        if deltaY == 0 {
            // Swallow; user is holding the zoom modifier but the wheel produced
            // no usable delta this frame.
            return true
        }

        enqueue(delta: Double(deltaY))
        return true
    }

    func handleFlagsChanged(normalizedFlags raw: UInt64) {
        if !modifierMatches(rawValue: raw) {
            resetSmoothing()
        }
    }

    // MARK: - Smoothing pipeline

    private func enqueue(delta: Double) {
        queue.async { [weak self] in
            self?.append(delta: delta)
        }
    }

    private func append(delta: Double) {
        if accumulator != 0, (delta > 0) != (accumulator > 0) {
            accumulator = 0
        }
        accumulator += delta
        accumulator = min(max(accumulator, -maxBufferedSteps), maxBufferedSteps)
        scheduleStep()
    }

    private func scheduleStep(after delay: TimeInterval = 0) {
        guard !stepScheduled else { return }
        stepScheduled = true
        let captured = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flushStep(generation: captured)
        }
    }

    private func flushStep(generation: Int) {
        guard generation == self.generation else { return }
        stepScheduled = false

        guard abs(accumulator) >= stepThreshold else { return }

        let now = CACurrentMediaTime()
        let remaining = minimumStepInterval - (now - lastDispatchTime)
        if remaining > 0 {
            scheduleStep(after: remaining)
            return
        }

        let direction = accumulator > 0 ? 1.0 : -1.0
        accumulator -= direction * stepThreshold
        lastDispatchTime = CACurrentMediaTime()
        sendStep(zoomIn: direction > 0)

        if abs(accumulator) >= stepThreshold {
            scheduleStep(after: minimumStepInterval)
        }
    }

    private func resetSmoothing() {
        queue.async { [weak self] in
            guard let self else { return }
            self.accumulator = 0
            self.stepScheduled = false
            self.generation &+= 1
        }
    }

    private func sendStep(zoomIn: Bool) {
        let keyCode = zoomIn ? VirtualKeyCode.equal : VirtualKeyCode.minus
        DispatchQueue.global(qos: .userInteractive).async {
            ShortcutSynthesizer.sendKey(
                keyCode: keyCode,
                modifierFlags: CGEventFlags.maskCommand.storedRawValue
            )
        }
    }
}
