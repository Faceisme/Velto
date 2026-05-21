import SwiftUI

/// Renders one recorded sample (in raw StrokePoint coordinates) as a smooth
/// gradient trail with an optional start dot and end arrow. Coordinates are
/// normalized to the view bounds at draw time.
struct GestureTrailView: View {
    var template: [StrokePoint]
    var stroke: CGFloat = 4
    var colors: [Color] = [.mgAccent, .mgAccentEnd]
    var showStartDot: Bool = true
    var showEndArrow: Bool = true
    var animated: Bool = false

    @State private var progress: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let pts = Self.normalize(template, into: geo.size, padding: max(stroke, 4))
            ZStack {
                if pts.count >= 2 {
                    TrailShape(points: pts)
                        .trim(from: 0, to: progress)
                        .stroke(
                            LinearGradient(colors: colors,
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
                        )

                    if showStartDot {
                        Circle()
                            .fill(colors.first ?? .mgAccent)
                            .frame(width: stroke * 1.1, height: stroke * 1.1)
                            .position(pts.first!)
                            .opacity(progress > 0 ? 1 : 0)
                    }
                    if showEndArrow, let arrow = arrowTransform(at: pts) {
                        ArrowHead(size: stroke * 1.4)
                            .fill(colors.last ?? .mgAccentEnd)
                            .frame(width: stroke * 2, height: stroke * 2)
                            .rotationEffect(.degrees(arrow.angle))
                            .position(arrow.point)
                            .opacity(progress >= 1 ? 1 : 0)
                    }
                }
            }
        }
        .onAppear {
            if animated {
                progress = 0
                withAnimation(.easeOut(duration: 1.0)) { progress = 1 }
            }
        }
    }

    private func arrowTransform(at pts: [CGPoint]) -> (point: CGPoint, angle: Double)? {
        guard pts.count >= 2 else { return nil }
        let a = pts[pts.count - 2], b = pts.last!
        let dx = b.x - a.x, dy = b.y - a.y
        return (b, atan2(dy, dx) * 180 / .pi)
    }

    /// Normalize raw stroke points to fit inside the given size with padding.
    static func normalize(_ template: [StrokePoint], into size: CGSize, padding: CGFloat = 4) -> [CGPoint] {
        guard template.count >= 2 else { return [] }

        var minX = template[0].x, maxX = template[0].x
        var minY = template[0].y, maxY = template[0].y
        for p in template.dropFirst() {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }

        let w = Swift.max(maxX - minX, 1)
        let h = Swift.max(maxY - minY, 1)
        let drawW = Swift.max(size.width - padding * 2, 1)
        let drawH = Swift.max(size.height - padding * 2, 1)
        let scale = Swift.min(drawW / w, drawH / h)
        let scaledW = w * scale
        let scaledH = h * scale
        let originX = padding + (drawW - scaledW) / 2
        let originY = padding + (drawH - scaledH) / 2

        return template.map { p in
            CGPoint(
                x: originX + (p.x - minX) * scale,
                y: originY + (p.y - minY) * scale
            )
        }
    }
}

private struct TrailShape: Shape {
    var points: [CGPoint]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        for pt in points.dropFirst() { p.addLine(to: pt) }
        return p
    }
}

private struct ArrowHead: Shape {
    var size: CGFloat
    func path(in rect: CGRect) -> Path {
        let s = size
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: -s, y: -s * 0.6))
        p.addLine(to: CGPoint(x: -s * 0.5, y: 0))
        p.addLine(to: CGPoint(x: -s, y: s * 0.6))
        p.closeSubpath()
        return p
    }
}

/// Large preview card with dotted-grid background. Renders the most recent
/// template as the primary trail; older templates render as faint ghosts behind.
struct GesturePreviewCard: View {
    var templates: [[StrokePoint]]
    var sampleCount: Int? = nil
    var height: CGFloat = 240
    var animated: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // dotted grid
            Canvas { ctx, size in
                let step: CGFloat = 14
                var y: CGFloat = 1
                while y < size.height {
                    var x: CGFloat = 1
                    while x < size.width {
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)),
                            with: .color(Color.black.opacity(0.08))
                        )
                        x += step
                    }
                    y += step
                }
            }
            .opacity(0.5)

            // ghost samples (older templates, faded)
            ForEach(Array(templates.dropLast().enumerated()), id: \.offset) { _, template in
                GestureTrailView(
                    template: template,
                    stroke: 2,
                    colors: [Color.mgText3, Color.mgText3],
                    showStartDot: false,
                    showEndArrow: false
                )
                .padding(height * 0.10)
            }

            // primary sample (the most recent)
            if let last = templates.last {
                GestureTrailView(
                    template: last,
                    stroke: 4,
                    animated: animated
                )
                .padding(height * 0.10)
            }

            if let n = sampleCount {
                Text("\(n) 个样本")
                    .font(.mgMeta)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(10)
            }
        }
        .frame(height: height)
        .background(
            LinearGradient(
                colors: [Color.mgAccent.opacity(0.06), Color.mgAccentEnd.opacity(0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: MGRadius.card, style: .continuous)
        )
    }
}
