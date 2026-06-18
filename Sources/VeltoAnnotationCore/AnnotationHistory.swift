import CoreGraphics

public struct AnnotationHistory: Sendable {
  private struct UndoSnapshot: Equatable, Sendable {
    let canvasSize: CGSize
    let cropRect: CGRect
    let elements: [AnnotationElement]
    let nextSequenceNumber: Int

    init(document: AnnotationDocument) {
      canvasSize = document.canvasSize
      cropRect = document.cropRect
      elements = document.elements
      nextSequenceNumber = document.nextSequenceNumber
    }

    func apply(to document: inout AnnotationDocument) {
      let selectedElementID = document.selectedElementID
      document.canvasSize = canvasSize
      document.cropRect = cropRect
      document.elements = elements
      document.nextSequenceNumber = nextSequenceNumber
      document.selectedElementID = selectedElementID.flatMap { selectedID in
        elements.contains { $0.id == selectedID } ? selectedID : nil
      }
    }
  }

  private struct Entry: Sendable {
    let before: UndoSnapshot
    let after: UndoSnapshot
  }

  private let limit: Int
  private var undoStack: [Entry] = []
  private var redoStack: [Entry] = []

  public init(limit: Int = 100) {
    self.limit = max(1, limit)
  }

  public var undoCount: Int {
    undoStack.count
  }

  public var redoCount: Int {
    redoStack.count
  }

  public mutating func record(before: AnnotationDocument, after: AnnotationDocument) {
    let beforeSnapshot = UndoSnapshot(document: before)
    let afterSnapshot = UndoSnapshot(document: after)
    guard beforeSnapshot != afterSnapshot else { return }

    undoStack.append(Entry(before: beforeSnapshot, after: afterSnapshot))
    if undoStack.count > limit {
      undoStack.removeFirst(undoStack.count - limit)
    }
    redoStack.removeAll()
  }

  public mutating func undo(document: inout AnnotationDocument) -> Bool {
    guard let entry = undoStack.popLast() else { return false }

    entry.before.apply(to: &document)
    redoStack.append(entry)
    return true
  }

  public mutating func redo(document: inout AnnotationDocument) -> Bool {
    guard let entry = redoStack.popLast() else { return false }

    entry.after.apply(to: &document)
    undoStack.append(entry)
    return true
  }
}
