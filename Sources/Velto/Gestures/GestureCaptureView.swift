import AppKit
import Foundation
import SwiftUI

/// Transparent NSView that captures a single left-button mouse stroke and
/// reports the points to its host. The view draws nothing chrome-related —
/// the surrounding `GesturePreviewCard` provides the background, dotted grid,
/// and rendering of already-saved samples. While the user is drawing we paint
/// just the live stroke on top in the accent color, so they can see the path
/// take shape; when they release we emit the points and clear the in-progress
/// stroke.
final class GestureCaptureView: NSView {
    var onStrokeFinished: (([CGPoint]) -> Void)?

    private var points: [CGPoint] = [] {
        didSet { invalidateForPointChange(from: oldValue, to: points) }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 完全透明 — 让 SwiftUI 层(GesturePreviewCard)负责所有装饰。
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        points = [convert(event.locationInWindow, from: nil)]
    }

    override func mouseDragged(with event: NSEvent) {
        points.append(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        points.append(convert(event.locationInWindow, from: nil))
        let finished = points
        points = []
        if finished.count >= 2 {
            onStrokeFinished?(finished)
        }
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
