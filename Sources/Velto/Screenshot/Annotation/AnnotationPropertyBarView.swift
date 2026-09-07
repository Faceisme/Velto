import AppKit
import VeltoAnnotationCore

/// 跟随当前工具变化的属性条。每个工具只暴露自己相关的控件,改动即时回调
/// `onStyleChange`,由覆盖层把新样式写回编辑器。crop 工具只读显示选区尺寸。
final class AnnotationPropertyBarView: ScreenshotChromeView {
  static let barHeight: CGFloat = 34

  var onStyleChange: ((AnnotationStyle) -> Void)?

  private let contentStack = NSStackView()
  private var currentTool: AnnotationTool?
  private var currentStyle = AnnotationStyle.defaults
  private var currentCropRect: CGRect = .zero

  private var colorWell: NSColorWell?
  private var swatchButtons: [AnnotationSwatchButton] = []
  private var lineWidthControl: NSSegmentedControl?
  private var fillOpacitySlider: NSSlider?
  private var highlightWidthControl: NSSegmentedControl?
  private var highlightOpacitySlider: NSSlider?
  private var mosaicControl: NSSegmentedControl?
  private var fontSizeControl: NSSegmentedControl?
  private var boldButton: NSButton?
  private var alignmentControl: NSSegmentedControl?
  private var sequenceDiameterControl: NSSegmentedControl?
  private var cropLabel: NSTextField?

  private static let lineWidths: [CGFloat] = [1, 3, 5]
  private static let highlightWidths: [CGFloat] = [4, 8, 12]
  private static let mosaicSizes: [Int] = [8, 12, 16, 24]
  private static let fontSizes: [CGFloat] = [14, 18, 24, 32]
  private static let sequenceDiameters: [CGFloat] = [24, 28, 32]
  private static let alignments: [AnnotationTextAlignment] = [.left, .center, .right]

  /// 常用色快捷色板;自定义颜色仍走右侧取色器。
  private static let presetColors: [(color: AnnotationColor, name: String)] = [
    (AnnotationColor(red: 1.00, green: 0.23, blue: 0.19), "红"),
    (AnnotationColor(red: 1.00, green: 0.58, blue: 0.00), "橙"),
    (AnnotationColor(red: 1.00, green: 0.80, blue: 0.00), "黄"),
    (AnnotationColor(red: 0.20, green: 0.78, blue: 0.35), "绿"),
    (AnnotationColor(red: 0.00, green: 0.48, blue: 1.00), "蓝"),
    (AnnotationColor(red: 0.69, green: 0.32, blue: 0.87), "紫"),
    (AnnotationColor(red: 0.00, green: 0.00, blue: 0.00), "黑"),
    (AnnotationColor(red: 1.00, green: 1.00, blue: 1.00), "白"),
  ]

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    cornerRadius = 10
    wantsLayer = true
    layer?.masksToBounds = true

    contentStack.orientation = .horizontal
    contentStack.alignment = .centerY
    contentStack.distribution = .fill
    contentStack.spacing = 8
    contentStack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
    addSubview(contentStack)
  }

  override func layout() { super.layout(); contentStack.frame = bounds }

  required init?(coder: NSCoder) {
    fatalError("not implemented")
  }

  /// 覆盖父覆盖层的全屏十字光标:属性条上恢复普通箭头。
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .arrow)
  }

  var barSize: NSSize {
    NSSize(width: max(120, contentStack.fittingSize.width), height: Self.barHeight)
  }

  func update(tool: AnnotationTool?, style: AnnotationStyle, cropRect: CGRect) {
    currentStyle = style
    currentCropRect = cropRect
    if tool != currentTool {
      currentTool = tool
      rebuild(for: tool)
    } else {
      refreshCropLabel()
      // 外部样式变化(如选中了别的颜色的对象)时同步色板与取色器。
      colorWell?.color = style.strokeColor.nsColor
      refreshSwatchSelection()
    }
  }

  // MARK: - Build

  private func rebuild(for tool: AnnotationTool?) {
    dismissHelp()
    clearControls()
    for view in contentStack.arrangedSubviews {
      contentStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    guard let tool else { return }
    switch tool {
    case .rectangle, .ellipse:
      addColorWell()
      addLineWidth()
      addFillOpacity()
    case .line, .arrow, .pen:
      addColorWell()
      addLineWidth()
    case .mosaic:
      addMosaic()
    case .text:
      addColorWell()
      addFontSize()
      addBold()
      addAlignment()
    case .highlight:
      addColorWell()
      addHighlightWidth()
      addHighlightOpacity()
    case .sequence:
      addColorWell()
      addSequenceDiameter()
    case .crop:
      addCropReadout()
    }
  }

  private func clearControls() {
    colorWell = nil
    swatchButtons = []
    lineWidthControl = nil
    fillOpacitySlider = nil
    highlightWidthControl = nil
    highlightOpacitySlider = nil
    mosaicControl = nil
    fontSizeControl = nil
    boldButton = nil
    alignmentControl = nil
    sequenceDiameterControl = nil
    cropLabel = nil
  }

  private func addColorWell() {
    // 快捷色板:一键换常用色,免开调色板。
    for preset in Self.presetColors {
      let swatch = AnnotationSwatchButton(color: preset.color)
      swatch.toolTip = "\(preset.name)色：设置标注颜色"
      swatch.setAccessibilityLabel("\(preset.name)色")
      swatch.onClick = { [weak self] in self?.swatchPicked(preset.color) }
      swatchButtons.append(swatch)
      contentStack.addArrangedSubview(swatch)
      contentStack.setCustomSpacing(4, after: swatch)
    }

    let well = NSColorWell(style: .minimal)
    well.color = currentStyle.strokeColor.nsColor
    well.toolTip = "自定义颜色：打开调色板选择其他颜色"
    well.setAccessibilityLabel("自定义颜色")
    well.target = self
    well.action = #selector(controlsChanged)
    NSLayoutConstraint.activate([
      well.widthAnchor.constraint(equalToConstant: 24),
      well.heightAnchor.constraint(equalToConstant: 24),
    ])
    colorWell = well
    contentStack.addArrangedSubview(well)
    refreshSwatchSelection()
  }

  private func swatchPicked(_ color: AnnotationColor) {
    dismissHelp()
    currentStyle.strokeColor = color
    currentStyle.fillColor = color
    colorWell?.color = color.nsColor
    refreshSwatchSelection()
    onStyleChange?(currentStyle)
  }

  private func refreshSwatchSelection() {
    for swatch in swatchButtons {
      swatch.isSelected = swatch.matches(currentStyle.strokeColor)
    }
  }

  private func addLineWidth() {
    let control = makeSegmented(
      images: Self.lineWidths.map { Self.dotImage(diameter: 3 + $0 * 1.6) },
      selected: nearestIndex(of: currentStyle.lineWidth, in: Self.lineWidths),
      help: Self.lineWidths.map { "线宽：\(Int($0))，调整线条粗细" }
    )
    control.toolTip = "线宽"
    lineWidthControl = control
    contentStack.addArrangedSubview(control)
  }

  private func addFillOpacity() {
    contentStack.addArrangedSubview(makeLabel("填充"))
    let slider = makeSlider(value: Double(currentStyle.fillOpacity))
    slider.toolTip = "填充透明度：最左为无填充，越向右越不透明"
    slider.setAccessibilityLabel("填充透明度")
    fillOpacitySlider = slider
    contentStack.addArrangedSubview(slider)
  }

  private func addMosaic() {
    let control = makeSegmented(
      labels: Self.mosaicSizes.map { "\($0)" },
      selected: nearestIndex(of: CGFloat(currentStyle.mosaicBlockSize), in: Self.mosaicSizes.map(CGFloat.init)),
      help: Self.mosaicSizes.map { "马赛克块大小：\($0)，数字越大块越粗" }
    )
    control.toolTip = "马赛克块大小"
    mosaicControl = control
    contentStack.addArrangedSubview(control)
  }

  private func addFontSize() {
    let control = makeSegmented(
      labels: Self.fontSizes.map { "\(Int($0))" },
      selected: nearestIndex(of: currentStyle.fontSize, in: Self.fontSizes),
      help: Self.fontSizes.map { "字号：\(Int($0))，数字越大文字越大" }
    )
    control.toolTip = "字号"
    fontSizeControl = control
    contentStack.addArrangedSubview(control)
  }

  private func addBold() {
    let button = NSButton(title: "B", target: self, action: #selector(controlsChanged))
    button.setButtonType(.pushOnPushOff)
    button.bezelStyle = .rounded
    button.font = .boldSystemFont(ofSize: 13)
    button.toolTip = "粗体：开启或关闭文字加粗"
    button.setAccessibilityLabel("粗体")
    button.state = currentStyle.isBold ? .on : .off
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 30),
    ])
    boldButton = button
    contentStack.addArrangedSubview(button)
  }

  private func addAlignment() {
    let symbols = ["text.alignleft", "text.aligncenter", "text.alignright"]
    let images = symbols.map {
      NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage()
    }
    let control = makeSegmented(
      images: images,
      selected: Self.alignments.firstIndex(of: currentStyle.textAlignment) ?? 0,
      help: ["左对齐：文字靠文本框左边排列", "居中：文字在文本框内居中排列", "右对齐：文字靠文本框右边排列"]
    )
    control.toolTip = "对齐"
    alignmentControl = control
    contentStack.addArrangedSubview(control)
  }

  private func addHighlightWidth() {
    let control = makeSegmented(
      images: Self.highlightWidths.map { Self.dotImage(diameter: 2 + $0 * 0.75) },
      selected: nearestIndex(of: currentStyle.lineWidth, in: Self.highlightWidths),
      help: Self.highlightWidths.map { "高亮笔宽：\(Int($0))，调整笔触粗细" }
    )
    control.toolTip = "笔宽"
    highlightWidthControl = control
    contentStack.addArrangedSubview(control)
  }

  private func addHighlightOpacity() {
    contentStack.addArrangedSubview(makeLabel("浓度"))
    let slider = makeSlider(value: Double(currentStyle.highlightOpacity))
    slider.toolTip = "高亮浓度：越向右颜色越浓，越向左越透明"
    slider.setAccessibilityLabel("高亮浓度")
    highlightOpacitySlider = slider
    contentStack.addArrangedSubview(slider)
  }

  private func addSequenceDiameter() {
    let control = makeSegmented(
      labels: Self.sequenceDiameters.map { "\(Int($0))" },
      selected: nearestIndex(of: currentStyle.sequenceDiameter, in: Self.sequenceDiameters),
      help: Self.sequenceDiameters.map { "序号大小：\(Int($0))，调整数字圆圈的直径" }
    )
    control.toolTip = "序号大小"
    sequenceDiameterControl = control
    contentStack.addArrangedSubview(control)
  }

  private func addCropReadout() {
    let label = makeLabel(cropText())
    label.toolTip = "裁剪尺寸：拖动选择要保留的区域，复制或保存时生效"
    label.font = .systemFont(ofSize: 13, weight: .medium)
    cropLabel = label
    contentStack.addArrangedSubview(label)
  }

  private func refreshCropLabel() {
    cropLabel?.stringValue = cropText()
  }

  private func cropText() -> String {
    let rect = currentCropRect.standardized
    return "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
  }

  // MARK: - Control factories

  private func makeSegmented(labels: [String], selected: Int, help: [String]) -> NSSegmentedControl {
    let control = NSSegmentedControl(
      labels: labels,
      trackingMode: .selectOne,
      target: self,
      action: #selector(controlsChanged)
    )
    control.segmentStyle = .rounded
    control.segmentDistribution = .fillEqually
    for (index, text) in help.enumerated() { control.setToolTip(text, forSegment: index) }
    control.selectedSegment = max(0, min(selected, labels.count - 1))
    return control
  }

  private func makeSegmented(images: [NSImage], selected: Int, help: [String]) -> NSSegmentedControl {
    let control = NSSegmentedControl(
      images: images,
      trackingMode: .selectOne,
      target: self,
      action: #selector(controlsChanged)
    )
    control.segmentStyle = .rounded
    control.segmentDistribution = .fillEqually
    for (index, text) in help.enumerated() { control.setToolTip(text, forSegment: index) }
    control.selectedSegment = max(0, min(selected, images.count - 1))
    return control
  }

  /// 线宽档位示意:模板圆点,随控件明暗自动着色。
  private static func dotImage(diameter: CGFloat) -> NSImage {
    let side: CGFloat = 14
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
      let rect = CGRect(
        x: (side - diameter) / 2, y: (side - diameter) / 2,
        width: diameter, height: diameter
      )
      NSColor.black.setFill()
      NSBezierPath(ovalIn: rect).fill()
      return true
    }
    image.isTemplate = true
    return image
  }

  private func makeSlider(value: Double) -> NSSlider {
    let slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: self, action: #selector(controlsChanged))
    slider.isContinuous = true
    NSLayoutConstraint.activate([
      slider.widthAnchor.constraint(equalToConstant: 70),
    ])
    return slider
  }

  private func makeLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 12)
    label.textColor = .secondaryLabelColor
    return label
  }

  private func nearestIndex(of value: CGFloat, in options: [CGFloat]) -> Int {
    guard !options.isEmpty else { return 0 }
    var best = 0
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for (index, option) in options.enumerated() {
      let distance = abs(option - value)
      if distance < bestDistance {
        bestDistance = distance
        best = index
      }
    }
    return best
  }

  // MARK: - Action

  @objc private func controlsChanged() {
    dismissHelp()
    var style = currentStyle
    if let colorWell, let resolved = AnnotationColor(resolving: colorWell.color) {
      style.strokeColor = resolved
      style.fillColor = resolved
    }
    if let lineWidthControl {
      style.lineWidth = Self.lineWidths[clampIndex(lineWidthControl.selectedSegment, Self.lineWidths.count)]
    }
    if let highlightWidthControl {
      style.lineWidth = Self.highlightWidths[clampIndex(highlightWidthControl.selectedSegment, Self.highlightWidths.count)]
    }
    if let fillOpacitySlider {
      style.fillOpacity = CGFloat(fillOpacitySlider.doubleValue)
    }
    if let highlightOpacitySlider {
      style.highlightOpacity = CGFloat(highlightOpacitySlider.doubleValue)
    }
    if let mosaicControl {
      style.mosaicBlockSize = Self.mosaicSizes[clampIndex(mosaicControl.selectedSegment, Self.mosaicSizes.count)]
    }
    if let fontSizeControl {
      style.fontSize = Self.fontSizes[clampIndex(fontSizeControl.selectedSegment, Self.fontSizes.count)]
    }
    if let boldButton {
      style.isBold = (boldButton.state == .on)
    }
    if let alignmentControl {
      style.textAlignment = Self.alignments[clampIndex(alignmentControl.selectedSegment, Self.alignments.count)]
    }
    if let sequenceDiameterControl {
      style.sequenceDiameter = Self.sequenceDiameters[clampIndex(sequenceDiameterControl.selectedSegment, Self.sequenceDiameters.count)]
    }
    currentStyle = style
    onStyleChange?(style)
  }

  private func clampIndex(_ index: Int, _ count: Int) -> Int {
    max(0, min(index, count - 1))
  }
}

/// 18×18 圆形快捷色板按钮:常显 1px 描边保证浅色可见,选中加 accent 外环。
final class AnnotationSwatchButton: NSView {
  var onClick: (() -> Void)?
  var isSelected = false { didSet { needsDisplay = true } }

  private let color: AnnotationColor
  private var isHovering = false
  private var trackingArea: NSTrackingArea?

  init(color: AnnotationColor) {
    self.color = color
    super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 18),
      heightAnchor.constraint(equalToConstant: 18),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("not implemented")
  }

  func matches(_ other: AnnotationColor) -> Bool {
    abs(color.red - other.red) < 0.02
      && abs(color.green - other.green) < 0.02
      && abs(color.blue - other.blue) < 0.02
  }

  override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let dot = bounds.insetBy(dx: isHovering ? 2 : 3, dy: isHovering ? 2 : 3)
    color.nsColor.setFill()
    NSBezierPath(ovalIn: dot).fill()
    NSColor.labelColor.withAlphaComponent(0.25).setStroke()
    let border = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
    border.lineWidth = 1
    border.stroke()
    if isSelected {
      NSColor.controlAccentColor.setStroke()
      let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
      ring.lineWidth = 1.5
      ring.stroke()
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
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
    isHovering = true
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    isHovering = false
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) {
      onClick?()
    }
  }
}
