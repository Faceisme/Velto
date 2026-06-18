import Foundation

public enum AnnotationTool: String, CaseIterable, Codable, Equatable, Sendable {
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
}

public enum AnnotationTextAlignment: String, Codable, Equatable, Sendable {
  case left
  case center
  case right
}
