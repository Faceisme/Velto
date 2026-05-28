import AppKit
import Foundation
import SwiftUI

/// 透明 NSView,负责录一次"按住右键拖动"的笔迹并把点列表抛回宿主。
/// 自己不画任何边框/背景 —— 装饰全交给外面的 `GesturePreviewCard`(背景、点
/// 阵网格、已存样本笔迹)。绘制中我们用 accent 色叠一条实时笔迹,松开右键
/// 时把点抛出去并清空。
///
/// **为什么是右键:** 左键被 SwiftUI 父链 / 系统拖动 / 文本选区 抢得很厉害,
/// 在卡片里按住左键经常被外面的滚动/点击吞掉。改成右键后这些都不冲突。
///
/// **右键事件的来路:** 整个 app 全局右键被 `EventTapManager` 的 CGEvent tap
/// 吃了去喂 GestureEngine。本视图在被挂上窗口时把自己的屏幕 rect 登记到
/// `RightClickPassThrough`,tap 看到光标在区域内时就直接放行,事件才能走到
/// 这里的 `rightMouseDown/Dragged/Up`。
final class GestureCaptureView: NSView {
    var onStrokeFinished: (([CGPoint]) -> Void)?

    private var points: [CGPoint] = [] {
        didSet { invalidateForPointChange(from: oldValue, to: points) }
    }

    private var frameObservers: [NSObjectProtocol] = []

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 完全透明 — 让 SwiftUI 层(GesturePreviewCard)负责所有装饰。
        layer?.backgroundColor = NSColor.clear.cgColor
        postsFrameChangedNotifications = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 不在 deinit 里清 observer:NSView 的 deinit 是 nonisolated,而 observer
    // 列表属于 main actor。清理交给 viewDidMoveToWindow(window: nil) 路径 ——
    // 视图从窗口摘下时,observer 才有意义需要解绑;此后视图本身被释放,闭包
    // 里的 [weak self] 也会变 nil,留下的 observer 触发也是 no-op。

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        points = [convert(event.locationInWindow, from: nil)]
    }

    override func rightMouseDragged(with event: NSEvent) {
        points.append(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseUp(with event: NSEvent) {
        points.append(convert(event.locationInWindow, from: nil))
        let finished = points
        points = []
        if finished.count >= 2 {
            onStrokeFinished?(finished)
        }
    }

    // MARK: - 右键透传区登记

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // 视图被摘下:清掉透传区,解绑 observer。
            unbindFrameObservers()
            RightClickPassThrough.setRegion(nil)
            return
        }
        rebindFrameObservers()
        republishPassThroughRegion()
    }

    private func unbindFrameObservers() {
        for o in frameObservers { NotificationCenter.default.removeObserver(o) }
        frameObservers = []
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        republishPassThroughRegion()
    }

    override func viewDidHide() {
        super.viewDidHide()
        RightClickPassThrough.setRegion(nil)
    }

    private func rebindFrameObservers() {
        unbindFrameObservers()

        let nc = NotificationCenter.default
        // 自身 frame 变化(SwiftUI 父布局重排都会触发)
        let viewObs = nc.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.republishPassThroughRegion() }
        }
        frameObservers.append(viewObs)

        guard let window else { return }
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.willCloseNotification,
        ] {
            let isClose = (name == NSWindow.willCloseNotification)
            let obs = nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if isClose {
                        RightClickPassThrough.setRegion(nil)
                    } else {
                        self?.republishPassThroughRegion()
                    }
                }
            }
            frameObservers.append(obs)
        }
    }

    private func republishPassThroughRegion() {
        guard let window, !isHidden, window.isVisible else {
            RightClickPassThrough.setRegion(nil)
            return
        }
        // 自身 bounds → window 坐标 → 屏幕(AppKit,左下原点)→ CGEvent(左上原点)
        let viewInWindow = convert(bounds, to: nil)
        let viewInScreen = window.convertToScreen(viewInWindow)
        let desktop = DisplayCoordinateConverter.desktopFrame()
        let cgRect = CGRect(
            x: viewInScreen.minX,
            y: desktop.maxY - viewInScreen.maxY,
            width: viewInScreen.width,
            height: viewInScreen.height
        )
        RightClickPassThrough.setRegion(cgRect)
    }

    private func invalidateForPointChange(from oldPoints: [CGPoint], to newPoints: [CGPoint]) {
        guard !oldPoints.isEmpty,
              !newPoints.isEmpty,
              newPoints.count >= oldPoints.count,
              let previous = oldPoints.last,
              let current = newPoints.last else {
            needsDisplay = true
            return
        }

        let dirtyRect = NSRect(
            x: min(previous.x, current.x),
            y: min(previous.y, current.y),
            width: abs(previous.x - current.x) + 1,
            height: abs(previous.y - current.y) + 1
        ).insetBy(dx: -10, dy: -10)
        setNeedsDisplay(dirtyRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard points.count >= 2 else { return }

        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }

        NSColor.systemBlue.setStroke()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}

// MARK: - SwiftUI bridge

struct GestureCaptureRepresentable: NSViewRepresentable {
    var onStrokeFinished: ([CGPoint]) -> Void

    func makeNSView(context: Context) -> GestureCaptureView { GestureCaptureView() }

    func updateNSView(_ view: GestureCaptureView, context: Context) {
        view.onStrokeFinished = onStrokeFinished
    }
}
