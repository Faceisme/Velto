import CoreGraphics
import Foundation

public struct AnnotationModifiers: OptionSet, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let shift = AnnotationModifiers(rawValue: 1 << 0)
  public static let option = AnnotationModifiers(rawValue: 1 << 1)
}

public enum AnnotationCancelResult: Equatable, Sendable {
  case cancelledGesture
  case deselectedObject
  case deactivatedTool
  case cancelSession
}

public struct AnnotationEditor: Sendable {
  public private(set) var document: AnnotationDocument
  public private(set) var history = AnnotationHistory(limit: 100)
  public var style: AnnotationStyle

  /// Minimum committed size for a dragged object; smaller drags are discarded.
  public static let minimumObjectSize: CGFloat = 2
  /// Minimum width/height the crop rect is allowed to clamp to.
  public static let minimumCropSize: CGFloat = 16
  /// How close a pointer must be to a handle to grab it during selection drags.
  public static let handleTolerance: CGFloat = 8

  private enum BoxKind: Sendable {
    case rectangle
    case ellipse
  }

  private enum SegmentKind: Sendable {
    case line
    case arrow
  }

  private enum PathKind: Sendable {
    case freehand
    case highlight
  }

  private enum ActiveGesture: Sendable {
    case none
    case box(id: UUID, kind: BoxKind)
    case segment(id: UUID, kind: SegmentKind)
    case path(id: UUID, kind: PathKind)
    case mosaic(id: UUID)
    case sequence(id: UUID)
    case move(id: UUID, lastPoint: CGPoint)
    case resize(id: UUID, handle: AnnotationResizeHandle)
    case crop
  }

  private var gesture: ActiveGesture = .none
  private var gestureAnchor: CGPoint = .zero
  private var gestureBefore: AnnotationDocument?
  private var angleSnapState = AngleSnapState()
  private var editingTextID: UUID?

  public init(canvasSize: CGSize, style: AnnotationStyle = .defaults) {
    document = AnnotationDocument(canvasSize: canvasSize)
    self.style = style
  }

  // MARK: - Tool & selection

  public mutating func selectTool(_ tool: AnnotationTool?) {
    cancelGesture()
    document.activeTool = tool
    document.selectedElementID = nil
  }

  public mutating func select(elementID: UUID?) {
    guard let elementID else {
      document.selectedElementID = nil
      return
    }
    guard document.elements.contains(where: { $0.id == elementID }) else {
      document.selectedElementID = nil
      return
    }
    document.selectedElementID = elementID
  }

  // MARK: - Pointer gestures

  public mutating func pointerDown(at point: CGPoint, modifiers: AnnotationModifiers) {
    cancelGesture()
    gestureBefore = document
    gestureAnchor = point
    angleSnapState = AngleSnapState()

    switch document.activeTool {
    case .rectangle:
      beginBox(.rectangle, at: point)
    case .ellipse:
      beginBox(.ellipse, at: point)
    case .line:
      beginSegment(.line, at: point)
    case .arrow:
      beginSegment(.arrow, at: point)
    case .pen:
      beginPath(.freehand, at: point)
    case .highlight:
      beginPath(.highlight, at: point)
    case .mosaic:
      beginMosaic(at: point)
    case .sequence:
      beginSequence(at: point)
    case .crop:
      gesture = .crop
    case .text:
      gesture = .none
    case nil:
      beginSelectionOrMove(at: point)
    }
  }

  public mutating func pointerDragged(to point: CGPoint, modifiers: AnnotationModifiers) {
    switch gesture {
    case .none:
      break
    case .box(let id, _):
      updateBox(id: id, to: point, modifiers: modifiers)
    case .segment(let id, _):
      updateSegment(id: id, to: point, modifiers: modifiers)
    case .path(let id, _):
      appendPathPoint(id: id, point: point)
    case .mosaic(let id):
      updateMosaic(id: id, to: point, modifiers: modifiers)
    case .sequence:
      break
    case .move(let id, let lastPoint):
      moveElement(id: id, from: lastPoint, to: point)
      gesture = .move(id: id, lastPoint: point)
    case .resize(let id, let handle):
      resizeElement(id: id, handle: handle, to: point)
    case .crop:
      updateCropPreview(to: point, modifiers: modifiers)
    }
  }

  public mutating func pointerUp(at point: CGPoint, modifiers: AnnotationModifiers) {
    defer { finishGesture() }
    switch gesture {
    case .none:
      return
    case .box(let id, _):
      updateBox(id: id, to: point, modifiers: modifiers)
      finalizeCreation(id: id, discardWhen: boxOrMosaicTooSmall(id: id))
    case .segment(let id, _):
      updateSegment(id: id, to: point, modifiers: modifiers)
      finalizeCreation(id: id, discardWhen: segmentTooShort(id: id))
    case .path(let id, _):
      appendPathPoint(id: id, point: point)
      finalizeCreation(id: id, discardWhen: pathTooShort(id: id))
    case .mosaic(let id):
      updateMosaic(id: id, to: point, modifiers: modifiers)
      finalizeCreation(id: id, discardWhen: boxOrMosaicTooSmall(id: id))
    case .sequence(let id):
      finalizeCreation(id: id, discardWhen: false)
    case .move(let id, let lastPoint):
      moveElement(id: id, from: lastPoint, to: point)
      recordGestureHistory()
    case .resize(let id, let handle):
      resizeElement(id: id, handle: handle, to: point)
      recordGestureHistory()
    case .crop:
      updateCropPreview(to: point, modifiers: modifiers)
      document.cropRect = clampedCrop(document.cropRect)
      recordGestureHistory()
    }
  }

  public mutating func click(at point: CGPoint) {
    pointerDown(at: point, modifiers: [])
    pointerUp(at: point, modifiers: [])
  }

  // MARK: - Text

  public mutating func beginEditingText(elementID: UUID) -> TextAnnotation? {
    guard let element = document.elements.first(where: { $0.id == elementID }),
          case .text(let text) = element else {
      return nil
    }
    editingTextID = elementID
    return text
  }

  public mutating func commitText(_ text: String, rect: CGRect) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let before = document

    if let editingID = editingTextID {
      editingTextID = nil
      if trimmed.isEmpty {
        document.elements.removeAll { $0.id == editingID }
        if document.selectedElementID == editingID {
          document.selectedElementID = nil
        }
      } else if let index = document.elements.firstIndex(where: { $0.id == editingID }),
                case .text(var value) = document.elements[index] {
        value.text = text
        value.rect = rect
        value.style = style
        document.elements[index] = .text(value)
        document.selectedElementID = editingID
      }
    } else {
      guard !trimmed.isEmpty else { return }
      let element = TextAnnotation(rect: rect, text: text, style: style)
      document.elements.append(.text(element))
      document.selectedElementID = element.id
    }

    history.record(before: before, after: document)
  }

  // MARK: - Crop / edit operations

  public mutating func updateCrop(_ rect: CGRect) {
    let before = document
    document.cropRect = clampedCrop(rect)
    history.record(before: before, after: document)
  }

  public mutating func deleteSelection() {
    guard let selected = document.selectedElementID else { return }
    let before = document
    document.elements.removeAll { $0.id == selected }
    document.selectedElementID = nil
    history.record(before: before, after: document)
  }

  public mutating func nudge(dx: CGFloat, dy: CGFloat, accelerated: Bool) {
    guard let selected = document.selectedElementID,
          let index = document.elements.firstIndex(where: { $0.id == selected }) else {
      return
    }
    let factor: CGFloat = accelerated ? 10 : 1
    let before = document
    document.elements[index] = AnnotationGeometry.moved(
      document.elements[index],
      by: CGPoint(x: dx * factor, y: dy * factor)
    )
    history.record(before: before, after: document)
  }

  public mutating func applyStyle(_ newStyle: AnnotationStyle) {
    style = newStyle
    guard let selected = document.selectedElementID,
          let index = document.elements.firstIndex(where: { $0.id == selected }) else {
      return
    }
    let before = document
    document.elements[index] = restyled(document.elements[index], with: newStyle)
    history.record(before: before, after: document)
  }

  // MARK: - History

  @discardableResult
  public mutating func undo() -> Bool {
    cancelGesture()
    return history.undo(document: &document)
  }

  @discardableResult
  public mutating func redo() -> Bool {
    cancelGesture()
    return history.redo(document: &document)
  }

  public var canUndo: Bool { history.undoCount > 0 }
  public var canRedo: Bool { history.redoCount > 0 }

  // MARK: - Layered cancel

  public mutating func cancelCurrentLayer() -> AnnotationCancelResult {
    if isGestureActive {
      cancelGesture()
      return .cancelledGesture
    }
    if document.selectedElementID != nil {
      document.selectedElementID = nil
      return .deselectedObject
    }
    if document.activeTool != nil {
      document.activeTool = nil
      return .deactivatedTool
    }
    return .cancelSession
  }

  // MARK: - Creation helpers

  private mutating func beginBox(_ kind: BoxKind, at anchor: CGPoint) {
    let box = BoxAnnotation(rect: CGRect(origin: anchor, size: .zero), style: style)
    document.elements.append(kind == .rectangle ? .rectangle(box) : .ellipse(box))
    gesture = .box(id: box.id, kind: kind)
  }

  private mutating func updateBox(id: UUID, to point: CGPoint, modifiers: AnnotationModifiers) {
    guard let index = document.elements.firstIndex(where: { $0.id == id }) else { return }
    let rect = AnnotationGeometry.constrainedBox(
      anchor: gestureAnchor,
      cursor: point,
      shiftPressed: modifiers.contains(.shift),
      optionPressed: modifiers.contains(.option)
    )
    switch document.elements[index] {
    case .rectangle(var value):
      value.rect = rect
      document.elements[index] = .rectangle(value)
    case .ellipse(var value):
      value.rect = rect
      document.elements[index] = .ellipse(value)
    default:
      break
    }
  }

  private mutating func beginSegment(_ kind: SegmentKind, at anchor: CGPoint) {
    let segment = SegmentAnnotation(start: anchor, end: anchor, style: style)
    document.elements.append(kind == .line ? .line(segment) : .arrow(segment))
    gesture = .segment(id: segment.id, kind: kind)
  }

  private mutating func updateSegment(id: UUID, to point: CGPoint, modifiers: AnnotationModifiers) {
    guard let index = document.elements.firstIndex(where: { $0.id == id }) else { return }
    let end = AnnotationGeometry.constrainedEndpoint(
      anchor: gestureAnchor,
      cursor: point,
      shiftPressed: modifiers.contains(.shift),
      state: &angleSnapState
    )
    switch document.elements[index] {
    case .line(var value):
      value.end = end
      document.elements[index] = .line(value)
    case .arrow(var value):
      value.end = end
      document.elements[index] = .arrow(value)
    default:
      break
    }
  }

  private mutating func beginPath(_ kind: PathKind, at anchor: CGPoint) {
    let path = PathAnnotation(points: [anchor], style: style)
    document.elements.append(kind == .freehand ? .freehand(path) : .highlight(path))
    gesture = .path(id: path.id, kind: kind)
  }

  private mutating func appendPathPoint(id: UUID, point: CGPoint) {
    guard let index = document.elements.firstIndex(where: { $0.id == id }) else { return }
    switch document.elements[index] {
    case .freehand(var value):
      if value.points.last != point { value.points.append(point) }
      document.elements[index] = .freehand(value)
    case .highlight(var value):
      if value.points.last != point { value.points.append(point) }
      document.elements[index] = .highlight(value)
    default:
      break
    }
  }

  private mutating func beginMosaic(at anchor: CGPoint) {
    let mosaic = MosaicAnnotation(
      rect: CGRect(origin: anchor, size: .zero),
      blockSize: style.mosaicBlockSize
    )
    document.elements.append(.mosaic(mosaic))
    gesture = .mosaic(id: mosaic.id)
  }

  private mutating func updateMosaic(id: UUID, to point: CGPoint, modifiers: AnnotationModifiers) {
    guard let index = document.elements.firstIndex(where: { $0.id == id }),
          case .mosaic(var value) = document.elements[index] else {
      return
    }
    value.rect = AnnotationGeometry.constrainedBox(
      anchor: gestureAnchor,
      cursor: point,
      shiftPressed: modifiers.contains(.shift),
      optionPressed: modifiers.contains(.option)
    )
    document.elements[index] = .mosaic(value)
  }

  private mutating func beginSequence(at point: CGPoint) {
    let sequence = SequenceAnnotation(
      center: point,
      number: document.nextSequenceNumber,
      style: style
    )
    document.elements.append(.sequence(sequence))
    document.nextSequenceNumber += 1
    gesture = .sequence(id: sequence.id)
  }

  private mutating func updateCropPreview(to point: CGPoint, modifiers: AnnotationModifiers) {
    let rect = AnnotationGeometry.constrainedBox(
      anchor: gestureAnchor,
      cursor: point,
      shiftPressed: modifiers.contains(.shift),
      optionPressed: modifiers.contains(.option)
    )
    document.cropRect = rect.intersection(CGRect(origin: .zero, size: document.canvasSize))
  }

  // MARK: - Selection / move / resize

  private mutating func beginSelectionOrMove(at point: CGPoint) {
    if let selected = document.selectedElementID,
       let element = document.elements.first(where: { $0.id == selected }) {
      if let handle = handle(at: point, for: element) {
        gesture = .resize(id: selected, handle: handle)
        return
      }
      // An already-selected object can be dragged from anywhere inside its frame,
      // even when it is only outlined.
      if selectionGrabContains(point, element) {
        gesture = .move(id: selected, lastPoint: point)
        return
      }
    }
    guard let hitID = AnnotationGeometry.hitTest(point, elements: document.elements) else {
      document.selectedElementID = nil
      gesture = .none
      return
    }
    document.selectedElementID = hitID
    gesture = .move(id: hitID, lastPoint: point)
  }

  private func selectionGrabContains(_ point: CGPoint, _ element: AnnotationElement) -> Bool {
    let frame = AnnotationGeometry.bounds(of: element)
      .insetBy(dx: -Self.handleTolerance / 2, dy: -Self.handleTolerance / 2)
    return frame.contains(point)
  }

  private mutating func moveElement(id: UUID, from lastPoint: CGPoint, to point: CGPoint) {
    guard let index = document.elements.firstIndex(where: { $0.id == id }) else { return }
    document.elements[index] = AnnotationGeometry.moved(
      document.elements[index],
      by: CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y)
    )
  }

  private mutating func resizeElement(id: UUID, handle: AnnotationResizeHandle, to point: CGPoint) {
    guard let index = document.elements.firstIndex(where: { $0.id == id }) else { return }
    document.elements[index] = AnnotationGeometry.resized(
      document.elements[index],
      handle: handle,
      to: point
    )
  }

  /// Returns the resize handle near `point` for the given element, if any.
  public func handle(at point: CGPoint, for element: AnnotationElement) -> AnnotationResizeHandle? {
    switch element {
    case .line(let value), .arrow(let value):
      if hypot(point.x - value.start.x, point.y - value.start.y) <= Self.handleTolerance {
        return .start
      }
      if hypot(point.x - value.end.x, point.y - value.end.y) <= Self.handleTolerance {
        return .end
      }
      return nil
    default:
      let bounds = AnnotationGeometry.bounds(of: element)
      let candidates: [(AnnotationResizeHandle, CGPoint)] = [
        (.topLeft, CGPoint(x: bounds.minX, y: bounds.minY)),
        (.top, CGPoint(x: bounds.midX, y: bounds.minY)),
        (.topRight, CGPoint(x: bounds.maxX, y: bounds.minY)),
        (.right, CGPoint(x: bounds.maxX, y: bounds.midY)),
        (.bottomRight, CGPoint(x: bounds.maxX, y: bounds.maxY)),
        (.bottom, CGPoint(x: bounds.midX, y: bounds.maxY)),
        (.bottomLeft, CGPoint(x: bounds.minX, y: bounds.maxY)),
        (.left, CGPoint(x: bounds.minX, y: bounds.midY)),
      ]
      var best: (handle: AnnotationResizeHandle, distance: CGFloat)?
      for (handle, anchor) in candidates {
        let distance = hypot(point.x - anchor.x, point.y - anchor.y)
        guard distance <= Self.handleTolerance else { continue }
        if best == nil || distance < best!.distance {
          best = (handle, distance)
        }
      }
      return best?.handle
    }
  }

  // MARK: - Gesture lifecycle

  private var isGestureActive: Bool {
    if case .none = gesture { return false }
    return true
  }

  private mutating func finalizeCreation(id: UUID, discardWhen shouldDiscard: Bool) {
    if shouldDiscard {
      document.elements.removeAll { $0.id == id }
      document.selectedElementID = nil
    } else {
      document.selectedElementID = id
    }
    recordGestureHistory()
  }

  private mutating func recordGestureHistory() {
    guard let before = gestureBefore else { return }
    history.record(before: before, after: document)
  }

  private mutating func finishGesture() {
    gesture = .none
    gestureBefore = nil
    angleSnapState = AngleSnapState()
  }

  private mutating func cancelGesture() {
    guard isGestureActive else {
      gestureBefore = nil
      return
    }
    if let before = gestureBefore {
      document = before
    }
    finishGesture()
  }

  // MARK: - Discard thresholds

  private func boxOrMosaicTooSmall(id: UUID) -> Bool {
    guard let element = document.elements.first(where: { $0.id == id }) else { return true }
    let bounds = AnnotationGeometry.bounds(of: element)
    return max(bounds.width, bounds.height) < Self.minimumObjectSize
  }

  private func segmentTooShort(id: UUID) -> Bool {
    guard let element = document.elements.first(where: { $0.id == id }) else { return true }
    switch element {
    case .line(let value), .arrow(let value):
      return hypot(value.end.x - value.start.x, value.end.y - value.start.y) < Self.minimumObjectSize
    default:
      return true
    }
  }

  private func pathTooShort(id: UUID) -> Bool {
    guard let element = document.elements.first(where: { $0.id == id }) else { return true }
    switch element {
    case .freehand(let value), .highlight(let value):
      guard value.points.count >= 2 else { return true }
      let bounds = AnnotationGeometry.bounds(of: element)
      return max(bounds.width, bounds.height) < Self.minimumObjectSize
    default:
      return true
    }
  }

  // MARK: - Crop clamping

  private func clampedCrop(_ rect: CGRect) -> CGRect {
    let canvas = CGRect(origin: .zero, size: document.canvasSize)
    var result = rect.standardized
    let minWidth = min(Self.minimumCropSize, canvas.width)
    let minHeight = min(Self.minimumCropSize, canvas.height)
    result.size.width = max(result.size.width, minWidth)
    result.size.height = max(result.size.height, minHeight)

    if result.maxX > canvas.maxX {
      result.origin.x = canvas.maxX - result.size.width
    }
    if result.maxY > canvas.maxY {
      result.origin.y = canvas.maxY - result.size.height
    }
    result.origin.x = max(canvas.minX, result.origin.x)
    result.origin.y = max(canvas.minY, result.origin.y)
    return result
  }

  // MARK: - Restyle

  private func restyled(
    _ element: AnnotationElement,
    with style: AnnotationStyle
  ) -> AnnotationElement {
    switch element {
    case .rectangle(var value):
      value.style = style
      return .rectangle(value)
    case .ellipse(var value):
      value.style = style
      return .ellipse(value)
    case .line(var value):
      value.style = style
      return .line(value)
    case .arrow(var value):
      value.style = style
      return .arrow(value)
    case .freehand(var value):
      value.style = style
      return .freehand(value)
    case .highlight(var value):
      value.style = style
      return .highlight(value)
    case .mosaic(var value):
      value.blockSize = style.mosaicBlockSize
      return .mosaic(value)
    case .text(var value):
      value.style = style
      return .text(value)
    case .sequence(var value):
      value.style = style
      return .sequence(value)
    }
  }
}
