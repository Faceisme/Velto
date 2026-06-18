import CoreGraphics
import Foundation

public struct AngleSnapState: Equatable, Sendable {
  public var directionIndex: Int?

  public init(directionIndex: Int? = nil) {
    self.directionIndex = directionIndex
  }
}

public enum AnnotationResizeHandle: CaseIterable, Sendable {
  case topLeft
  case top
  case topRight
  case right
  case bottomRight
  case bottom
  case bottomLeft
  case left
  case start
  case end
}

public enum AnnotationGeometry {
  private static let angleStep = CGFloat.pi / 4
  private static let angleHysteresis = 4 * CGFloat.pi / 180

  public static func constrainedEndpoint(
    anchor: CGPoint,
    cursor: CGPoint,
    shiftPressed: Bool,
    state: inout AngleSnapState
  ) -> CGPoint {
    guard shiftPressed else {
      state.directionIndex = nil
      return cursor
    }

    let dx = cursor.x - anchor.x
    let dy = cursor.y - anchor.y
    let radius = hypot(dx, dy)
    guard radius > 0 else { return anchor }

    let rawAngle = atan2(dy, dx)
    let nearestIndex = normalizedDirectionIndex(Int((rawAngle / angleStep).rounded()))
    if let activeIndex = state.directionIndex {
      let activeAngle = CGFloat(activeIndex) * angleStep
      let angularDistance = abs(atan2(
        sin(rawAngle - activeAngle),
        cos(rawAngle - activeAngle)
      ))
      if angularDistance > angleStep / 2 + angleHysteresis {
        state.directionIndex = nearestIndex
      }
    } else {
      state.directionIndex = nearestIndex
    }

    let directionIndex = state.directionIndex ?? nearestIndex
    switch directionIndex {
    case 0:
      return CGPoint(x: anchor.x + radius, y: anchor.y)
    case 2:
      return CGPoint(x: anchor.x, y: anchor.y + radius)
    case 4:
      return CGPoint(x: anchor.x - radius, y: anchor.y)
    case 6:
      return CGPoint(x: anchor.x, y: anchor.y - radius)
    case 1, 3, 5, 7:
      let angle = CGFloat(directionIndex) * angleStep
      return CGPoint(
        x: anchor.x + radius * cos(angle),
        y: anchor.y + radius * sin(angle)
      )
    default:
      return anchor
    }
  }

  public static func constrainedBox(
    anchor: CGPoint,
    cursor: CGPoint,
    shiftPressed: Bool,
    optionPressed: Bool
  ) -> CGRect {
    var dx = cursor.x - anchor.x
    var dy = cursor.y - anchor.y
    if shiftPressed {
      let side = max(abs(dx), abs(dy))
      dx = dx < 0 ? -side : side
      dy = dy < 0 ? -side : side
    }

    if optionPressed {
      return CGRect(
        x: anchor.x - abs(dx),
        y: anchor.y - abs(dy),
        width: abs(dx) * 2,
        height: abs(dy) * 2
      )
    }

    return CGRect(
      x: min(anchor.x, anchor.x + dx),
      y: min(anchor.y, anchor.y + dy),
      width: abs(dx),
      height: abs(dy)
    )
  }

  public static func point(radius: CGFloat, degrees: CGFloat) -> CGPoint {
    let angle = degrees * .pi / 180
    return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
  }

  public static func distance(
    from point: CGPoint,
    toSegmentFrom start: CGPoint,
    to end: CGPoint
  ) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else {
      return hypot(point.x - start.x, point.y - start.y)
    }

    let projection = (
      (point.x - start.x) * dx + (point.y - start.y) * dy
    ) / lengthSquared
    let clampedProjection = min(1, max(0, projection))
    let closest = CGPoint(
      x: start.x + clampedProjection * dx,
      y: start.y + clampedProjection * dy
    )
    return hypot(point.x - closest.x, point.y - closest.y)
  }

  public static func hitTest(
    _ point: CGPoint,
    elements: [AnnotationElement],
    minimumTolerance: CGFloat = 6
  ) -> UUID? {
    for element in elements.reversed() {
      let isHit: Bool
      switch element {
      case .rectangle(let value):
        let tolerance = strokeTolerance(
          style: value.style,
          minimumTolerance: minimumTolerance
        )
        isHit = rectangleContains(
          point,
          rect: value.rect,
          isFilled: value.style.fillOpacity > 0,
          tolerance: tolerance
        )
      case .ellipse(let value):
        let tolerance = strokeTolerance(
          style: value.style,
          minimumTolerance: minimumTolerance
        )
        isHit = ellipseContains(
          point,
          rect: value.rect,
          isFilled: value.style.fillOpacity > 0,
          tolerance: tolerance
        )
      case .line(let value), .arrow(let value):
        let tolerance = strokeTolerance(
          style: value.style,
          minimumTolerance: minimumTolerance
        )
        isHit = distance(
          from: point,
          toSegmentFrom: value.start,
          to: value.end
        ) <= tolerance
      case .freehand(let value), .highlight(let value):
        let tolerance = strokeTolerance(
          style: value.style,
          minimumTolerance: minimumTolerance
        )
        isHit = pathContains(point, points: value.points, tolerance: tolerance)
      case .mosaic(let value):
        isHit = value.rect.standardized.contains(point)
      case .text(let value):
        isHit = value.rect.standardized.contains(point)
      case .sequence:
        isHit = bounds(of: element).contains(point)
      }

      if isHit { return element.id }
    }
    return nil
  }

  public static func bounds(of element: AnnotationElement) -> CGRect {
    switch element {
    case .rectangle(let value), .ellipse(let value):
      return value.rect.standardized
    case .line(let value), .arrow(let value):
      return bounds(of: [value.start, value.end])
    case .freehand(let value), .highlight(let value):
      return bounds(of: value.points)
    case .mosaic(let value):
      return value.rect.standardized
    case .text(let value):
      return value.rect.standardized
    case .sequence(let value):
      let diameter = max(0, value.style.sequenceDiameter)
      return CGRect(
        x: value.center.x - diameter / 2,
        y: value.center.y - diameter / 2,
        width: diameter,
        height: diameter
      )
    }
  }

  public static func moved(
    _ element: AnnotationElement,
    by delta: CGPoint
  ) -> AnnotationElement {
    switch element {
    case .rectangle(var value):
      value.rect = value.rect.offsetBy(dx: delta.x, dy: delta.y)
      return .rectangle(value)
    case .ellipse(var value):
      value.rect = value.rect.offsetBy(dx: delta.x, dy: delta.y)
      return .ellipse(value)
    case .line(var value):
      value.start = offset(value.start, by: delta)
      value.end = offset(value.end, by: delta)
      return .line(value)
    case .arrow(var value):
      value.start = offset(value.start, by: delta)
      value.end = offset(value.end, by: delta)
      return .arrow(value)
    case .freehand(var value):
      value.points = value.points.map { offset($0, by: delta) }
      return .freehand(value)
    case .highlight(var value):
      value.points = value.points.map { offset($0, by: delta) }
      return .highlight(value)
    case .mosaic(var value):
      value.rect = value.rect.offsetBy(dx: delta.x, dy: delta.y)
      return .mosaic(value)
    case .text(var value):
      value.rect = value.rect.offsetBy(dx: delta.x, dy: delta.y)
      return .text(value)
    case .sequence(var value):
      value.center = offset(value.center, by: delta)
      return .sequence(value)
    }
  }

  public static func resized(
    _ element: AnnotationElement,
    handle: AnnotationResizeHandle,
    to point: CGPoint
  ) -> AnnotationElement {
    switch element {
    case .rectangle(var value):
      value.rect = resizedRect(value.rect, handle: handle, to: point)
      return .rectangle(value)
    case .ellipse(var value):
      value.rect = resizedRect(value.rect, handle: handle, to: point)
      return .ellipse(value)
    case .line(var value):
      resizeSegment(&value, handle: handle, to: point)
      return .line(value)
    case .arrow(var value):
      resizeSegment(&value, handle: handle, to: point)
      return .arrow(value)
    case .freehand(var value):
      value.points = resizedPoints(value.points, handle: handle, to: point)
      return .freehand(value)
    case .highlight(var value):
      value.points = resizedPoints(value.points, handle: handle, to: point)
      return .highlight(value)
    case .mosaic(var value):
      value.rect = resizedRect(value.rect, handle: handle, to: point)
      return .mosaic(value)
    case .text(var value):
      value.rect = resizedRect(value.rect, handle: handle, to: point)
      return .text(value)
    case .sequence(var value):
      resizeSequence(&value, handle: handle, to: point)
      return .sequence(value)
    }
  }

  public static func smoothedPath(
    points: [CGPoint],
    minimumDistance: CGFloat = 1.5
  ) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }

    let threshold = max(0, minimumDistance)
    var filtered = [first]
    if points.count > 2 {
      for point in points.dropFirst().dropLast() {
        guard let previous = filtered.last else { continue }
        if hypot(point.x - previous.x, point.y - previous.y) >= threshold {
          filtered.append(point)
        }
      }
    }
    if let last = points.last, last != filtered.last {
      filtered.append(last)
    }

    path.move(to: filtered[0])
    guard filtered.count > 1 else { return path }
    guard filtered.count > 2 else {
      path.addLine(to: filtered[1])
      return path
    }

    for index in 1..<(filtered.count - 1) {
      let point = filtered[index]
      let next = filtered[index + 1]
      path.addQuadCurve(
        to: midpoint(point, next),
        control: point
      )
    }
    path.addQuadCurve(
      to: filtered[filtered.count - 1],
      control: filtered[filtered.count - 2]
    )
    return path
  }

  private static func normalizedDirectionIndex(_ value: Int) -> Int {
    (value % 8 + 8) % 8
  }

  private static func strokeTolerance(
    style: AnnotationStyle,
    minimumTolerance: CGFloat
  ) -> CGFloat {
    max(max(6, minimumTolerance), style.lineWidth / 2 + 4)
  }

  private static func rectangleContains(
    _ point: CGPoint,
    rect: CGRect,
    isFilled: Bool,
    tolerance: CGFloat
  ) -> Bool {
    let rect = rect.standardized
    if isFilled, rect.contains(point) { return true }

    let corners = [
      CGPoint(x: rect.minX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.maxY),
      CGPoint(x: rect.minX, y: rect.maxY),
    ]
    for index in corners.indices {
      let nextIndex = (index + 1) % corners.count
      if distance(
        from: point,
        toSegmentFrom: corners[index],
        to: corners[nextIndex]
      ) <= tolerance {
        return true
      }
    }
    return false
  }

  private static func ellipseContains(
    _ point: CGPoint,
    rect: CGRect,
    isFilled: Bool,
    tolerance: CGFloat
  ) -> Bool {
    let rect = rect.standardized
    let radiusX = rect.width / 2
    let radiusY = rect.height / 2
    guard radiusX > 0, radiusY > 0 else {
      return rectangleContains(
        point,
        rect: rect,
        isFilled: isFilled,
        tolerance: tolerance
      )
    }

    let ellipsePath = CGPath(ellipseIn: rect, transform: nil)
    if isFilled, ellipsePath.contains(point) { return true }

    let strokedPath = ellipsePath.copy(
      strokingWithWidth: tolerance * 2,
      lineCap: .round,
      lineJoin: .round,
      miterLimit: 10
    )
    return strokedPath.contains(point)
  }

  private static func pathContains(
    _ point: CGPoint,
    points: [CGPoint],
    tolerance: CGFloat
  ) -> Bool {
    guard let first = points.first else { return false }
    guard points.count > 1 else {
      return hypot(point.x - first.x, point.y - first.y) <= tolerance
    }

    for index in 1..<points.count {
      if distance(
        from: point,
        toSegmentFrom: points[index - 1],
        to: points[index]
      ) <= tolerance {
        return true
      }
    }
    return false
  }

  private static func bounds(of points: [CGPoint]) -> CGRect {
    guard let first = points.first else { return .zero }
    var minX = first.x
    var maxX = first.x
    var minY = first.y
    var maxY = first.y
    for point in points.dropFirst() {
      minX = min(minX, point.x)
      maxX = max(maxX, point.x)
      minY = min(minY, point.y)
      maxY = max(maxY, point.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  private static func offset(_ point: CGPoint, by delta: CGPoint) -> CGPoint {
    CGPoint(x: point.x + delta.x, y: point.y + delta.y)
  }

  private static func resizedRect(
    _ rect: CGRect,
    handle: AnnotationResizeHandle,
    to point: CGPoint
  ) -> CGRect {
    let edges = resizedEdges(rect, handle: handle, to: point)
    return CGRect(
      x: min(edges.startX, edges.endX),
      y: min(edges.startY, edges.endY),
      width: abs(edges.endX - edges.startX),
      height: abs(edges.endY - edges.startY)
    )
  }

  private static func resizedEdges(
    _ rect: CGRect,
    handle: AnnotationResizeHandle,
    to point: CGPoint
  ) -> (startX: CGFloat, endX: CGFloat, startY: CGFloat, endY: CGFloat) {
    let rect = rect.standardized
    var startX = rect.minX
    var endX = rect.maxX
    var startY = rect.minY
    var endY = rect.maxY

    switch handle {
    case .topLeft:
      startX = point.x
      endY = point.y
    case .top:
      endY = point.y
    case .topRight:
      endX = point.x
      endY = point.y
    case .right:
      endX = point.x
    case .bottomRight:
      endX = point.x
      startY = point.y
    case .bottom:
      startY = point.y
    case .bottomLeft:
      startX = point.x
      startY = point.y
    case .left:
      startX = point.x
    case .start, .end:
      break
    }

    return (startX, endX, startY, endY)
  }

  private static func resizeSegment(
    _ value: inout SegmentAnnotation,
    handle: AnnotationResizeHandle,
    to point: CGPoint
  ) {
    switch handle {
    case .start:
      value.start = point
    case .end:
      value.end = point
    case .topLeft, .top, .topRight, .right, .bottomRight, .bottom,
         .bottomLeft, .left:
      break
    }
  }

  private static func resizedPoints(
    _ points: [CGPoint],
    handle: AnnotationResizeHandle,
    to point: CGPoint
  ) -> [CGPoint] {
    guard !points.isEmpty else { return points }
    switch handle {
    case .start, .end:
      return points
    case .topLeft, .top, .topRight, .right, .bottomRight, .bottom,
         .bottomLeft, .left:
      break
    }

    let oldBounds = bounds(of: points)
    let edges = resizedEdges(oldBounds, handle: handle, to: point)
    return points.map { point in
      CGPoint(
        x: mappedCoordinate(
          point.x,
          oldMinimum: oldBounds.minX,
          oldLength: oldBounds.width,
          targetStart: edges.startX,
          targetLength: edges.endX - edges.startX
        ),
        y: mappedCoordinate(
          point.y,
          oldMinimum: oldBounds.minY,
          oldLength: oldBounds.height,
          targetStart: edges.startY,
          targetLength: edges.endY - edges.startY
        )
      )
    }
  }

  private static func mappedCoordinate(
    _ coordinate: CGFloat,
    oldMinimum: CGFloat,
    oldLength: CGFloat,
    targetStart: CGFloat,
    targetLength: CGFloat
  ) -> CGFloat {
    guard oldLength > 0 else { return targetStart + targetLength / 2 }
    return targetStart + (coordinate - oldMinimum) / oldLength * targetLength
  }

  private static func resizeSequence(
    _ value: inout SequenceAnnotation,
    handle: AnnotationResizeHandle,
    to point: CGPoint
  ) {
    let rect = bounds(of: .sequence(value))
    let diameter: CGFloat
    let center: CGPoint

    switch handle {
    case .left:
      diameter = abs(point.x - rect.maxX)
      center = CGPoint(x: (point.x + rect.maxX) / 2, y: value.center.y)
    case .right:
      diameter = abs(point.x - rect.minX)
      center = CGPoint(x: (point.x + rect.minX) / 2, y: value.center.y)
    case .top:
      diameter = abs(point.y - rect.minY)
      center = CGPoint(x: value.center.x, y: (point.y + rect.minY) / 2)
    case .bottom:
      diameter = abs(point.y - rect.maxY)
      center = CGPoint(x: value.center.x, y: (point.y + rect.maxY) / 2)
    case .topLeft:
      (center, diameter) = resizedSequenceCorner(
        fixed: CGPoint(x: rect.maxX, y: rect.minY),
        moving: point,
        fallbackX: -1,
        fallbackY: 1
      )
    case .topRight:
      (center, diameter) = resizedSequenceCorner(
        fixed: CGPoint(x: rect.minX, y: rect.minY),
        moving: point,
        fallbackX: 1,
        fallbackY: 1
      )
    case .bottomRight:
      (center, diameter) = resizedSequenceCorner(
        fixed: CGPoint(x: rect.minX, y: rect.maxY),
        moving: point,
        fallbackX: 1,
        fallbackY: -1
      )
    case .bottomLeft:
      (center, diameter) = resizedSequenceCorner(
        fixed: CGPoint(x: rect.maxX, y: rect.maxY),
        moving: point,
        fallbackX: -1,
        fallbackY: -1
      )
    case .start, .end:
      return
    }

    value.center = center
    value.style.sequenceDiameter = max(0, diameter)
  }

  private static func resizedSequenceCorner(
    fixed: CGPoint,
    moving: CGPoint,
    fallbackX: CGFloat,
    fallbackY: CGFloat
  ) -> (center: CGPoint, diameter: CGFloat) {
    let dx = moving.x - fixed.x
    let dy = moving.y - fixed.y
    let diameter = max(abs(dx), abs(dy))
    let directionX = dx == 0 ? fallbackX : (dx < 0 ? -1 : 1)
    let directionY = dy == 0 ? fallbackY : (dy < 0 ? -1 : 1)
    return (
      CGPoint(
        x: fixed.x + directionX * diameter / 2,
        y: fixed.y + directionY * diameter / 2
      ),
      diameter
    )
  }

  private static func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
    CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
  }
}
