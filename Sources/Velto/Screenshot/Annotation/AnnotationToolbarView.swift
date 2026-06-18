import AppKit
import VeltoAnnotationCore

/// 主工具栏向覆盖层回报的动作。选区/工具切换走 `selectTool`,其余是一次性命令。
enum AnnotationToolbarAction {
  case selectTool(AnnotationTool?)
  case undo
  case redo
  case cancel
  case save
  case copy
  case complete
}

/// Xnip 风格的 Liquid Glass 主工具栏:10 个工具 + 2 个历史 + 4 个动作,共 16 个
/// 等宽 36×36 按钮。图标全部走 `AnnotationIconLibrary` 自绘矢量,统一 2pt 描边,
/// 不使用 SF Symbols,这样 hover/pressed/disabled 都只改背景、绝不改尺寸或缩放。
final class AnnotationToolbarView: NSGlassEffectView {
  static let buttonSize: CGFloat = 36
  static let barHeight: CGFloat = 54

  var onAction: ((AnnotationToolbarAction) -> Void)?

  private let contentStack = NSStackView()
  private var toolButtons: [AnnotationTool: AnnotationToolbarButton] = [:]
  private var undoButton: AnnotationToolbarButton!
  private var redoButton: AnnotationToolbarButton!

  private static let toolOrder: [(AnnotationTool, AnnotationIcon)] = [
    (.rectangle, .rectangle),
    (.ellipse, .ellipse),
    (.line, .line),
    (.arrow, .arrow),
    (.pen, .pen),
    (.mosaic, .mosaic),
    (.text, .text),
    (.highlight, .highlight),
    (.sequence, .sequence),
    (.crop, .crop),
  ]

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    style = .regular
    cornerRadius = 18
    wantsLayer = true
    layer?.masksToBounds = true
    buildLayout()
  }

  required init?(coder: NSCoder) {
    fatalError("not implemented")
  }

  /// 自然尺寸:外层布局据此放置玻璃面板,内容随玻璃 bounds 自动铺满。
  var barSize: NSSize {
    NSSize(width: contentStack.fittingSize.width, height: Self.barHeight)
  }

  func update(activeTool: AnnotationTool?, canUndo: Bool, canRedo: Bool) {
    for (tool, button) in toolButtons {
      button.isSelected = (tool == activeTool)
    }
    undoButton.isEnabled = canUndo
    redoButton.isEnabled = canRedo
  }

  // MARK: - Layout

  private func buildLayout() {
    contentStack.orientation = .horizontal
    contentStack.alignment = .centerY
    contentStack.distribution = .fill
    contentStack.spacing = 2
    contentStack.edgeInsets = NSEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)

    var lastTool: AnnotationToolbarButton?
    for (tool, icon) in Self.toolOrder {
      let button = makeButton(icon: icon)
      button.onClick = { [weak self] in self?.onAction?(.selectTool(tool)) }
      toolButtons[tool] = button
      contentStack.addArrangedSubview(button)
      lastTool = button
    }

    undoButton = makeButton(icon: .undo)
    undoButton.onClick = { [weak self] in self?.onAction?(.undo) }
    redoButton = makeButton(icon: .redo)
    redoButton.onClick = { [weak self] in self?.onAction?(.redo) }
    contentStack.addArrangedSubview(undoButton)
    contentStack.addArrangedSubview(redoButton)

    let saveButton = makeButton(icon: .save)
    saveButton.onClick = { [weak self] in self?.onAction?(.save) }
    let copyButton = makeButton(icon: .copy)
    copyButton.onClick = { [weak self] in self?.onAction?(.copy) }
    let cancelButton = makeButton(icon: .cancel)
    cancelButton.tone = .destructive
    cancelButton.onClick = { [weak self] in self?.onAction?(.cancel) }
    let completeButton = makeButton(icon: .complete)
    completeButton.tone = .confirm
    completeButton.onClick = { [weak self] in self?.onAction?(.complete) }
    contentStack.addArrangedSubview(saveButton)
    contentStack.addArrangedSubview(copyButton)
    contentStack.addArrangedSubview(cancelButton)
    contentStack.addArrangedSubview(completeButton)

    // 组间留 4pt:工具|历史、历史|动作。
    if let lastTool {
      contentStack.setCustomSpacing(4, after: lastTool)
    }
    contentStack.setCustomSpacing(4, after: redoButton)

    contentView = contentStack
  }

  private func makeButton(icon: AnnotationIcon) -> AnnotationToolbarButton {
    let button = AnnotationToolbarButton(icon: icon)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: Self.buttonSize),
      button.heightAnchor.constraint(equalToConstant: Self.buttonSize),
    ])
    return button
  }
}

/// 36×36 的工具按钮:中央嵌一个固定 24×24 的图标视图。hover/pressed 只改圆角背景,
/// 选中态用 controlAccentColor 实心底配白色图标;禁用态走 disabledControlTextColor。
final class AnnotationToolbarButton: NSView {
  enum Tone {
    case standard
    case destructive
    case confirm
  }

  var onClick: (() -> Void)?
  var tone: Tone = .standard { didSet { refreshTint() } }
  var isSelected = false {
    didSet {
      needsDisplay = true
      refreshTint()
    }
  }
  var isEnabled = true {
    didSet {
      needsDisplay = true
      refreshTint()
    }
  }

  private let iconView: AnnotationIconView
  private var isHovering = false
  private var isPressed = false
  private var trackingArea: NSTrackingArea?

  init(icon: AnnotationIcon) {
    iconView = AnnotationIconView(icon: icon)
    super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)
    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 24),
      iconView.heightAnchor.constraint(equalToConstant: 24),
    ])
    refreshTint()
  }

  required init?(coder: NSCoder) {
    fatalError("not implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: AnnotationToolbarView.buttonSize, height: AnnotationToolbarView.buttonSize)
  }

  override func draw(_ dirtyRect: NSRect) {
    let inset = bounds.insetBy(dx: 2, dy: 2)
    let path = NSBezierPath(roundedRect: inset, xRadius: 9, yRadius: 9)
    if isSelected {
      NSColor.controlAccentColor.setFill()
      path.fill()
    } else if isEnabled && (isHovering || isPressed) {
      NSColor.labelColor.withAlphaComponent(isPressed ? 0.18 : 0.1).setFill()
      path.fill()
    }
  }

  private func refreshTint() {
    iconView.tint = resolvedTint
  }

  private var resolvedTint: NSColor {
    if isSelected { return .white }
    if !isEnabled { return .disabledControlTextColor }
    switch tone {
    case .standard: return .labelColor
    case .destructive: return .systemRed
    case .confirm: return .systemGreen
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    guard isEnabled else { return }
    isHovering = true
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    isHovering = false
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    isPressed = true
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard isEnabled else { return }
    let wasPressed = isPressed
    isPressed = false
    needsDisplay = true
    let point = convert(event.locationInWindow, from: nil)
    if wasPressed && bounds.contains(point) {
      onClick?()
    }
  }
}

/// 固定 24×24 的图标视图:翻转坐标系以匹配 `AnnotationIconLibrary` 的 y-down 设计空间,
/// 统一 2pt round cap/join 描边,颜色由按钮注入。
final class AnnotationIconView: NSView {
  var icon: AnnotationIcon { didSet { needsDisplay = true } }
  var tint: NSColor = .labelColor { didSet { needsDisplay = true } }

  init(icon: AnnotationIcon) {
    self.icon = icon
    super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
  }

  required init?(coder: NSCoder) {
    fatalError("not implemented")
  }

  override var isFlipped: Bool { true }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 24, height: 24)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.addPath(AnnotationIconLibrary.path(for: icon))
    context.setStrokeColor(tint.cgColor)
    context.setLineWidth(2)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()
  }
}
