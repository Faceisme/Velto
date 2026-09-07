import AppKit
import VeltoAnnotationCore

/// Shared commands for the editing row and the capture/output column.
enum AnnotationToolbarAction {
  case selectTool(AnnotationTool?)
  case undo, redo, scroll, cancel, save, copy, complete
}

/// Compact primary/side toolbars, adapted from CapCap's ToolbarView.
/// The same native buttons are also used while capturing a long screenshot.
final class AnnotationToolbarView: ScreenshotChromeView {
  static let buttonSize: CGFloat = 32
  static let barHeight: CGFloat = 44
  var onAction: ((AnnotationToolbarAction) -> Void)?

  private let stack = NSStackView()
  private var toolButtons: [AnnotationTool: AnnotationToolbarButton] = [:]
  private var undoButton: AnnotationToolbarButton?
  private var redoButton: AnnotationToolbarButton?
  private var scrollButton: AnnotationToolbarButton?
  private let actionsOnly: Bool

  override convenience init(frame: NSRect) { self.init(frame: frame, actionsOnly: false) }

  init(frame: NSRect, actionsOnly: Bool) {
    self.actionsOnly = actionsOnly
    super.init(frame: frame)
    stack.orientation = actionsOnly ? .vertical : .horizontal
    stack.alignment = actionsOnly ? .centerX : .centerY
    stack.spacing = 4
    stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
    addSubview(stack)
    if actionsOnly {
      scrollButton = add(.scrollCapture, title: "长截图（S）", help: "长截图：锁定选区，上下滚动页面来拼接", action: .scroll)
      add(.save, title: "保存", help: "保存：将截图存储到本地", action: .save)
      separator()
      add(.cancel, title: "取消（Esc）", help: "取消：放弃本次截图并退出", action: .cancel).tone = .destructive
      add(.complete, title: "复制（空格）", help: "复制：将截图放入剪贴板并退出", action: .complete).tone = .confirm
    } else {
      let tools: [(AnnotationTool, AnnotationIcon, String, String)] = [
        (.rectangle, .rectangle, "矩形", "矩形：拖动绘制方框，可调整颜色、线宽和填充"),
        (.ellipse, .ellipse, "椭圆", "椭圆：拖动圈出内容，可调整颜色、线宽和填充"),
        (.line, .line, "直线", "直线：拖动绘制线段"),
        (.arrow, .arrow, "箭头", "箭头：从起点拖向需要指示的位置"),
        (.pen, .pen, "画笔", "画笔：按住鼠标自由绘制"),
        (.highlight, .highlight, "高亮", "高亮：用半透明笔触突出内容"),
        (.mosaic, .mosaic, "马赛克", "马赛克：拖动框出需要模糊的区域"),
        (.sequence, .sequence, "序号", "序号：点击添加递增的数字标记"),
        (.text, .text, "文字", "文字标注：点击截图输入文字，可调整颜色、字号和对齐"),
        (.crop, .crop, "裁剪", "裁剪：拖出要保留的区域，复制或保存时裁去外部")
      ]
      for (tool, icon, title, help) in tools {
        toolButtons[tool] = add(icon, title: title, help: help, action: .selectTool(tool))
      }
      separator()
      undoButton = add(.undo, title: "撤销（⌘Z）", action: .undo)
      redoButton = add(.redo, title: "重做（⇧⌘Z）", action: .redo)
    }
  }

  required init?(coder: NSCoder) { fatalError("not implemented") }
  override func layout() { super.layout(); stack.frame = bounds }

  var barSize: NSSize {
    let size = stack.fittingSize
    return actionsOnly ? NSSize(width: Self.barHeight, height: size.height)
      : NSSize(width: size.width, height: Self.barHeight)
  }

  func update(activeTool: AnnotationTool?, canUndo: Bool, canRedo: Bool) {
    for (tool, button) in toolButtons { button.isSelected = tool == activeTool }
    undoButton?.isEnabled = canUndo
    redoButton?.isEnabled = canRedo
  }

  func setScrollEnabled(_ enabled: Bool) { scrollButton?.isEnabled = enabled }

  @discardableResult
  private func add(_ icon: AnnotationIcon, title: String, help: String? = nil,
                   action: AnnotationToolbarAction) -> AnnotationToolbarButton {
    let button = AnnotationToolbarButton(icon: icon)
    button.toolTip = help ?? title
    button.setAccessibilityLabel(title)
    button.onClick = { [weak self] in self?.onAction?(action) }
    stack.addArrangedSubview(button)
    return button
  }

  private func separator() {
    let separator = NSBox()
    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      separator.widthAnchor.constraint(equalToConstant: actionsOnly ? 20 : 1),
      separator.heightAnchor.constraint(equalToConstant: actionsOnly ? 1 : 20)
    ])
    stack.addArrangedSubview(separator)
  }
}

/// Native NSButton provides tracking, accessibility and activation behavior.
final class AnnotationToolbarButton: NSButton {
  enum Tone { case standard, destructive, confirm }
  var onClick: (() -> Void)?
  var tone: Tone = .standard { didSet { needsDisplay = true } }
  var isSelected = false { didSet { needsDisplay = true } }
  private var hovering = false
  private var hoverArea: NSTrackingArea?

  init(icon: AnnotationIcon) {
    super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
    translatesAutoresizingMaskIntoConstraints = false
    isBordered = false
    setButtonType(.momentaryPushIn)
    imagePosition = .imageOnly
    image = NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
    if icon == .text {
      // The textformat symbol localizes to “格式” on Chinese systems.
      image = nil
      imagePosition = .noImage
      title = "Aa"
      font = .systemFont(ofSize: 16, weight: .medium)
    }
    target = self
    action = #selector(invokeAction)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: AnnotationToolbarView.buttonSize),
      heightAnchor.constraint(equalToConstant: AnnotationToolbarView.buttonSize)
    ])
  }

  required init?(coder: NSCoder) { fatalError("not implemented") }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
  @objc private func invokeAction() {
    var parent = superview
    while let view = parent {
      if let chrome = view as? ScreenshotChromeView { chrome.dismissHelp(); break }
      parent = view.superview
    }
    onClick?()
  }

  override func draw(_ dirtyRect: NSRect) {
    if isSelected || (isEnabled && (hovering || isHighlighted)) {
      let color = isSelected ? ScreenshotChromeView.accent.withAlphaComponent(0.16)
        : NSColor.white.withAlphaComponent(isHighlighted ? 0.15 : 0.08)
      color.setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
    contentTintColor = !isEnabled ? NSColor.white.withAlphaComponent(0.25)
      : isSelected || tone == .confirm ? ScreenshotChromeView.accent
      : tone == .destructive ? NSColor(srgbRed: 1, green: 0.40, blue: 0.43, alpha: 1)
      : NSColor.white.withAlphaComponent(0.9)
    if imagePosition == .noImage {
      let caption = NSAttributedString(string: title, attributes: [
        .font: font ?? NSFont.systemFont(ofSize: 16),
        .foregroundColor: contentTintColor ?? NSColor.white
      ])
      if !attributedTitle.isEqual(to: caption) { attributedTitle = caption }
    }
    super.draw(dirtyRect)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                             owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverArea = area
  }
  override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
}
