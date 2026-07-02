import CoreGraphics

public enum ScrollCaptureActionBarLayout {
  public static func place(
    selection: CGRect,
    screenBounds: CGRect,
    barSize: CGSize,
    gap: CGFloat = 8
  ) -> CGRect {
    let selection = selection.standardized
    let candidates = [
      outsideRightBottom(selection: selection, size: barSize, gap: gap),
      outsideLeftBottom(selection: selection, size: barSize, gap: gap),
      outsideRightTop(selection: selection, size: barSize, gap: gap),
      outsideLeftTop(selection: selection, size: barSize, gap: gap),
      outsideBottomRight(selection: selection, size: barSize, gap: gap),
      outsideTopRight(selection: selection, size: barSize, gap: gap),
      insideBottomRight(selection: selection, size: barSize, gap: gap),
      insideTopRight(selection: selection, size: barSize, gap: gap),
      insideBottomLeft(selection: selection, size: barSize, gap: gap),
      insideTopLeft(selection: selection, size: barSize, gap: gap),
    ]

    if let frame = candidates.first(where: { screenBounds.contains($0) }) {
      return frame
    }
    return clamp(outsideRightBottom(selection: selection, size: barSize, gap: gap), in: screenBounds)
  }

  private static func outsideRightBottom(selection: CGRect, size: CGSize, gap: CGFloat) -> CGRect {
    CGRect(
      x: selection.maxX + gap,
      y: selection.minY,
      width: size.width,
      height: size.height
    )
  }

  private static func outsideLeftBottom(selection: CGRect, size: CGSize, gap: CGFloat) -> CGRect {
    CGRect(
      x: selection.minX - gap - size.width,
      y: selection.minY,
      width: size.width,
      height: size.height
    )
  }

  private static func outsideRightTop(selection: CGRect, size: CGSize, gap: CGFloat) -> CGRect {
    CGRect(
      x: selection.maxX + gap,
      y: selection.maxY - size.height,
      width: size.width,
      height: size.height
    )
  }

  private static func outsideLeftTop(selection: CGRect, size: CGSize, gap: CGFloat) -> CGRect {
    CGRect(
      x: selection.minX - gap - size.width,
      y: selection.maxY - size.height,
      width: size.width,
      height: size.height
    )
  }

  private static func outsideBottomRight(selection: CGRect, size: CGSize, gap: CGFloat) -> CGRect {
    CGRect(
      x: selection.maxX - size.width,
      y: selection.minY - gap - size.height,
      width: size.width,
      height: size.height
    )
  }

  private static func outsideTopRight(selection: CGRect, size: CGSize, gap: CGFloat) -> CGRect {
    CGRect(
      x: selection.maxX - size.width,
      y: selection.maxY + gap,
      width: size.width,
      height: size.height
    )
  }

  private static func insideBottomRight(selection: CGRect, size: CGSize, gap: CGFloat) -> CGRect {
    CGRect(
      x: selection.maxX - gap - size.width,
      y: selection.minY + gap,
      width: size.width,
      height: size.height
    )
  }

  private static func insideTopRight(selection: CGRect, size: CGSize, gap: CGFloat) -> CGRect {
    CGRect(
      x: selection.maxX - gap - size.width,
      y: selection.maxY - gap - size.height,
      width: size.width,
      height: size.height
    )
  }

  private static func insideBottomLeft(selection: CGRect, size: CGSize, gap: CGFloat) -> CGRect {
    CGRect(
      x: selection.minX + gap,
      y: selection.minY + gap,
      width: size.width,
      height: size.height
    )
  }

  private static func insideTopLeft(selection: CGRect, size: CGSize, gap: CGFloat) -> CGRect {
    CGRect(
      x: selection.minX + gap,
      y: selection.maxY - gap - size.height,
      width: size.width,
      height: size.height
    )
  }

  private static func clamp(_ frame: CGRect, in bounds: CGRect) -> CGRect {
    guard frame.width <= bounds.width, frame.height <= bounds.height else {
      return CGRect(
        x: bounds.midX - frame.width / 2,
        y: bounds.midY - frame.height / 2,
        width: frame.width,
        height: frame.height
      )
    }
    return CGRect(
      x: min(max(frame.minX, bounds.minX), bounds.maxX - frame.width),
      y: min(max(frame.minY, bounds.minY), bounds.maxY - frame.height),
      width: frame.width,
      height: frame.height
    )
  }
}
