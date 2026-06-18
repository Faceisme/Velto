import AppKit
import CoreGraphics
import CoreText
import Foundation

public enum AnnotationRenderError: Error, Equatable {
  case contextCreationFailed
  case imageCreationFailed
  case invalidCropRect
}

/// Shared compositor for both the on-screen preview and the exported image, so a
/// Retina export looks identical to what the user saw while editing. Annotation
/// coordinates are top-left origin (y increases downward), matching the flipped
/// editing canvas.
public enum AnnotationRenderer {
  public static func render(
    baseImage: CGImage,
    document: AnnotationDocument,
    scale: CGFloat
  ) -> Result<CGImage, AnnotationRenderError> {
    guard scale > 0 else { return .failure(.invalidCropRect) }

    let canvas = CGRect(origin: .zero, size: document.canvasSize)
    let crop = document.cropRect.standardized.intersection(canvas)
    guard !crop.isNull, crop.width >= 1, crop.height >= 1 else {
      return .failure(.invalidCropRect)
    }

    let pixelWidth = Int((document.canvasSize.width * scale).rounded())
    let pixelHeight = Int((document.canvasSize.height * scale).rounded())
    guard pixelWidth > 0, pixelHeight > 0 else { return .failure(.invalidCropRect) }

    guard let context = CGContext(
      data: nil,
      width: pixelWidth,
      height: pixelHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return .failure(.contextCreationFailed)
    }

    // Flip so annotation coordinates (top-left, points) map to device pixels.
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(x: scale, y: -scale)

    context.interpolationQuality = .high
    // The base image is an upright (top-left origin) bitmap; under the y-down
    // annotation CTM `draw` would render it upside down, so flip it back just for
    // the image. Mosaics and vectors keep the y-down CTM (annotation coordinates).
    context.saveGState()
    context.translateBy(x: 0, y: canvas.height)
    context.scaleBy(x: 1, y: -1)
    context.draw(baseImage, in: canvas)
    context.restoreGState()

    for case .mosaic(let mosaic) in document.elements {
      AnnotationMosaicRenderer.draw(mosaic, baseImage: baseImage, scale: scale, in: context)
    }

    drawAnnotations(in: context, document: document, scale: scale)

    guard let composited = context.makeImage() else {
      return .failure(.imageCreationFailed)
    }

    let pixelCrop = CGRect(
      x: (crop.minX * scale).rounded(),
      y: (crop.minY * scale).rounded(),
      width: (crop.width * scale).rounded(),
      height: (crop.height * scale).rounded()
    )
    guard let cropped = composited.cropping(to: pixelCrop) else {
      return .failure(.imageCreationFailed)
    }
    return .success(cropped)
  }

  /// Draws every vector (non-mosaic) element at annotation coordinates. The caller
  /// is responsible for the current transform; mosaics are drawn separately because
  /// they need the immutable base image.
  public static func drawAnnotations(
    in context: CGContext,
    document: AnnotationDocument,
    scale: CGFloat
  ) {
    for element in document.elements {
      if case .mosaic = element { continue }
      drawVector(element, in: context)
    }
  }

  // MARK: - Vector drawing

  private static func drawVector(_ element: AnnotationElement, in context: CGContext) {
    switch element {
    case .rectangle(let value):
      drawBox(value, in: context) { rect in CGPath(rect: rect, transform: nil) }
    case .ellipse(let value):
      drawBox(value, in: context) { rect in CGPath(ellipseIn: rect, transform: nil) }
    case .line(let value):
      drawSegment(value, arrow: false, in: context)
    case .arrow(let value):
      drawSegment(value, arrow: true, in: context)
    case .freehand(let value):
      drawStrokePath(value, highlight: false, in: context)
    case .highlight(let value):
      drawStrokePath(value, highlight: true, in: context)
    case .text(let value):
      drawText(value, in: context)
    case .sequence(let value):
      drawSequence(value, in: context)
    case .mosaic:
      break
    }
  }

  private static func drawBox(
    _ box: BoxAnnotation,
    in context: CGContext,
    path makePath: (CGRect) -> CGPath
  ) {
    let rect = box.rect.standardized
    guard rect.width > 0 || rect.height > 0 else { return }
    let path = makePath(rect)

    if box.style.fillOpacity > 0 {
      context.saveGState()
      context.addPath(path)
      context.setFillColor(cgColor(box.style.fillColor, alpha: box.style.fillOpacity))
      context.fillPath()
      context.restoreGState()
    }

    guard box.style.lineWidth > 0 else { return }
    context.saveGState()
    context.addPath(path)
    context.setStrokeColor(cgColor(box.style.strokeColor))
    context.setLineWidth(box.style.lineWidth)
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()
  }

  private static func drawSegment(
    _ segment: SegmentAnnotation,
    arrow: Bool,
    in context: CGContext
  ) {
    let lineWidth = max(0.5, segment.style.lineWidth)
    context.saveGState()
    context.setStrokeColor(cgColor(segment.style.strokeColor))
    context.setFillColor(cgColor(segment.style.strokeColor))
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    context.move(to: segment.start)
    context.addLine(to: segment.end)
    context.strokePath()

    if arrow {
      let angle = atan2(segment.end.y - segment.start.y, segment.end.x - segment.start.x)
      let length = hypot(segment.end.x - segment.start.x, segment.end.y - segment.start.y)
      let headLength = min(length, max(10, lineWidth * 3.5))
      let headAngle = CGFloat.pi / 6
      let left = CGPoint(
        x: segment.end.x - headLength * cos(angle - headAngle),
        y: segment.end.y - headLength * sin(angle - headAngle)
      )
      let right = CGPoint(
        x: segment.end.x - headLength * cos(angle + headAngle),
        y: segment.end.y - headLength * sin(angle + headAngle)
      )
      context.move(to: left)
      context.addLine(to: segment.end)
      context.addLine(to: right)
      context.strokePath()
    }
    context.restoreGState()
  }

  private static func drawStrokePath(
    _ path: PathAnnotation,
    highlight: Bool,
    in context: CGContext
  ) {
    guard path.points.count >= 1 else { return }
    let smoothed = AnnotationGeometry.smoothedPath(points: path.points)
    context.saveGState()
    if highlight {
      context.setBlendMode(.multiply)
      context.setStrokeColor(cgColor(path.style.strokeColor, alpha: path.style.highlightOpacity))
      context.setLineWidth(max(path.style.lineWidth * 3, 8))
    } else {
      context.setStrokeColor(cgColor(path.style.strokeColor))
      context.setLineWidth(max(0.5, path.style.lineWidth))
    }
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(smoothed)
    context.strokePath()
    context.restoreGState()
  }

  private static func drawText(_ text: TextAnnotation, in context: CGContext) {
    guard !text.text.isEmpty else { return }
    let rect = text.rect.standardized
    guard rect.width > 0, rect.height > 0 else { return }

    let attributed = attributedString(
      text.text,
      style: text.style,
      alignment: text.style.textAlignment
    )
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let framePath = CGPath(
      rect: CGRect(x: 0, y: 0, width: rect.width, height: rect.height),
      transform: nil
    )
    let frame = CTFramesetterCreateFrame(
      framesetter,
      CFRangeMake(0, attributed.length),
      framePath,
      nil
    )

    context.saveGState()
    context.textMatrix = .identity
    // Local y-up frame anchored at the text box, undoing the outer y-flip.
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    CTFrameDraw(frame, context)
    context.restoreGState()
  }

  private static func drawSequence(_ sequence: SequenceAnnotation, in context: CGContext) {
    let diameter = max(1, sequence.style.sequenceDiameter)
    let rect = CGRect(
      x: sequence.center.x - diameter / 2,
      y: sequence.center.y - diameter / 2,
      width: diameter,
      height: diameter
    )

    context.saveGState()
    context.setFillColor(cgColor(sequence.style.strokeColor))
    context.fillEllipse(in: rect)
    context.restoreGState()

    var badgeStyle = sequence.style
    badgeStyle.fontSize = max(10, diameter * 0.55)
    badgeStyle.isBold = true
    let attributed = attributedString(
      "\(sequence.number)",
      style: badgeStyle,
      alignment: .center,
      color: AnnotationColor(red: 1, green: 1, blue: 1, alpha: 1)
    )
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

    context.saveGState()
    context.textMatrix = .identity
    context.translateBy(x: sequence.center.x, y: sequence.center.y)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = CGPoint(
      x: -bounds.width / 2 - bounds.minX,
      y: -bounds.height / 2 - bounds.minY
    )
    CTLineDraw(line, context)
    context.restoreGState()
  }

  // MARK: - Helpers

  private static func attributedString(
    _ string: String,
    style: AnnotationStyle,
    alignment: AnnotationTextAlignment,
    color: AnnotationColor? = nil
  ) -> NSAttributedString {
    let font = NSFont.systemFont(
      ofSize: style.fontSize,
      weight: style.isBold ? .bold : .regular
    )
    let paragraph = NSMutableParagraphStyle()
    switch alignment {
    case .left: paragraph.alignment = .left
    case .center: paragraph.alignment = .center
    case .right: paragraph.alignment = .right
    }
    let resolved = color ?? style.strokeColor
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: resolved.nsColor,
      .paragraphStyle: paragraph,
    ]
    return NSAttributedString(string: string, attributes: attributes)
  }

  private static func cgColor(_ color: AnnotationColor, alpha: CGFloat? = nil) -> CGColor {
    CGColor(
      red: CGFloat(color.red),
      green: CGFloat(color.green),
      blue: CGFloat(color.blue),
      alpha: alpha ?? CGFloat(color.alpha)
    )
  }
}
