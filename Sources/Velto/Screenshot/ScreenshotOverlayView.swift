import AppKit

final class ScreenshotOverlayView: NSView {
  weak var delegate: ScreenshotOverlayDelegate?
  var snapshotImage: CGImage? { didSet { needsDisplay = true } }
  var dimAlpha: CGFloat = 0.35

  override var acceptsFirstResponder: Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    if let img = snapshotImage { ctx.draw(img, in: bounds) }
    ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
    ctx.fill(bounds)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { delegate?.overlayDidCancel(); return }  // Esc
    super.keyDown(with: event)
  }
}
