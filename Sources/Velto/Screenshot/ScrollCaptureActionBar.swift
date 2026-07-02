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

  private static let buttonSize: CGFloat = 36
  private static let buttonGap: CGFloat = 2
  private static let contentInsets = NSEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)

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
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    setupContent(size: size)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  private func setupContent(size: CGSize) {
    let content = NSStackView(frame: CGRect(origin: .zero, size: size))
    content.orientation = .vertical
    content.alignment = .centerX
    content.distribution = .fill
    content.spacing = Self.buttonGap
    content.edgeInsets = Self.contentInsets

    let finishButton = makeButton(icon: .complete, toolTip: "完成")
    finishButton.tone = .confirm
    finishButton.onClick = { [weak self] in self?.onFinish?() }
    content.addArrangedSubview(finishButton)

    let copyButton = makeButton(icon: .copy, toolTip: "复制")
    copyButton.onClick = { [weak self] in self?.onCopy?() }
    content.addArrangedSubview(copyButton)

    let saveButton = makeButton(icon: .save, toolTip: "存储到本地")
    saveButton.onClick = { [weak self] in self?.onSave?() }
    content.addArrangedSubview(saveButton)

    let cancelButton = makeButton(icon: .cancel, toolTip: "取消")
    cancelButton.tone = .destructive
    cancelButton.onClick = { [weak self] in self?.onCancel?() }
    content.addArrangedSubview(cancelButton)

    let glass = NSGlassEffectView(frame: CGRect(origin: .zero, size: size))
    glass.cornerRadius = 18
    glass.contentView = content
    contentView = glass
  }

  private func makeButton(icon: AnnotationIcon, toolTip: String) -> AnnotationToolbarButton {
    let button = AnnotationToolbarButton(icon: icon)
    button.toolTip = toolTip
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: Self.buttonSize),
      button.heightAnchor.constraint(equalToConstant: Self.buttonSize),
    ])
    return button
  }
}
