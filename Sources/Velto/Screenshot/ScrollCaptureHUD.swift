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
  private var copyKeyCode = ScreenshotPreferences.defaults.copyKeyCode
  private var cancelKeyCode = ScreenshotPreferences.defaults.cancelKeyCode
  private var saveShortcut = ScreenshotPreferences.defaults.saveShortcut

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
    ignoresMouseEvents = true
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    setupContent(size: size)
    configureShortcuts(using: GestureStore.shared.preferences.screenshot)
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
    hintLabel.stringValue = configuredHint
    container.addSubview(hintLabel)
    contentView = container
  }

  /// 复用本次截图会话的快捷键配置,并同步更新浮窗提示。
  func configureShortcuts(using preferences: ScreenshotPreferences) {
    copyKeyCode = preferences.copyKeyCode
    cancelKeyCode = preferences.cancelKeyCode
    saveShortcut = preferences.saveShortcut
    hintLabel.stringValue = configuredHint
  }

  func update(thumbnail: CGImage?, heightPx: Int, hint: String?) {
    if let thumbnail {
      imageView.image = NSImage(cgImage: thumbnail, size: .zero)
    }
    hintLabel.stringValue = hint ?? configuredHint
  }

  override func keyDown(with event: NSEvent) {
    let normalizedModifiers = ModifierFormatter.normalizedRawValue(from: event.modifierFlags)
    if event.keyCode == saveShortcut.keyCode,
       normalizedModifiers == saveShortcut.modifierFlags {
      onSave?()
    } else if normalizedModifiers == 0, event.keyCode == copyKeyCode {
      onCopy?()
    } else if normalizedModifiers == 0, event.keyCode == cancelKeyCode {
      onCancel?()
    } else if normalizedModifiers == 0, event.keyCode == 36 {
      onCopy?()
    } else {
      super.keyDown(with: event)
    }
  }

  private var configuredHint: String {
    let copyName = Self.keyName(for: copyKeyCode)
    let finishKeys = copyKeyCode == 36 ? "Enter" : "Enter/\(copyName)"
    return "向下滚动目标窗口(滚慢一点)\n"
      + "\(finishKeys) 完成 · \(saveShortcut.displayName) 保存 · "
      + "\(Self.keyName(for: cancelKeyCode)) 取消"
  }

  private static func keyName(for keyCode: UInt16) -> String {
    switch keyCode {
    case 36: return "Enter"
    case 48: return "Tab"
    case 49: return "空格"
    case 51: return "删除"
    case 53: return "Esc"
    default: return "keyCode \(keyCode)"
    }
  }
}
