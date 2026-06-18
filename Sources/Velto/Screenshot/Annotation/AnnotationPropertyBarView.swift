import AppKit
import VeltoAnnotationCore

/// 跟随当前工具变化的属性条。每个工具只暴露自己相关的控件,改动即时回调
/// `onStyleChange`,由覆盖层把新样式写回编辑器。crop 工具只读显示选区尺寸。
final class AnnotationPropertyBarView: NSGlassEffectView {
  static let barHeight: CGFloat = 34

  var onStyleChange: ((AnnotationStyle) -> Void)?

  private let contentStack = NSStackView()
  private var currentTool: AnnotationTool?
  private var currentStyle = AnnotationStyle.defaults
  private var currentCropRect: CGRect = .zero

  private var colorWell: NSColorWell?
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

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    style = .regular
    cornerRadius = 16
    wantsLayer = true
    layer?.masksToBounds = true

    contentStack.orientation = .horizontal
    contentStack.alignment = .centerY
    contentStack.distribution = .fill
    contentStack.spacing = 8
    contentStack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
    contentView = contentStack
  }

  required init?(coder: NSCoder) {
    fatalError("not implemented")
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
    }
  }

  // MARK: - Build

  private func rebuild(for tool: AnnotationTool?) {
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
    let well = NSColorWell(style: .minimal)
    well.color = currentStyle.strokeColor.nsColor
    well.target = self
    well.action = #selector(controlsChanged)
    NSLayoutConstraint.activate([
      well.widthAnchor.constraint(equalToConstant: 24),
      well.heightAnchor.constraint(equalToConstant: 24),
    ])
    colorWell = well
    contentStack.addArrangedSubview(well)
  }

  private func addLineWidth() {
    let control = makeSegmented(
      labels: Self.lineWidths.map { "\(Int($0))" },
      selected: nearestIndex(of: currentStyle.lineWidth, in: Self.lineWidths)
    )
    lineWidthControl = control
    contentStack.addArrangedSubview(control)
  }

  private func addFillOpacity() {
    contentStack.addArrangedSubview(makeLabel("填充"))
    let slider = makeSlider(value: Double(currentStyle.fillOpacity))
    fillOpacitySlider = slider
    contentStack.addArrangedSubview(slider)
  }

  private func addMosaic() {
    let control = makeSegmented(
      labels: Self.mosaicSizes.map { "\($0)" },
      selected: nearestIndex(of: CGFloat(currentStyle.mosaicBlockSize), in: Self.mosaicSizes.map(CGFloat.init))
    )
    mosaicControl = control
    contentStack.addArrangedSubview(control)
  }

  private func addFontSize() {
    let control = makeSegmented(
      labels: Self.fontSizes.map { "\(Int($0))" },
      selected: nearestIndex(of: currentStyle.fontSize, in: Self.fontSizes)
    )
    fontSizeControl = control
    contentStack.addArrangedSubview(control)
  }

  private func addBold() {
    let button = NSButton(title: "B", target: self, action: #selector(controlsChanged))
    button.setButtonType(.pushOnPushOff)
    button.bezelStyle = .rounded
    button.font = .boldSystemFont(ofSize: 13)
    button.state = currentStyle.isBold ? .on : .off
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 30),
    ])
    boldButton = button
    contentStack.addArrangedSubview(button)
  }

  private func addAlignment() {
    let control = makeSegmented(
      labels: ["左", "中", "右"],
      selected: Self.alignments.firstIndex(of: currentStyle.textAlignment) ?? 0
    )
    alignmentControl = control
    contentStack.addArrangedSubview(control)
  }

  private func addHighlightWidth() {
    let control = makeSegmented(
      labels: ["细", "中", "粗"],
      selected: nearestIndex(of: currentStyle.lineWidth, in: Self.highlightWidths)
    )
    highlightWidthControl = control
    contentStack.addArrangedSubview(control)
  }

  private func addHighlightOpacity() {
    contentStack.addArrangedSubview(makeLabel("浓度"))
    let slider = makeSlider(value: Double(currentStyle.highlightOpacity))
    highlightOpacitySlider = slider
    contentStack.addArrangedSubview(slider)
  }

  private func addSequenceDiameter() {
    let control = makeSegmented(
      labels: Self.sequenceDiameters.map { "\(Int($0))" },
      selected: nearestIndex(of: currentStyle.sequenceDiameter, in: Self.sequenceDiameters)
    )
    sequenceDiameterControl = control
    contentStack.addArrangedSubview(control)
  }

  private func addCropReadout() {
    let label = makeLabel(cropText())
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

  private func makeSegmented(labels: [String], selected: Int) -> NSSegmentedControl {
    let control = NSSegmentedControl(
      labels: labels,
      trackingMode: .selectOne,
      target: self,
      action: #selector(controlsChanged)
    )
    control.segmentStyle = .rounded
    control.selectedSegment = max(0, min(selected, labels.count - 1))
    return control
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
