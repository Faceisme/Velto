import SwiftUI

// MARK: - GestureTrailView
//
// 渲染一组手势样本(templates),其中:
//  - 最后一个样本作为"主轨迹":粗渐变实色线 + 起点圆点 + 终点箭头
//  - 前面所有样本作为"羽毛感衬底":opacity 0.22, stroke 0.55×
// 所有 sample 共享同一个 union-bbox 归一化,这样 ghost 才会和 main 真正叠在一起。

struct GestureTrailView: View {
    var templates: [[StrokePoint]]
    var stroke: CGFloat = 4
    var colors: [Color] = [.mgAccent, .mgAccentEnd]
    var showStartDot: Bool = true
    var showEndArrow: Bool = true
    /// 最多渲染的 ghost 数量(避免糊成一团)。负数表示不限制。
    var maxGhosts: Int = 4

    var body: some View {
        Canvas { ctx, size in
            guard let main = templates.last else { return }
            let pad = max(stroke, 4)

            // union 归一化:所有 templates 共享一个 bbox,这样它们会自然叠在一起
            let unionBox = Self.unionBoundingBox(templates) ?? Self.boundingBox(main)
            guard let box = unionBox else { return }

            // ghost 样本(除最后一个之外的最近 N 个)
            // 使用一个 opacity 0.22 的子 context 把所有 ghost 一次性盖上去
            let ghosts = Array(templates.dropLast().suffix(max(maxGhosts, 0)))
            if !ghosts.isEmpty {
                var ghostCtx = ctx
                ghostCtx.opacity = 0.22
                for sample in ghosts {
                    let pts = Self.normalize(sample, in: box, into: size, padding: pad)
                    guard pts.count >= 2 else { continue }
                    var path = Path()
                    path.move(to: pts[0])
                    for p in pts.dropFirst() { path.addLine(to: p) }
                    ghostCtx.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: colors),
                            startPoint: .zero,
                            endPoint: CGPoint(x: size.width, y: size.height)
                        ),
                        style: StrokeStyle(lineWidth: stroke * 0.55, lineCap: .round, lineJoin: .round)
                    )
                }
            }

            // 主轨迹
            let mainPts = Self.normalize(main, in: box, into: size, padding: pad)
            if mainPts.count >= 2 {
                var path = Path()
                path.move(to: mainPts[0])
                for p in mainPts.dropFirst() { path.addLine(to: p) }
                ctx.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: colors),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: size.height)
                    ),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
                )

                if showStartDot, let start = mainPts.first {
                    let r = stroke * 0.85
                    let rect = CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(colors.first ?? .mgAccent))
                }

                if showEndArrow, mainPts.count >= 2 {
                    let a = mainPts[mainPts.count - 2]
                    let b = mainPts.last!
                    let angle = atan2(b.y - a.y, b.x - a.x)
                    let s = max(stroke * 1.6, 6)

                    var arrow = Path()
                    arrow.move(to: .zero)
                    arrow.addLine(to: CGPoint(x: -s,        y: -s * 0.65))
                    arrow.addLine(to: CGPoint(x: -s * 0.4,  y: 0))
                    arrow.addLine(to: CGPoint(x: -s,        y:  s * 0.65))
                    arrow.closeSubpath()

                    var sub = ctx
                    sub.translateBy(x: b.x, y: b.y)
                    sub.rotate(by: .radians(angle))
                    sub.fill(arrow, with: .color(colors.last ?? .mgAccentEnd))
                }
            }
        }
        // ghost 部分一次性透明 — 简化做法:把整层包一个 .opacity 不行(影响主轨迹),
        // 改为下面这样:再把 ghost 画一次到底层,主轨迹在上层 — 但 Canvas 是单 pass。
        // 折中:直接接受 ghost 偏实色 — 视觉上 stroke 已经被 ×0.55 削细,效果近似。
    }

    // MARK: - Geometry helpers

    /// Convenience used by the small thumbnail in the gesture list.
    static func normalize(_ template: [StrokePoint], into size: CGSize, padding: CGFloat = 4) -> [CGPoint] {
        guard let box = boundingBox(template) else { return [] }
        return normalize(template, in: box, into: size, padding: padding)
    }

    static func boundingBox(_ template: [StrokePoint]) -> CGRect? {
        guard let first = template.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in template.dropFirst() {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    static func unionBoundingBox(_ templates: [[StrokePoint]]) -> CGRect? {
        var union: CGRect?
        for t in templates {
            guard let box = boundingBox(t) else { continue }
            union = union?.union(box) ?? box
        }
        return union
    }

    static func normalize(_ template: [StrokePoint], in box: CGRect, into size: CGSize, padding: CGFloat) -> [CGPoint] {
        guard template.count >= 2 else { return [] }
        let drawW = max(size.width - padding * 2, 1)
        let drawH = max(size.height - padding * 2, 1)
        let scale = min(drawW / box.width, drawH / box.height)
        let scaledW = box.width * scale
        let scaledH = box.height * scale
        let originX = padding + (drawW - scaledW) / 2
        let originY = padding + (drawH - scaledH) / 2
        return template.map { p in
            CGPoint(
                x: originX + (p.x - box.minX) * scale,
                y: originY + (p.y - box.minY) * scale
            )
        }
    }
}

// MARK: - GesturePreviewCard
//
// 大的录制画布:
//  - 高 220px,圆角 10px
//  - 三层背景: 两个 radial gradient + #F8F9FB
//  - dotted grid 衬底, 每 14px 一个点, opacity 0.45
//  - 右上角玻璃药丸 "● N 个样本"
//  - 左下角灰色提示 "按住右键并画出轨迹"

struct GesturePreviewCard<Overlay: View>: View {
    var templates: [[StrokePoint]]
    var sampleCount: Int? = nil
    var height: CGFloat = 220
    var hint: String? = "按住右键并画出轨迹"
    @ViewBuilder var overlay: () -> Overlay

    init(
        templates: [[StrokePoint]],
        sampleCount: Int? = nil,
        height: CGFloat = 220,
        hint: String? = "按住右键并画出轨迹",
        @ViewBuilder overlay: @escaping () -> Overlay = { EmptyView() }
    ) {
        self.templates = templates
        self.sampleCount = sampleCount
        self.height = height
        self.hint = hint
        self.overlay = overlay
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MGRadius.cardSm, style: .continuous)
        return ZStack {
            shape
                .fill(Color.mgCardAlt)
                .veltoNativeGlass(in: shape)

            // 点阵网格
            Canvas { ctx, size in
                let step: CGFloat = 14
                let dotColor = Color.mgText3.opacity(0.16)
                var y: CGFloat = 1
                while y < size.height {
                    var x: CGFloat = 1
                    while x < size.width {
                        let rect = CGRect(x: x, y: y, width: 1, height: 1)
                        ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
                        x += step
                    }
                    y += step
                }
            }
            .opacity(0.45)

            // 居中的大轨迹
            GestureTrailView(templates: templates, stroke: 5)
                .padding(height * 0.10)

            // 自定义 overlay(比如录制中的轨迹)
            overlay()

            // 提示文字 (左下)
            if let hint, !hint.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Text(hint)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.mgText3)
                        Spacer()
                    }
                }
                .padding(.leading, 12)
                .padding(.bottom, 10)
            }

            // 样本数玻璃药丸 (右上)
            if let n = sampleCount {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.mgAccent)
                                .frame(width: 6, height: 6)
                            Text("\(n) 个样本")
                                .font(.mgSubLabel)
                                .foregroundStyle(Color.mgText1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.mgGlassControl)
                        )
                        .veltoNativeGlass(in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.mgHair, lineWidth: 0.5)
                        )
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
        .frame(height: height)
        .overlay {
            shape.strokeBorder(Color.mgHair, lineWidth: 0.5)
        }
        .clipShape(shape)
    }
}
