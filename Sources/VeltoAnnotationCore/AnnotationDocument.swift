import CoreGraphics
import Foundation

public struct AnnotationDocument: Equatable, Sendable {
  public var canvasSize: CGSize
  public var cropRect: CGRect
  public var elements: [AnnotationElement]
  public var selectedElementID: UUID?
  public var activeTool: AnnotationTool?
  public var nextSequenceNumber: Int

  public init(canvasSize: CGSize) {
    self.canvasSize = canvasSize
    cropRect = CGRect(origin: .zero, size: canvasSize)
    elements = []
    selectedElementID = nil
    activeTool = nil
    nextSequenceNumber = 1
  }
}
