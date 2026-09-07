import AppKit

/// A readable, fixed-width preview, following CapCap's scrolling preview.
/// Long images retain their width; the viewport follows newly appended rows.
@MainActor
final class ScrollCaptureHUD: NSPanel {
  private let imageView = NSImageView()
  private let preview = NSScrollView()
  private let hintLabel = NSTextField(wrappingLabelWithString: "")
  private let heightLabel = NSTextField(labelWithString: "准备中")
  private var preferences = ScreenshotPreferences.defaults

  init(onScreen screenFrame: CGRect, selection: CGRect? = nil) {
    let size = NSSize(width: 224, height: 350)
    let selection = selection ?? screenFrame
    var x = selection.maxX + 60
    if x + size.width > screenFrame.maxX - 12 { x = selection.minX - size.width - 60 }
    x = max(screenFrame.minX + 12, min(x, screenFrame.maxX - size.width - 12))
    let y = max(screenFrame.minY + 12, min(selection.maxY - size.height, screenFrame.maxY - size.height - 12))
    super.init(contentRect: CGRect(origin: CGPoint(x: x, y: y), size: size),
               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    level = .screenSaver
    hasShadow = true
    hidesOnDeactivate = false
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

    let content = ScreenshotChromeView(frame: CGRect(origin: .zero, size: size))
    let title = NSTextField(labelWithString: "长截图")
    title.font = .systemFont(ofSize: 12, weight: .semibold)
    title.textColor = .white
    title.frame = CGRect(x: 12, y: 320, width: 90, height: 18)
    content.addSubview(title)
    heightLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    heightLabel.textColor = ScreenshotChromeView.accent
    heightLabel.alignment = .right
    heightLabel.frame = CGRect(x: 102, y: 320, width: 110, height: 18)
    content.addSubview(heightLabel)

    preview.frame = CGRect(x: 12, y: 76, width: 200, height: 234)
    preview.hasVerticalScroller = true
    preview.autohidesScrollers = true
    preview.drawsBackground = true
    preview.backgroundColor = NSColor(white: 0.06, alpha: 1)
    preview.documentView = imageView
    imageView.imageScaling = .scaleAxesIndependently
    content.addSubview(preview)

    hintLabel.frame = CGRect(x: 12, y: 12, width: 200, height: 54)
    hintLabel.font = .systemFont(ofSize: 11)
    hintLabel.textColor = NSColor.white.withAlphaComponent(0.65)
    hintLabel.maximumNumberOfLines = 4
    content.addSubview(hintLabel)
    contentView = content
  }

  override var canBecomeKey: Bool { false }
  func configureShortcuts(using preferences: ScreenshotPreferences) {
    self.preferences = preferences
    hintLabel.stringValue = configuredHint
  }

  func update(thumbnail: CGImage?, heightPx: Int, hint: String?) {
    heightLabel.stringValue = heightPx > 0 ? "\(heightPx) px" : "准备中"
    if let thumbnail {
      let followTail = preview.contentView.bounds.minY <= 8
      let height = 200 * CGFloat(thumbnail.height) / CGFloat(thumbnail.width)
      imageView.frame = CGRect(x: 0, y: 0, width: 200, height: height)
      imageView.image = NSImage(cgImage: thumbnail, size: imageView.frame.size)
      if followTail { preview.contentView.scroll(to: .zero) }
      preview.reflectScrolledClipView(preview.contentView)
    }
    hintLabel.stringValue = hint ?? configuredHint
  }

  var configuredHint: String {
    "完成后编辑 · 空格复制\n\(preferences.saveShortcut.displayName) 保存 · Esc 取消"
  }
}
