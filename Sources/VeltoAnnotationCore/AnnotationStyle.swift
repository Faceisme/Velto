import AppKit
import Foundation

public struct AnnotationColor: Codable, Equatable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public init?(resolving color: NSColor) {
    guard let aqua = NSAppearance(named: .aqua) else { return nil }
    var converted: NSColor?
    aqua.performAsCurrentDrawingAppearance {
      converted = color.usingColorSpace(.sRGB)
    }
    guard let rgb = converted else { return nil }

    self.init(
      red: Double(rgb.redComponent),
      green: Double(rgb.greenComponent),
      blue: Double(rgb.blueComponent),
      alpha: Double(rgb.alphaComponent)
    )
  }

  public var nsColor: NSColor {
    NSColor(
      srgbRed: CGFloat(red),
      green: CGFloat(green),
      blue: CGFloat(blue),
      alpha: CGFloat(alpha)
    )
  }

  public static let systemRed: AnnotationColor = {
    let fallback = AnnotationColor(red: 1, green: 56.0 / 255.0, blue: 60.0 / 255.0)
    return AnnotationColor(resolving: .systemRed) ?? fallback
  }()
}

public struct AnnotationStyle: Codable, Equatable, Sendable {
  public var strokeColor: AnnotationColor
  public var lineWidth: CGFloat
  public var fillColor: AnnotationColor
  public var fillOpacity: CGFloat
  public var fontSize: CGFloat
  public var isBold: Bool
  public var textAlignment: AnnotationTextAlignment
  public var highlightOpacity: CGFloat
  public var mosaicBlockSize: Int
  public var sequenceDiameter: CGFloat

  public init(
    strokeColor: AnnotationColor,
    lineWidth: CGFloat,
    fillColor: AnnotationColor,
    fillOpacity: CGFloat,
    fontSize: CGFloat,
    isBold: Bool,
    textAlignment: AnnotationTextAlignment,
    highlightOpacity: CGFloat,
    mosaicBlockSize: Int,
    sequenceDiameter: CGFloat
  ) {
    self.strokeColor = strokeColor
    self.lineWidth = lineWidth
    self.fillColor = fillColor
    self.fillOpacity = fillOpacity
    self.fontSize = fontSize
    self.isBold = isBold
    self.textAlignment = textAlignment
    self.highlightOpacity = highlightOpacity
    self.mosaicBlockSize = mosaicBlockSize
    self.sequenceDiameter = sequenceDiameter
  }

  public static let defaults = AnnotationStyle(
    strokeColor: .systemRed,
    lineWidth: 3,
    fillColor: .systemRed,
    fillOpacity: 0,
    fontSize: 18,
    isBold: false,
    textAlignment: .left,
    highlightOpacity: 0.35,
    mosaicBlockSize: 12,
    sequenceDiameter: 28
  )
}
