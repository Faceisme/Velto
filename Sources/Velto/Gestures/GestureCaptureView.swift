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

    /// 录制采样与运行时(`GestureEngine`)对齐:低于此位移的点不追加,滤手抖噪声。
    private let minimumPointDistance: CGFloat = 2
    /// 点数上限,防止长时间按住右键拖出超大模板写进配置;超限后只更新末点。
    private let maximumPointCount = 512

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
        appendSamplePoint(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseUp(with event: NSEvent) {
        appendSamplePoint(convert(event.locationInWindow, from: nil))
        let finished = points
        points = []
        // 用与识别一致的判据兜底:太短 / 无法归一化成签名的噪声笔迹直接丢弃,不写进
        // 模板(否则会产生空 / 不稳定的 canonical,污染列表、冲突检测与备份)。
        guard finished.count >= 2,
              !GestureDirection.signature(from: finished).isEmpty else { return }
        onStrokeFinished?(finished)
    }

    /// 追加采样点:滤掉低于 `minimumPointDistance` 的微动;超过 `maximumPointCount`
    /// 后不再增长,只更新末点。和运行时 `GestureEngine` 的采样规则保持一致。
    private func appendSamplePoint(_ point: CGPoint) {
        if let last = points.last, hypot(point.x - last.x, point.y - last.y) < minimumPointDistance {
            return
        }
        if points.count >= maximumPointCount {
            points[points.count - 1] = point
        } else {
            points.append(point)
        }
    }

    // MARK: - 右键透传区登记

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // 视图被摘下:清掉透传区,解绑 observer。
            unbindFrameObservers()
            RightClickPassThrough.clear(owner: ObjectIdentifier(self))
            return
        }
        rebindFrameObservers()
        republishPassThroughRegion()
        // 挂载瞬间 bounds / window 可能尚未就绪(首次 republish 的 guard 会失败),
        // 下一个 runloop 再补一次,确保布局完成后 region 一定被注册。
        DispatchQueue.main.async { [weak self] in
            self?.republishPassThroughRegion()
        }
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
        RightClickPassThrough.clear(owner: ObjectIdentifier(self))
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
        // 注意:不监听 willClose 来清除 region。SwiftUI 在测量/过渡时会把录制视图
        // 临时挂到不可见的辅助窗口,那些窗口的 willClose 会误清掉有效实例已注册的
        // region(owner 恰好匹配),而恢复 republish 又受 window.isVisible 限制、存在
        // 空窗期,用户恰在空窗期右键就"无法录制"。真正的窗口关闭由 viewDidMoveTo
        // Window(nil) 兜底清理,这里只监听位置/尺寸变化来刷新 region。
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
        ] {
            let obs = nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.republishPassThroughRegion()
                }
            }
            frameObservers.append(obs)
        }
    }

    private func republishPassThroughRegion() {
        // 暂态不可见(挂载瞬间 window 未就绪 / 布局动画里的一帧)不主动清除已注册
        // 区域 —— 真正的离场由 viewDidMoveToWindow(nil)/viewDidHide/willClose 负责
        // 清。否则窗口布局收敛期间偶发的不可见瞬间会把刚注册的 region 抹掉、又没有
        // 后续 frameDidChange 补注册,导致 region 永久为空、右键被 GestureEngine
        // 抢走而无法录制(就是"新建手势后偶尔录不进"的根因)。
        guard let window, !isHidden, window.isVisible else {
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
        RightClickPassThrough.setRegion(
            cgRect,
            windowNumber: window.windowNumber,
            owner: ObjectIdentifier(self)
        )
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
