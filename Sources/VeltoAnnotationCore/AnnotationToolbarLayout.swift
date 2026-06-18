import CoreGraphics

public struct AnnotationToolbarPlacement: Equatable, Sendable {
  public var mainFrame: CGRect
  public var propertyFrame: CGRect

  public init(mainFrame: CGRect, propertyFrame: CGRect) {
    self.mainFrame = mainFrame
    self.propertyFrame = propertyFrame
  }
}

/// Positions the main toolbar and property bar around a selection in screen
/// coordinates (y increases upward). The bars sit below the selection by default
/// and flip above when the stack would not fit; the horizontal position is centered
/// on the selection and clamped into the screen without shrinking the controls.
public enum AnnotationToolbarLayout {
  public static func place(
    selection: CGRect,
    screenBounds: CGRect,
    mainSize: CGSize,
    propertySize: CGSize,
    selectionGap: CGFloat = 10,
    barGap: CGFloat = 6
  ) -> AnnotationToolbarPlacement {
    let selection = selection.standardized
    let mainX = clampedX(width: mainSize.width, around: selection.midX, in: screenBounds)
    let propertyX = clampedX(width: propertySize.width, around: selection.midX, in: screenBounds)

    let below = belowLayout(
      selection: selection,
      mainSize: mainSize,
      propertySize: propertySize,
      mainX: mainX,
      propertyX: propertyX,
      selectionGap: selectionGap,
      barGap: barGap
    )
    let above = aboveLayout(
      selection: selection,
      mainSize: mainSize,
      propertySize: propertySize,
      mainX: mainX,
      propertyX: propertyX,
      selectionGap: selectionGap,
      barGap: barGap
    )

    let chosen: AnnotationToolbarPlacement
    if fits(below, in: screenBounds) {
      chosen = below
    } else if fits(above, in: screenBounds) {
      chosen = above
    } else {
      chosen = below
    }
    return clampVertically(chosen, in: screenBounds)
  }

  private static func belowLayout(
    selection: CGRect,
    mainSize: CGSize,
    propertySize: CGSize,
    mainX: CGFloat,
    propertyX: CGFloat,
    selectionGap: CGFloat,
    barGap: CGFloat
  ) -> AnnotationToolbarPlacement {
    // Main toolbar adjacent to the selection's lower edge, property bar below it.
    let mainMinY = selection.minY - selectionGap - mainSize.height
    let propertyMinY = mainMinY - barGap - propertySize.height
    return AnnotationToolbarPlacement(
      mainFrame: CGRect(x: mainX, y: mainMinY, width: mainSize.width, height: mainSize.height),
      propertyFrame: CGRect(
        x: propertyX, y: propertyMinY, width: propertySize.width, height: propertySize.height
      )
    )
  }

  private static func aboveLayout(
    selection: CGRect,
    mainSize: CGSize,
    propertySize: CGSize,
    mainX: CGFloat,
    propertyX: CGFloat,
    selectionGap: CGFloat,
    barGap: CGFloat
  ) -> AnnotationToolbarPlacement {
    // Main toolbar adjacent to the selection's upper edge, property bar above it.
    let mainMinY = selection.maxY + selectionGap
    let propertyMinY = mainMinY + mainSize.height + barGap
    return AnnotationToolbarPlacement(
      mainFrame: CGRect(x: mainX, y: mainMinY, width: mainSize.width, height: mainSize.height),
      propertyFrame: CGRect(
        x: propertyX, y: propertyMinY, width: propertySize.width, height: propertySize.height
      )
    )
  }

  private static func clampedX(
    width: CGFloat,
    around centerX: CGFloat,
    in bounds: CGRect
  ) -> CGFloat {
    var x = centerX - width / 2
    if width <= bounds.width {
      x = min(x, bounds.maxX - width)
      x = max(x, bounds.minX)
    } else {
      // Wider than the screen: center it and let it overflow symmetrically.
      x = bounds.midX - width / 2
    }
    return x
  }

  private static func fits(_ placement: AnnotationToolbarPlacement, in bounds: CGRect) -> Bool {
    let union = placement.mainFrame.union(placement.propertyFrame)
    return union.minY >= bounds.minY && union.maxY <= bounds.maxY
  }

  private static func clampVertically(
    _ placement: AnnotationToolbarPlacement,
    in bounds: CGRect
  ) -> AnnotationToolbarPlacement {
    let union = placement.mainFrame.union(placement.propertyFrame)
    var dy: CGFloat = 0
    if union.maxY > bounds.maxY {
      dy = bounds.maxY - union.maxY
    }
    if union.minY + dy < bounds.minY {
      dy = bounds.minY - union.minY
    }
    guard dy != 0 else { return placement }
    return AnnotationToolbarPlacement(
      mainFrame: placement.mainFrame.offsetBy(dx: 0, dy: dy),
      propertyFrame: placement.propertyFrame.offsetBy(dx: 0, dy: dy)
    )
  }
}
