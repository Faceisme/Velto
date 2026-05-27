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

    // 不做 fade-in / fade-out 动画。alt-tab 也没做 —— 它的"丝滑"靠的就是
    // 即时响应。哪怕 0.14s 的 fade-in 都会被感受为"按下后等了一下"。
    // 如果未来想做"出现 / 消失"动效,做 micro-bounce(50ms 缩放)比 fade
    // 更不影响响应感。

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
        on screen: NSScreen? = nil
    ) {
        let contentSize = tilesView.rebuild(with: windows, style: style)
        let frame = positionedFrame(for: contentSize, on: screen)
        setFrame(frame, display: true)
        // 即时显示 —— 跟 alt-tab 一致。fade-in 会被感受为"按下后等了一下"。
        alphaValue = 1
        orderFrontRegardless()
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
    static func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
    }
}
