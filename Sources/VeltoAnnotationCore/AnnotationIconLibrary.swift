import CoreGraphics

public enum AnnotationIcon: CaseIterable, Sendable {
  case rectangle
  case ellipse
  case line
  case arrow
  case pen
  case mosaic
  case text
  case highlight
  case sequence
  case crop
  case undo
  case redo
  case cancel
  case save
  case copy
  case scrollCapture
  case complete
}

/// Stroke-only vector glyphs drawn in a 24×24 box. Every glyph is normalized so its
/// path bounding box is centered on (12, 12); the paths carry no color or line width
/// so the toolbar can tint and stroke them uniformly.
public enum AnnotationIconLibrary {
  public static func path(for icon: AnnotationIcon) -> CGPath {
    let raw = rawPath(for: icon)
    let box = raw.boundingBoxOfPath
    guard box.width > 0, box.height > 0 else { return raw }
    var transform = CGAffineTransform(
      translationX: 12 - box.midX,
      y: 12 - box.midY
    )
    return raw.copy(using: &transform) ?? raw
  }

  private static func rawPath(for icon: AnnotationIcon) -> CGPath {
    let path = CGMutablePath()
    switch icon {
    case .rectangle:
      path.addRect(CGRect(x: 5, y: 6, width: 14, height: 12))

    case .ellipse:
      path.addEllipse(in: CGRect(x: 5, y: 5, width: 14, height: 14))

    case .line:
      path.move(to: CGPoint(x: 6, y: 18))
      path.addLine(to: CGPoint(x: 18, y: 6))

    case .arrow:
      path.move(to: CGPoint(x: 6, y: 18))
      path.addLine(to: CGPoint(x: 18, y: 6))
      path.move(to: CGPoint(x: 12, y: 6))
      path.addLine(to: CGPoint(x: 18, y: 6))
      path.addLine(to: CGPoint(x: 18, y: 12))

    case .pen:
      // Pencil body running diagonally with a nib at the lower-left.
      path.move(to: CGPoint(x: 16, y: 5))
      path.addLine(to: CGPoint(x: 19, y: 8))
      path.addLine(to: CGPoint(x: 9, y: 18))
      path.addLine(to: CGPoint(x: 6, y: 15))
      path.closeSubpath()
      path.move(to: CGPoint(x: 6, y: 15))
      path.addLine(to: CGPoint(x: 5, y: 19))
      path.addLine(to: CGPoint(x: 9, y: 18))

    case .mosaic:
      // 2×2 网格:24px 下 3×3 太密糊成一团,四宫格更清晰。
      path.addRect(CGRect(x: 5, y: 5, width: 14, height: 14))
      path.move(to: CGPoint(x: 12, y: 5))
      path.addLine(to: CGPoint(x: 12, y: 19))
      path.move(to: CGPoint(x: 5, y: 12))
      path.addLine(to: CGPoint(x: 19, y: 12))

    case .text:
      path.move(to: CGPoint(x: 6, y: 6))
      path.addLine(to: CGPoint(x: 18, y: 6))
      path.move(to: CGPoint(x: 12, y: 6))
      path.addLine(to: CGPoint(x: 12, y: 18))

    case .highlight:
      // 荧光笔:斜置笔身 + 扁凿笔尖 + 全宽划线,与铅笔(pen)明确区分。
      path.move(to: CGPoint(x: 15, y: 4))
      path.addLine(to: CGPoint(x: 19, y: 8))
      path.addLine(to: CGPoint(x: 11, y: 16))
      path.addLine(to: CGPoint(x: 7, y: 12))
      path.closeSubpath()
      path.move(to: CGPoint(x: 7, y: 12))
      path.addLine(to: CGPoint(x: 4.5, y: 16.5))
      path.addLine(to: CGPoint(x: 11, y: 16))
      path.closeSubpath()
      path.move(to: CGPoint(x: 5, y: 20))
      path.addLine(to: CGPoint(x: 19, y: 20))

    case .sequence:
      path.addEllipse(in: CGRect(x: 5, y: 5, width: 14, height: 14))
      path.move(to: CGPoint(x: 10.5, y: 10))
      path.addLine(to: CGPoint(x: 12, y: 8.5))
      path.addLine(to: CGPoint(x: 12, y: 16))

    case .crop:
      path.move(to: CGPoint(x: 8, y: 5))
      path.addLine(to: CGPoint(x: 8, y: 16))
      path.addLine(to: CGPoint(x: 19, y: 16))
      path.move(to: CGPoint(x: 5, y: 8))
      path.addLine(to: CGPoint(x: 16, y: 8))
      path.addLine(to: CGPoint(x: 16, y: 19))

    case .undo:
      // 左向燕尾箭头 + 向右回卷的半圆尾巴(lucide undo-2 几何)。
      path.move(to: CGPoint(x: 9, y: 14))
      path.addLine(to: CGPoint(x: 4, y: 9))
      path.addLine(to: CGPoint(x: 9, y: 4))
      path.move(to: CGPoint(x: 4, y: 9))
      path.addLine(to: CGPoint(x: 14.5, y: 9))
      path.addArc(
        center: CGPoint(x: 14.5, y: 14.5),
        radius: 5.5,
        startAngle: -.pi / 2,
        endAngle: .pi / 2,
        clockwise: false
      )
      path.addLine(to: CGPoint(x: 11, y: 20))

    case .redo:
      path.move(to: CGPoint(x: 15, y: 14))
      path.addLine(to: CGPoint(x: 20, y: 9))
      path.addLine(to: CGPoint(x: 15, y: 4))
      path.move(to: CGPoint(x: 20, y: 9))
      path.addLine(to: CGPoint(x: 9.5, y: 9))
      path.addArc(
        center: CGPoint(x: 9.5, y: 14.5),
        radius: 5.5,
        startAngle: -.pi / 2,
        endAngle: .pi / 2,
        clockwise: true
      )
      path.addLine(to: CGPoint(x: 13, y: 20))

    case .cancel:
      path.move(to: CGPoint(x: 7, y: 7))
      path.addLine(to: CGPoint(x: 17, y: 17))
      path.move(to: CGPoint(x: 17, y: 7))
      path.addLine(to: CGPoint(x: 7, y: 17))

    case .save:
      path.move(to: CGPoint(x: 12, y: 5))
      path.addLine(to: CGPoint(x: 12, y: 15))
      path.move(to: CGPoint(x: 8, y: 11))
      path.addLine(to: CGPoint(x: 12, y: 15))
      path.addLine(to: CGPoint(x: 16, y: 11))
      path.move(to: CGPoint(x: 6, y: 18))
      path.addLine(to: CGPoint(x: 18, y: 18))

    case .copy:
      // 前层圆角矩形 + 背层只露上/左两边(lucide copy 几何),不再整框互相穿插。
      path.addRoundedRect(
        in: CGRect(x: 9, y: 9, width: 12, height: 12),
        cornerWidth: 2, cornerHeight: 2
      )
      path.move(to: CGPoint(x: 15.5, y: 5))
      path.addArc(
        tangent1End: CGPoint(x: 5, y: 5),
        tangent2End: CGPoint(x: 5, y: 15.5),
        radius: 2
      )
      path.addLine(to: CGPoint(x: 5, y: 15.5))

    case .scrollCapture:
      // 滚动长截图:页面视窗 + 内容线 + 向下滚动箭头。
      path.addRoundedRect(
        in: CGRect(x: 6, y: 4, width: 12, height: 16),
        cornerWidth: 2, cornerHeight: 2
      )
      path.move(to: CGPoint(x: 9, y: 8))
      path.addLine(to: CGPoint(x: 15, y: 8))
      path.move(to: CGPoint(x: 9, y: 11))
      path.addLine(to: CGPoint(x: 15, y: 11))
      path.move(to: CGPoint(x: 12, y: 13))
      path.addLine(to: CGPoint(x: 12, y: 19))
      path.move(to: CGPoint(x: 9, y: 16))
      path.addLine(to: CGPoint(x: 12, y: 19))
      path.addLine(to: CGPoint(x: 15, y: 16))

    case .complete:
      path.move(to: CGPoint(x: 6, y: 12))
      path.addLine(to: CGPoint(x: 10, y: 17))
      path.addLine(to: CGPoint(x: 18, y: 7))
    }
    return path
  }
}
