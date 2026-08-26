import Cocoa

/// 切换器的浮动面板。NSPanel 而不是 NSWindow,因为 NSPanel 支持
/// `.nonactivatingPanel`(显示时不抢前台进程的 keyboard focus,我们靠 CGEvent
/// tap 截键盘事件)。
///
/// 玻璃效果走 macOS 26 (Tahoe) 引入的公开 `NSGlassEffectView` —— 真正的
/// Liquid Glass,跟系统 Cmd+Tab / Dock 一个味。我们项目 deployment target
/// 就是 26,所以不做老系统降级。
final class SwitcherPanel: NSPanel {
    static let shared = SwitcherPanel()

    /// `NSGlassEffectView` 子类。Liquid Glass 视图本身既是背景容器、也是 tracking
    /// 事件源 —— 直接作为 contentView,中间不能再夹一层 NSView(会破坏玻璃渲染)。
    let glass: SwitcherGlassView
    let tilesView: SwitcherTilesView

    /// 跟 alt-tab Appearance.swift 里的 thumbnails-style + macOS 26 路径对齐:
    ///   - windowPadding 28
    ///   - windowCornerRadius 43(macOS 26 Liquid Glass 用更大的圆角)
    ///   - cellCornerRadius 18
    static let windowPadding: CGFloat = 25
    static let windowCornerRadius: CGFloat = 32
    static let cellCornerRadius: CGFloat = 18

    // 不做 fade-in / fade-out。alt-tab 也没做 —— 它的"丝滑"靠的就是即时响应,
    // 哪怕 0.14s 的 fade-in 都会被感受为"按下后等了一下"。
    // 出现动效走 micro-bounce:面板**第 0 帧就是全不透明的**(没有等待感),
    // 只是内容从 0.97 弹到 1.0。系统级面板(Spotlight / 通知中心)都是这个套路
    // —— 落位感来自缩放收敛,不是来自淡入。
    private static let appearScaleFrom: CGFloat = 0.97
    private static let appearDuration: CFTimeInterval = 0.09

    private init() {
        let initialFrame = NSRect(x: 0, y: 0, width: 600, height: 200)
        self.glass = SwitcherGlassView(frame: initialFrame)
        self.tilesView = SwitcherTilesView(frame: initialFrame)

        super.init(
            contentRect: initialFrame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        // panel 完全透明 —— Liquid Glass 自己提供深度感和阴影,我们不要 NSPanel
        // 额外的 shadow(否则会有双层阴影叠加,看着脏)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        isFloatingPanel = true
        animationBehavior = .none
        hidesOnDeactivate = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        setAccessibilitySubrole(.unknown)

        glass.cornerRadius = Self.windowCornerRadius
        glass.tilesViewRef = tilesView

        // tilesView 直接挂 glass 上
        tilesView.frame = glass.bounds
        tilesView.autoresizingMask = [.width, .height]
        glass.contentView = tilesView

        // 直接做 contentView
        self.contentView = glass
    }

    /// 重建 tiles + 计算尺寸 + 居中 + 立即显示。
    func show(
        with windows: [SwitcherWindow],
        style: SwitcherAppearanceStyle = .thumbnails,
        hideWindowTitle: Bool = false,
        on screen: NSScreen? = nil
    ) {
        // 先定面板屏幕,算可用区域(留点边距,别贴满屏),交给 tiles 决定列数与缩放。
        let panelScreen = screen ?? NSScreen.screenContainingMouse() ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = panelScreen.visibleFrame
        let maxSize = NSSize(width: visible.width * 0.94, height: visible.height * 0.94)
        let contentSize = tilesView.rebuild(
            with: windows,
            style: style,
            hideWindowTitle: hideWindowTitle,
            maxSize: maxSize
        )
        let frame = positionedFrame(for: contentSize, on: panelScreen)
        // 已经在屏上时只是换内容(session 中途重扫),不能再弹一次 —— 那会变成抽搐。
        let wasVisible = isVisible
        setFrame(frame, display: true)
        // 即时显示 —— 跟 alt-tab 一致。fade-in 会被感受为"按下后等了一下"。
        alphaValue = 1
        orderFrontRegardless()
        if !wasVisible { playAppearSettle() }
    }

    /// 出现时的落位动效:内容 0.97 → 1.0,90ms easeOut。见类顶部注释。
    private func playAppearSettle() {
        guard let layer = tilesView.layer else { return }
        // 绕**内容中心**缩放。NSView 背衬层的 anchorPoint 由 AppKit 说了算(不保证
        // 是中心),直接动 transform.scale 可能从某个角上长出来,所以自己补平移。
        let b = layer.bounds
        let dx = b.midX - (b.minX + layer.anchorPoint.x * b.width)
        let dy = b.midY - (b.minY + layer.anchorPoint.y * b.height)
        let s = Self.appearScaleFrom
        var from = CATransform3DMakeTranslation(dx, dy, 0)
        from = CATransform3DScale(from, s, s, 1)
        from = CATransform3DTranslate(from, -dx, -dy, 0)

        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = NSValue(caTransform3D: from)
        anim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        anim.duration = Self.appearDuration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "appearSettle")
    }

    func hidePanel() {
        // 即时隐藏 —— 用户松开 Cmd 那一刻 panel 就应该消失。fade-out 会让 panel
        // 在松手后继续可见 100ms,跟点击响应即时反馈的预期冲突。
        orderOut(nil)
        tilesView.clearHover()
    }

    private func positionedFrame(for contentSize: NSSize, on screen: NSScreen?) -> NSRect {
        let s = screen ?? NSScreen.screenContainingMouse() ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = s.visibleFrame
        let x = visible.midX - contentSize.width / 2
        let y = visible.midY - contentSize.height / 2
        return NSRect(origin: NSPoint(x: x, y: y), size: contentSize)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// NSGlassEffectView 子类:挂 trackingArea,鼠标离开整个 panel 时清掉 tile 的 hover。
/// macOS 26+ Only。
final class SwitcherGlassView: NSGlassEffectView {
    weak var tilesViewRef: SwitcherTilesView?
    private var rootTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // .regular 是普通玻璃(默认),.clear 是更透明的变体。.regular 跟系统
        // Dock / Cmd+Tab 一致。
        style = .regular
        wantsLayer = true
        // alt-tab 注释:不设 masksToBounds 会在四角出现奇怪的阴影残留
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("not implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let rootTrackingArea {
            removeTrackingArea(rootTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        rootTrackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        tilesViewRef?.clearHover()
    }
}

extension NSScreen {
    /// 鼠标所在的屏幕。
    ///
    /// 光标压在屏幕边界像素上、或落在高度不一致的双屏之间的"空档"里时,
    /// `frame.contains` 会全部失手返回 nil,调用方的 `?? NSScreen.main` 兜底
    /// 就把面板扔到「有 key window 的那块屏」—— 跟鼠标毫无关系。表现为
    /// 面板偶尔莫名其妙弹到另一个显示器上。改成退化到**最近**的屏幕。
    static func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return hit }
        return NSScreen.screens.min {
            squaredDistance(from: $0.frame, to: mouse) < squaredDistance(from: $1.frame, to: mouse)
        }
    }

    /// 点到矩形的最短距离平方(点在矩形内时为 0)。只用来比大小,不开根号。
    private static func squaredDistance(from rect: NSRect, to p: NSPoint) -> CGFloat {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
