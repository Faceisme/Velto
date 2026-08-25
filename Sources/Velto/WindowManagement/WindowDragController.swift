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

    private let queue = DispatchQueue(label: "com.face.velto.window-drag", qos: .userInteractive)
    private let lock = NSLock()

    /// `0` means "not configured". Read from the tap thread on every mouseMoved,
    /// so writes from the main-thread preferences observer go through `lock`.
    private var moveModifierFlags: UInt64 = 0
    private var resizeModifierFlags: UInt64 = 0

    private var session: DragSession?
    private var pendingUpdate: PendingUpdate?
    private var updateScheduled = false

    /// 目标定位失败后的冷却截止时间(window-drag 队列独占,无需加锁)。
    ///
    /// `beginDrag` 失败时 `session` 保持 nil,原先会让**每一个** mouseMoved 重跑
    /// 一整轮跨进程目标定位:CGWindowListCopyWindowInfo 全窗口枚举 + 最多两次
    /// systemwide `AXUIElementCopyElementAtPosition`。后者是同步 IPC,会逼指针
    /// 下的 App 在主线程上跑 AX 命中测试;120Hz 的鼠标移动就是每秒上百次。
    ///
    /// Telegram / 富途这类**不暴露 AX 窗口**的 App(实测 kAXWindows 返回 0 个)
    /// 定位必然失败,于是 100% 落进这条重试路径:Velto 这边 0.1s 超时就放弃,
    /// 目标进程那边照样得把请求排队处理完,积压只增不减,主线程再也腾不出手响应
    /// 点击 —— 表现就是"窗口像冻住了:选不中文字、交通灯没反应、切不动会话"。
    /// 失败后冷却一段时间再试,把重试频率从每秒上百次压到每秒两次。
    private var lookupBackoffUntil: CFAbsoluteTime = 0

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
            self?.lookupBackoffUntil = 0
        }
    }

    // MARK: - Lookup pre-warm

    private func prewarmDragLookup(mode: DragMode, at location: CGPoint) {
        queue.async { [weak self] in
            guard let self, self.lookupAllowed() else { return }
            if self.beginDrag(mode: mode, at: location) == nil {
                self.noteLookupFailure()
            }
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

    /// 冷却窗口:失败后 0.5s 内不再重跑目标定位。这段时间里指针下的窗口不会凭空
    /// 出现,重试纯属白烧目标进程的主线程。
    private static let lookupBackoff: TimeInterval = 0.5

    private func lookupAllowed() -> Bool {
        CFAbsoluteTimeGetCurrent() >= lookupBackoffUntil
    }

    private func noteLookupFailure() {
        lookupBackoffUntil = CFAbsoluteTimeGetCurrent() + Self.lookupBackoff
    }

    private func applyUpdate(mode: DragMode, at location: CGPoint) -> Bool {
        if session?.mode != mode {
            guard lookupAllowed() else { return false }
            session = beginDrag(mode: mode, at: location)
            if session == nil {
                noteLookupFailure()
                return false
            }
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
        let modeText = mode == .move ? "move" : "resize"
        guard let window = GestureTargetController.windowUnderPointer(at: location),
              let frame = GestureTargetController.frame(ofWindow: window) else {
            WindowManagementDebugLog.log(
                "beginDrag(\(modeText)) @ (\(Int(location.x)),\(Int(location.y))): 未拿到窗口/frame → 放弃")
            return nil
        }

        WindowManagementDebugLog.log(
            "beginDrag(\(modeText)) @ (\(Int(location.x)),\(Int(location.y))): 进入拖动会话,目标窗口 frame=[\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))],光标在窗口内=\(frame.contains(location))")

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
