import AppKit
import Foundation

final class GestureCaptureView: NSView {
    var onStrokeFinished: (([CGPoint]) -> Void)?

    private var savedTemplates: [[CGPoint]] = [] {
        didSet {
            needsDisplay = true
        }
    }

    private var points: [CGPoint] = [] {
        didSet {
            invalidateForPointChange(from: oldValue, to: points)
        }
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clear() {
        points = []
    }

    func showTemplates(_ templates: [[StrokePoint]]) {
        savedTemplates = templates.map { template in
            template.map(\.cgPoint)
        }
        points = []
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
        if points.count >= 2 {
            onStrokeFinished?(points)
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

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        if points.isEmpty {
            if savedTemplates.isEmpty {
                "在这里画一个手势样本".draw(
                    in: bounds.insetBy(dx: 16, dy: bounds.height / 2 - 10),
                    withAttributes: attributes
                )
            } else {
                drawSavedTemplates()
            }
            return
        }

        "松开鼠标保存这个样本".draw(
            in: bounds.insetBy(dx: 16, dy: bounds.height / 2 - 10),
            withAttributes: attributes
        )

        drawPath(points, color: .systemTeal, lineWidth: 4, normalizeToBounds: false)
    }

    private func drawSavedTemplates() {
        for (index, template) in savedTemplates.enumerated() where template.count >= 2 {
            let isLast = index == savedTemplates.count - 1
            drawPath(
                template,
                color: isLast ? .systemTeal : .tertiaryLabelColor,
                lineWidth: isLast ? 4 : 2,
                normalizeToBounds: true
            )
        }
    }

    private func drawPath(
        _ rawPoints: [CGPoint],
        color: NSColor,
        lineWidth: CGFloat,
        normalizeToBounds: Bool
    ) {
        let drawablePoints = normalizeToBounds ? normalized(rawPoints) : rawPoints
        guard drawablePoints.count >= 2 else {
            return
        }

        let path = NSBezierPath()
        path.move(to: drawablePoints[0])
        for point in drawablePoints.dropFirst() {
            path.line(to: point)
        }

        color.setStroke()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func normalized(_ rawPoints: [CGPoint]) -> [CGPoint] {
        guard rawPoints.count >= 2 else {
            return rawPoints
        }

        var minX = rawPoints[0].x
        var maxX = rawPoints[0].x
        var minY = rawPoints[0].y
        var maxY = rawPoints[0].y

        for point in rawPoints.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        let width = max(maxX - minX, 1)
        let height = max(maxY - minY, 1)
        let drawRect = bounds.insetBy(dx: 34, dy: 34)
        let scale = min(drawRect.width / width, drawRect.height / height)
        let scaledWidth = width * scale
        let scaledHeight = height * scale
        let origin = CGPoint(
            x: drawRect.minX + (drawRect.width - scaledWidth) / 2,
            y: drawRect.minY + (drawRect.height - scaledHeight) / 2
        )

        return rawPoints.map { point in
            CGPoint(
                x: origin.x + (point.x - minX) * scale,
                y: origin.y + (point.y - minY) * scale
            )
        }
    }
}
