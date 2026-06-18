import CoreGraphics
import Foundation

public struct BoxAnnotation: Equatable, Sendable {
  public let id: UUID
  public var rect: CGRect
  public var style: AnnotationStyle

  public init(id: UUID = UUID(), rect: CGRect, style: AnnotationStyle) {
    self.id = id
    self.rect = rect
    self.style = style
  }
}

public struct SegmentAnnotation: Equatable, Sendable {
  public let id: UUID
  public var start: CGPoint
  public var end: CGPoint
  public var style: AnnotationStyle

  public init(id: UUID = UUID(), start: CGPoint, end: CGPoint, style: AnnotationStyle) {
    self.id = id
    self.start = start
    self.end = end
    self.style = style
  }
}

public struct PathAnnotation: Equatable, Sendable {
  public let id: UUID
  public var points: [CGPoint]
  public var style: AnnotationStyle

  public init(id: UUID = UUID(), points: [CGPoint], style: AnnotationStyle) {
    self.id = id
    self.points = points
    self.style = style
  }
}

public struct MosaicAnnotation: Equatable, Sendable {
  public let id: UUID
  public var rect: CGRect
  public var blockSize: Int

  public init(id: UUID = UUID(), rect: CGRect, blockSize: Int) {
    self.id = id
    self.rect = rect
    self.blockSize = blockSize
  }
}

public struct TextAnnotation: Equatable, Sendable {
  public let id: UUID
  public var rect: CGRect
  public var text: String
  public var style: AnnotationStyle

  public init(id: UUID = UUID(), rect: CGRect, text: String, style: AnnotationStyle) {
    self.id = id
    self.rect = rect
    self.text = text
    self.style = style
  }
}

public struct SequenceAnnotation: Equatable, Sendable {
  public let id: UUID
  public var center: CGPoint
  public var number: Int
  public var style: AnnotationStyle

  public init(id: UUID = UUID(), center: CGPoint, number: Int, style: AnnotationStyle) {
    self.id = id
    self.center = center
    self.number = number
    self.style = style
  }
}

public enum AnnotationElement: Equatable, Sendable {
  case rectangle(BoxAnnotation)
  case ellipse(BoxAnnotation)
  case line(SegmentAnnotation)
  case arrow(SegmentAnnotation)
  case freehand(PathAnnotation)
  case highlight(PathAnnotation)
  case mosaic(MosaicAnnotation)
  case text(TextAnnotation)
  case sequence(SequenceAnnotation)

  public var id: UUID {
    switch self {
    case .rectangle(let value), .ellipse(let value):
      value.id
    case .line(let value), .arrow(let value):
      value.id
    case .freehand(let value), .highlight(let value):
      value.id
    case .mosaic(let value):
      value.id
    case .text(let value):
      value.id
    case .sequence(let value):
      value.id
    }
  }
}
