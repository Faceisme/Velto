import AppKit
import VeltoAnnotationCore

/// 滚动截图期间贴近选区边框的操作条。它是独立非激活浮窗,不改变底下目标 App 的前台状态;
/// 截图覆盖层仍可透传滚轮,只有按钮本身接收鼠标点击。
@MainActor
final class ScrollCaptureActionBar: NSPanel {
  var onFinish: (() -> Void)?
  var onCopy: (() -> Void)?
  var onSave: (() -> Void)?
  var onCancel: (() -> Void)?

  private static let buttonSize: CGFloat = 32
  private static let buttonGap: CGFloat = 2
  private static let contentInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

  private static var barSize: CGSize {
    let width = contentInsets.left + buttonSize + contentInsets.right
    let height = contentInsets.top + contentInsets.bottom
      + buttonSize * 4
      + buttonGap * 3
    return CGSize(width: width, height: height)
  }

  init(selectionRect: CGRect, screenFrame: CGRect) {
    let size = Self.barSize
    let frame = ScrollCaptureActionBarLayout.place(
      selection: selectionRect,
      screenBounds: screenFrame,
      barSize: size
    )
    super.init(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isOpaque = false
    backgroundColor = .clear
    level = .screenSaver
    hasShadow = true
    hidesOnDeactivate = false
    acceptsMouseMovedEvents = true
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    setupContent(size: size)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// 选区几何变化(底边扩展)后按新选区重新落位。
  func reposition(selectionRect: CGRect, screenFrame: CGRect) {
    setFrame(ScrollCaptureActionBarLayout.place(
      selection: selectionRect,
      screenBounds: screenFrame,
      barSize: Self.barSize
    ), display: true)
  }

  private func setupContent(size: CGSize) {
    let content = NSStackView(frame: CGRect(origin: .zero, size: size))
    content.orientation = .vertical
    content.alignment = .centerX
    content.distribution = .fill
    content.spacing = Self.buttonGap
    content.edgeInsets = Self.contentInsets

    let finishButton = makeButton(icon: .complete, title: "完成", toolTip: "完成：结束滚动，继续裁剪或标注长图")
    finishButton.tone = .confirm
    finishButton.onClick = { [weak self] in self?.onFinish?() }
    content.addArrangedSubview(finishButton)

    let copyButton = makeButton(icon: .copy, title: "复制", toolTip: "复制：将长图放入剪贴板并退出")
    copyButton.onClick = { [weak self] in self?.onCopy?() }
    content.addArrangedSubview(copyButton)

    let saveButton = makeButton(icon: .save, title: "存储到本地", toolTip: "保存：将长图存储到本地并退出")
    saveButton.onClick = { [weak self] in self?.onSave?() }
    content.addArrangedSubview(saveButton)

    let cancelButton = makeButton(icon: .cancel, title: "取消", toolTip: "取消：放弃本次长截图并退出")
    cancelButton.tone = .destructive
    cancelButton.onClick = { [weak self] in self?.onCancel?() }
    content.addArrangedSubview(cancelButton)

    let glass = ScreenshotChromeView(frame: CGRect(origin: .zero, size: size))
    glass.cornerRadius = 12
    glass.addSubview(content)
    contentView = glass
  }

  private func makeButton(icon: AnnotationIcon, title: String, toolTip: String) -> AnnotationToolbarButton {
    let button = AnnotationToolbarButton(icon: icon)
    button.toolTip = toolTip
    button.setAccessibilityLabel(title)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: Self.buttonSize),
      button.heightAnchor.constraint(equalToConstant: Self.buttonSize),
    ])
    return button
  }
}
