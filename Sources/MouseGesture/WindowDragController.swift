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
/// `@unchecked Sendable`:`handle*` 入口在 tap 线程上,后续 AX 写入在私有
/// `queue` 上串行化;modifier flags 通过 `lock` 保护。
final class WindowDragController: @unchecked Sendable {
    enum DragMode {
        case move
        case resize
    }

    /// Resize anchors at the window's top-left corner; the right and bottom
    /// edges follow cursor motion. This keeps cursor direction mapped 1:1 to
    /// size change (left = shrink width, right = grow width, etc.) even when
    /// the window is pinned against a screen edge — picking the "nearest edge"
    /// would get stuck the moment that edge hits the screen boundary.
    private struct DragSession {
        var mode: DragMode
        var window: AXUIElement
        var startPointer: CGPoint
        var startDragPointer: CGPoint
        var usesConvertedDragPointer: Bool
        var startFrame: CGRect
        var screenFrame: CGRect
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
            return GestureTargetController.setSize(nextFrame.size, ofWindow: session.window)
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
            screenFrame: screenFrame
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
        let origin = session.startFrame.origin
        var size = CGSize(
            width: max(minimumSize.width, session.startFrame.width + dx),
            height: max(minimumSize.height, session.startFrame.height + dy)
        )

        let screenFrame = session.screenFrame
        if !screenFrame.isEmpty {
            let maxWidth = screenFrame.maxX - origin.x
            if maxWidth > 0 {
                size.width = min(size.width, maxWidth)
            }
            let maxHeight = screenFrame.maxY - origin.y
            if maxHeight > 0 {
                size.height = min(size.height, maxHeight)
            }
        }

        size.width = max(size.width, minimumSize.width)
        size.height = max(size.height, minimumSize.height)
        return CGRect(origin: origin, size: size)
    }
}
