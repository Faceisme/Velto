import AppKit

/// 滚动捕获浮窗:展示长图缩略与提示;作为 key 窗口接收完成、保存和取消操作。
/// 滚轮事件落在光标下的窗口,因此浮窗接键盘不会影响用户滚动目标 App。
@MainActor
final class ScrollCaptureHUD: NSWindow {
  var onCopy: (() -> Void)?
  var onSave: (() -> Void)?
  var onCancel: (() -> Void)?

  private let imageView = NSImageView()
  private let hintLabel = NSTextField(labelWithString: "")
  private static let defaultHint = "向下滚动目标窗口(滚慢一点)\nEnter/空格 完成 · ⌘S 保存 · Esc 取消"

  init(onScreen screenFrame: CGRect) {
    let size = NSSize(width: 240, height: 340)
    let origin = NSPoint(
      x: screenFrame.maxX - size.width - 24,
      y: screenFrame.minY + 24
    )
    super.init(
      contentRect: CGRect(origin: origin, size: size),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    isOpaque = false
    backgroundColor = .clear
    level = .screenSaver
    hasShadow = true
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    setupContent(size: size)
  }

  override var canBecomeKey: Bool { true }

  private func setupContent(size: NSSize) {
    let container = NSView(frame: CGRect(origin: .zero, size: size))
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
    container.layer?.cornerRadius = 12

    imageView.frame = CGRect(
      x: 12,
      y: 60,
      width: size.width - 24,
      height: size.height - 72
    )
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.wantsLayer = true
    imageView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
    container.addSubview(imageView)

    hintLabel.frame = CGRect(x: 12, y: 8, width: size.width - 24, height: 44)
    hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
    hintLabel.textColor = .white
    hintLabel.alignment = .center
    hintLabel.maximumNumberOfLines = 3
    hintLabel.lineBreakMode = .byWordWrapping
    hintLabel.stringValue = Self.defaultHint
    container.addSubview(hintLabel)
    contentView = container
  }

  func update(thumbnail: CGImage?, heightPx: Int, hint: String?) {
    if let thumbnail {
      imageView.image = NSImage(cgImage: thumbnail, size: .zero)
    }
    hintLabel.stringValue = hint ?? Self.defaultHint
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 49:
      onCopy?()
    case 1 where event.modifierFlags.contains(.command):
      onSave?()
    case 53:
      onCancel?()
    default:
      super.keyDown(with: event)
    }
  }
}
