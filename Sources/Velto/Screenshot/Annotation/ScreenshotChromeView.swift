import AppKit
import VeltoAnnotationCore

// Compact floating chrome adapted from CapCap's ToolbarView / AdaptiveChrome.
// Attribution and MIT license: Resources/ThirdPartyNotices/CapCap.md.
class ScreenshotChromeView: NSView {
  static let accent = NSColor(srgbRed: 0.12, green: 0.84, blue: 0.51, alpha: 1)
  var cornerRadius: CGFloat = 12 { didSet { needsDisplay = true } }
  private var helpTrackingArea: NSTrackingArea?
  private var helpTask: Task<Void, Never>?
  private var helpPanel: NSPanel?
  private var helpText: String?

  override init(frame: NSRect) {
    super.init(frame: frame)
    appearance = NSAppearance(named: .darkAqua)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError("not implemented") }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                           xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor(srgbRed: 0.10, green: 0.12, blue: 0.14, alpha: 0.97).setFill()
    path.fill()
    NSColor.white.withAlphaComponent(0.12).setStroke()
    path.lineWidth = 0.5
    path.stroke()
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let helpTrackingArea { removeTrackingArea(helpTrackingArea) }
    let area = NSTrackingArea(rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    helpTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { updateHelp(with: event) }
  override func mouseMoved(with event: NSEvent) { updateHelp(with: event) }
  override func mouseExited(with event: NSEvent) { dismissHelp() }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    dismissHelp()
    super.viewWillMove(toWindow: newWindow)
  }

  func dismissHelp() {
    helpTask?.cancel()
    helpTask = nil
    helpText = nil
    if let helpPanel {
      helpPanel.parent?.removeChildWindow(helpPanel)
      helpPanel.orderOut(nil)
    }
    helpPanel = nil
  }

  private func updateHelp(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    var target = hitTest(point)
    while let view = target, view !== self, view.toolTip == nil { target = view.superview }
    guard let target, target !== self, var text = target.toolTip, !text.isEmpty else {
      dismissHelp()
      return
    }
    if let control = target as? NSSegmentedControl, control.segmentCount > 0, control.bounds.width > 0 {
      let x = control.convert(event.locationInWindow, from: nil).x - control.bounds.minX
      let segment = max(0, min(control.segmentCount - 1,
        Int(x / control.bounds.width * CGFloat(control.segmentCount))))
      text = control.toolTip(forSegment: segment) ?? text
    }
    guard text != helpText else { return }
    dismissHelp()
    helpText = text
    helpTask = Task { [weak self, weak target] in
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      guard let self, let target, self.helpText == text,
            !self.isHiddenOrHasHiddenAncestor, let window = self.window,
            window.isVisible, target.window === window else { return }
      self.showHelp(text, for: target, in: window)
    }
  }

  private func showHelp(_ text: String, for target: NSView, in parent: NSWindow) {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 12)
    label.textColor = .white
    label.sizeToFit()
    let size = NSSize(width: label.frame.width + 20, height: label.frame.height + 14)
    let anchor = parent.convertToScreen(target.convert(target.bounds, to: nil))
    let screen = (parent.screen?.visibleFrame ?? parent.frame).insetBy(dx: 8, dy: 8)
    let x = max(screen.minX, min(anchor.midX - size.width / 2, screen.maxX - size.width))
    let below = anchor.minY - size.height - 8
    let y = max(screen.minY, min(below >= screen.minY ? below : anchor.maxY + 8,
                               screen.maxY - size.height))
    let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    // Native tooltips may sit below the screen-saver-level capture overlay.
    // A non-interactive child stays above it without taking focus or mouse input.
    panel.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    let background = NSView(frame: NSRect(origin: .zero, size: size))
    background.wantsLayer = true
    background.layer?.backgroundColor = NSColor(srgbRed: 0.16, green: 0.18, blue: 0.20, alpha: 1).cgColor
    background.layer?.cornerRadius = 6
    label.frame.origin = NSPoint(x: 10, y: 7)
    background.addSubview(label)
    panel.contentView = background
    helpPanel = panel
    parent.addChildWindow(panel, ordered: .above)
  }
}

extension AnnotationIcon {
  var symbolName: String {
    switch self {
    case .rectangle: "rectangle"
    case .ellipse: "circle"
    case .line: "line.diagonal"
    case .arrow: "arrow.up.right"
    case .pen: "pencil.tip"
    case .mosaic: "square.grid.3x3"
    case .text: "textformat"
    case .highlight: "highlighter"
    case .sequence: "1.circle"
    case .crop: "crop"
    case .undo: "arrow.uturn.backward"
    case .redo: "arrow.uturn.forward"
    case .cancel: "xmark"
    case .save: "square.and.arrow.down"
    case .copy: "doc.on.clipboard"
    case .scrollCapture: "arrow.up.and.down.text.horizontal"
    case .complete: "checkmark"
    }
  }
}
