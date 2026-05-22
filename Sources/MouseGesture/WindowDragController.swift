import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Modifier+drag window management: holding the move/resize modifier and
/// dragging the mouse moves or resizes the window under the pointer.
///
/// All inbound `handle*` methods run on the event-tap thread. Actual AX writes
/// happen on a dedicated serial queue with coalescing so we never block the
/// tap callback waiting on a window server round trip.
final class WindowDragController {
    enum DragMode {
        case move
        case resize
    }

    private enum ResizeEdge {
        case min
        case max
    }

    private struct DragSession {
        var mode: DragMode
        var window: AXUIElement
        var startPointer: CGPoint
        var startDragPointer: CGPoint
        var usesConvertedDragPointer: Bool
        var startFrame: CGRect
        var screenFrame: CGRect
        var horizontalEdge: ResizeEdge
        var verticalEdge: ResizeEdge
    }

    private struct PendingUpdate {
        var mode: DragMode
        var location: CGPoint
    }

    private let queue = DispatchQueue(label: "com.face.mygestures.window-drag", qos: .userInteractive)
    private let lock = NSLock()

    /// `0` means "not configured". Read from the tap thread on every mouseMoved,
    /// so writes from the main-thread preferences observer go through `lock`.
    private var moveModifierFlags: UInt64 = 0
    private var resizeModifierFlags: UInt64 = 0

    private var session: DragSession?
    private var pendingUpdate: PendingUpdate?
    private var updateScheduled = false

    // MARK: - Preference snapshot

    func updateModifierFlags(move: UInt64, resize: UInt64) {
        lock.lock()
        moveModifierFlags = move
        resizeModifierFlags = resize
        lock.unlock()
    }

    /// Read by the tap thread on every mouseMoved. Atomic-ish via short lock.
    func dragMode(forNormalizedFlags raw: UInt64) -> DragMode? {
        lock.lock()
        let resize = resizeModifierFlags
        let move = moveModifierFlags
        lock.unlock()

        if resize != 0, raw == resize { return .resize }
        if move != 0, raw == move { return .move }
        return nil
    }

    // MARK: - Event handlers (tap thread)

    func handleFlagsChanged(event: CGEvent, normalizedFlags raw: UInt64) {
        if let mode = dragMode(forNormalizedFlags: raw) {
            prewarmDragLookup(mode: mode, at: event.location)
        } else {
            resetSession()
        }
    }

    func handleMouseMoved(at location: CGPoint, mode: DragMode) {
        enqueueUpdate(mode: mode, at: location)
    }

    func resetSession() {
        lock.lock()
        pendingUpdate = nil
        updateScheduled = false
        lock.unlock()

        queue.async { [weak self] in
            self?.session = nil
        }
    }

    // MARK: - Lookup pre-warm

    private func prewarmDragLookup(mode: DragMode, at location: CGPoint) {
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.beginDrag(mode: mode, at: location)
        }
    }

    private func enqueueUpdate(mode: DragMode, at location: CGPoint) {
        lock.lock()
        pendingUpdate = PendingUpdate(mode: mode, location: location)
        let shouldSchedule = !updateScheduled
        if shouldSchedule { updateScheduled = true }
        lock.unlock()

        guard shouldSchedule else { return }
        queue.async { [weak self] in
            self?.flushUpdates()
        }
    }

    private func flushUpdates() {
        lock.lock()
        guard let update = pendingUpdate else {
            updateScheduled = false
            lock.unlock()
            return
        }
        pendingUpdate = nil
        lock.unlock()

        _ = applyUpdate(mode: update.mode, at: update.location)

        lock.lock()
        let more = pendingUpdate != nil
        if !more { updateScheduled = false }
        lock.unlock()

        if more {
            queue.async { [weak self] in
                self?.flushUpdates()
            }
        }
    }

    // MARK: - Drag math (window-drag queue only)

    private func applyUpdate(mode: DragMode, at location: CGPoint) -> Bool {
        if session?.mode != mode {
            session = beginDrag(mode: mode, at: location)
        }

        guard let session else { return false }

        let currentPointer = dragPoint(from: location, usesConvertedPointer: session.usesConvertedDragPointer)
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

    private func beginDrag(mode: DragMode, at location: CGPoint) -> DragSession? {
        guard let window = GestureTargetController.windowUnderPointer(at: location),
              let frame = GestureTargetController.frame(ofWindow: window) else {
            return nil
        }

        let dragPoint = initialDragPoint(for: location, in: frame)
        let screenFrame = DisplayCoordinateConverter.visibleAccessibilityFrame(containingEventLocation: location)

        return DragSession(
            mode: mode,
            window: window,
            startPointer: location,
            startDragPointer: dragPoint.point,
            usesConvertedDragPointer: dragPoint.usesConvertedPointer,
            startFrame: frame,
            screenFrame: screenFrame,
            horizontalEdge: dragPoint.point.x < frame.midX ? .min : .max,
            verticalEdge: dragPoint.point.y < frame.midY ? .min : .max
        )
    }

    private func initialDragPoint(
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
        return rawDistance <= convertedDistance ? (location, false) : (convertedPoint, true)
    }

    private func dragPoint(from location: CGPoint, usesConvertedPointer: Bool) -> CGPoint {
        usesConvertedPointer
            ? DisplayCoordinateConverter.eventLocationToAccessibilityPoint(location)
            : location
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        return hypot(point.x - clampedX, point.y - clampedY)
    }

    private func resizedFrame(from session: DragSession, dx: CGFloat, dy: CGFloat) -> CGRect {
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
        guard !screenFrame.isEmpty else { return result }

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
}
