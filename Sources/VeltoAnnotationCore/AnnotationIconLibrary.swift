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
      path.addEllipse(in: CGRect(x: 5, y: 6, width: 14, height: 12))

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
      path.addRect(CGRect(x: 5, y: 5, width: 14, height: 14))
      path.move(to: CGPoint(x: 9.66, y: 5))
      path.addLine(to: CGPoint(x: 9.66, y: 19))
      path.move(to: CGPoint(x: 14.33, y: 5))
      path.addLine(to: CGPoint(x: 14.33, y: 19))
      path.move(to: CGPoint(x: 5, y: 9.66))
      path.addLine(to: CGPoint(x: 19, y: 9.66))
      path.move(to: CGPoint(x: 5, y: 14.33))
      path.addLine(to: CGPoint(x: 19, y: 14.33))

    case .text:
      path.move(to: CGPoint(x: 6, y: 6))
      path.addLine(to: CGPoint(x: 18, y: 6))
      path.move(to: CGPoint(x: 12, y: 6))
      path.addLine(to: CGPoint(x: 12, y: 18))

    case .highlight:
      // Marker nib sweeping diagonally.
      path.move(to: CGPoint(x: 7, y: 17))
      path.addLine(to: CGPoint(x: 15, y: 7))
      path.addLine(to: CGPoint(x: 18, y: 10))
      path.addLine(to: CGPoint(x: 10, y: 20))
      path.closeSubpath()
      path.move(to: CGPoint(x: 6, y: 20))
      path.addLine(to: CGPoint(x: 10, y: 20))

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
      path.addArc(
        center: CGPoint(x: 12, y: 12),
        radius: 5.5,
        startAngle: -0.35,
        endAngle: 4.2,
        clockwise: false
      )
      path.move(to: CGPoint(x: 6.2, y: 9))
      path.addLine(to: CGPoint(x: 6.6, y: 13.4))
      path.addLine(to: CGPoint(x: 10.6, y: 11.6))

    case .redo:
      path.addArc(
        center: CGPoint(x: 12, y: 12),
        radius: 5.5,
        startAngle: .pi + 0.35,
        endAngle: .pi - 1.05,
        clockwise: true
      )
      path.move(to: CGPoint(x: 17.8, y: 9))
      path.addLine(to: CGPoint(x: 17.4, y: 13.4))
      path.addLine(to: CGPoint(x: 13.4, y: 11.6))

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
      path.addRect(CGRect(x: 5, y: 7, width: 10, height: 12))
      path.addRect(CGRect(x: 9, y: 5, width: 10, height: 12))

    case .complete:
      path.move(to: CGPoint(x: 6, y: 12))
      path.addLine(to: CGPoint(x: 10, y: 17))
      path.addLine(to: CGPoint(x: 18, y: 7))
    }
    return path
  }
}
