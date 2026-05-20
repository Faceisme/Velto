import AppKit
import Foundation
import QuartzCore

final class GestureOverlayController {
    private var window: NSWindow?
    private let drawingView = GestureOverlayView()
    private let renderLock = NSLock()
    private let minimumRenderInterval: CFTimeInterval = 1.0 / 120.0

    private var pendingPoints: [CGPoint]?
    private var hasPendingRender = false
    private var renderGeneration = 0
    private var lastRenderTime: CFTimeInterval = 0

    func show(points: [CGPoint]) {
        let generation = resetPendingRender()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentGeneration(generation) else { return }
            self.ensureWindow()
            self.drawingView.points = points
            self.lastRenderTime = CACurrentMediaTime()
            self.window?.orderFrontRegardless()
        }
    }

    func update(points: [CGPoint]) {
        guard let generation = enqueueRender(points: points) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.schedulePendingRender(generation: generation)
        }
    }

    func hide() {
        let generation = resetPendingRender()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentGeneration(generation) else { return }
            self.drawingView.points = []
            self.window?.orderOut(nil)
        }
    }

    private func ensureWindow() {
        let frame = DisplayCoordinateConverter.desktopFrame()

        if let window {
            if window.frame != frame {
                window.setFrame(frame, display: false)
            }
            return
        }

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = drawingView
        window.hasShadow = false

        self.window = window
    }

    private func enqueueRender(points: [CGPoint]) -> Int? {
        renderLock.lock()
        defer { renderLock.unlock() }

        pendingPoints = points
        guard !hasPendingRender else {
            return nil
        }

        hasPendingRender = true
        return renderGeneration
    }

    private func resetPendingRender() -> Int {
        renderLock.lock()
        defer { renderLock.unlock() }

        renderGeneration += 1
        pendingPoints = nil
        hasPendingRender = false
        return renderGeneration
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        renderLock.lock()
        defer { renderLock.unlock() }

        return renderGeneration == generation
    }

    private func schedulePendingRender(generation: Int) {
        guard isCurrentGeneration(generation) else {
            return
        }

        let now = CACurrentMediaTime()
        let delay = max(0, minimumRenderInterval - (now - lastRenderTime))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flushPendingRender(generation: generation)
        }
    }

    private func flushPendingRender(generation: Int) {
        guard let points = consumePendingPoints(generation: generation) else {
            return
        }

        ensureWindow()
        drawingView.points = points
        lastRenderTime = CACurrentMediaTime()
    }

    private func consumePendingPoints(generation: Int) -> [CGPoint]? {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard renderGeneration == generation else {
            return nil
        }

        let points = pendingPoints
        pendingPoints = nil
        hasPendingRender = false
        return points
    }
}

private final class GestureOverlayView: NSView {
    private let strokeLayer = CAShapeLayer()
    private let dotOuterLayer = CAShapeLayer()
    private let dotInnerLayer = CAShapeLayer()
    private var currentPath = CGMutablePath()
    private var renderedPointCount = 0
    private var renderedOrigin: CGPoint?

    var points: [CGPoint] = [] {
        didSet {
            updatePath()
        }
    }

    override var isFlipped: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    override func layout() {
        super.layout()
        strokeLayer.frame = bounds
        dotOuterLayer.frame = bounds
        dotInnerLayer.frame = bounds
        updateLayerScales()
        updatePath()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayerScales()
        updatePath()
    }

    private func configureLayers() {
        wantsLayer = true

        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.clear.cgColor
        layer = rootLayer

        strokeLayer.fillColor = nil
        strokeLayer.strokeColor = NSColor.systemTeal.cgColor
        strokeLayer.lineWidth = 4
        strokeLayer.lineCap = .round
        strokeLayer.lineJoin = .round

        dotOuterLayer.fillColor = NSColor.white.cgColor
        dotInnerLayer.fillColor = NSColor.systemTeal.cgColor

        rootLayer.addSublayer(strokeLayer)
        rootLayer.addSublayer(dotOuterLayer)
        rootLayer.addSublayer(dotInnerLayer)
    }

    private func updateLayerScales() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        strokeLayer.contentsScale = scale
        dotOuterLayer.contentsScale = scale
        dotInnerLayer.contentsScale = scale
    }

    private func updatePath() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        defer {
            CATransaction.commit()
        }

        guard points.count >= 2 else {
            resetRenderedPath()
            strokeLayer.path = nil
            dotOuterLayer.path = nil
            dotInnerLayer.path = nil
            return
        }

        let origin = window?.frame.origin ?? .zero
        if shouldRebuildPath(origin: origin) {
            rebuildPath(origin: origin)
        } else {
            appendNewPathSegments(origin: origin)
        }

        strokeLayer.path = currentPath

        updateDotPath(origin: origin)
    }

    private func shouldRebuildPath(origin: CGPoint) -> Bool {
        renderedPointCount == 0 ||
            points.count < renderedPointCount ||
            renderedOrigin != origin
    }

    private func rebuildPath(origin: CGPoint) {
        currentPath = CGMutablePath()
        currentPath.move(to: localPoint(for: points[0], origin: origin))

        for point in points.dropFirst() {
            currentPath.addLine(to: localPoint(for: point, origin: origin))
        }

        renderedPointCount = points.count
        renderedOrigin = origin
    }

    private func appendNewPathSegments(origin: CGPoint) {
        guard renderedPointCount < points.count else {
            return
        }

        for index in renderedPointCount..<points.count {
            currentPath.addLine(to: localPoint(for: points[index], origin: origin))
        }

        renderedPointCount = points.count
    }

    private func updateDotPath(origin: CGPoint) {
        guard let last = points.last else {
            dotOuterLayer.path = nil
            dotInnerLayer.path = nil
            return
        }

        let center = localPoint(for: last, origin: origin)
        let dotRect = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
        dotOuterLayer.path = CGPath(ellipseIn: dotRect.insetBy(dx: -2, dy: -2), transform: nil)
        dotInnerLayer.path = CGPath(ellipseIn: dotRect, transform: nil)
    }

    private func resetRenderedPath() {
        currentPath = CGMutablePath()
        renderedPointCount = 0
        renderedOrigin = nil
    }

    private func localPoint(for point: CGPoint, origin: CGPoint) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }
}
