import AppKit
import Testing
import VeltoAnnotationCore
@testable import Velto

@MainActor private func toolbarButtons(_ view: NSView) -> [AnnotationToolbarButton] {
  view.subviews.flatMap { child in
    if let button = child as? AnnotationToolbarButton { return [button] }
    return toolbarButtons(child)
  }
}

@Test @MainActor func annotationToolbarShowsChineseHoverTitles() {
  let toolbar = AnnotationToolbarView(frame: .zero)
  let buttons = toolbarButtons(toolbar)
  let titles = Set(buttons.compactMap { $0.accessibilityLabel() })
  for title in ["矩形", "椭圆", "直线", "箭头", "画笔", "马赛克", "文字", "高亮", "序号", "裁剪"] {
    #expect(titles.contains(title))
  }
  #expect(buttons.count == 12)
  #expect(buttons.allSatisfy { ($0.image != nil || $0.title == "Aa") && $0.accessibilityLabel() != nil })
  #expect(buttons.first { $0.accessibilityLabel() == "文字" }?.title == "Aa")
  #expect(buttons.allSatisfy { $0.toolTip?.isEmpty == false })
  #expect(toolbar.barSize.height == 44)
  #expect(toolbar.barSize.width < 500)
}

@Test @MainActor func annotationToolbarHasScrollCaptureButton() throws {
  let toolbar = AnnotationToolbarView(frame: .zero, actionsOnly: true)
  let button = try #require(toolbarButtons(toolbar).first { $0.accessibilityLabel() == "长截图（S）" })
  var scrolls = 0
  toolbar.onAction = { if case .scroll = $0 { scrolls += 1 } }
  button.performClick(nil)
  #expect(scrolls == 1)
  toolbar.setScrollEnabled(false)
  button.performClick(nil)
  #expect(scrolls == 1)
  #expect(toolbar.barSize.width == 44)
}

@Test func scrollCaptureIconIsDrawable() {
  #expect(AnnotationIcon.allCases.contains(.scrollCapture))
  let box = AnnotationIconLibrary.path(for: .scrollCapture).boundingBoxOfPath
  #expect(box.width > 0 && box.height > 0)
}

/// Observe tooltip presentation without showing a test window on the user's desktop.
@MainActor private final class AnnotationHelpHost: NSWindow {
  var presentedHelp: NSWindow?
  var helpOrdering: NSWindow.OrderingMode?
  override var isVisible: Bool { true }
  override func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode) {
    presentedHelp = childWin
    helpOrdering = place
  }
}

@Test @MainActor func annotationHoverHelpCoversOptionsAndDismisses() async throws {
  let host = AnnotationHelpHost(contentRect: CGRect(x: 100, y: 100, width: 800, height: 80),
    styleMask: .borderless, backing: .buffered, defer: false)
  host.level = .screenSaver
  let property = AnnotationPropertyBarView(frame: .zero)
  host.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 80))
  host.contentView!.addSubview(property)
  func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }
  for tool in AnnotationTool.allCases {
    property.update(tool: tool, style: .defaults, cropRect: CGRect(x: 0, y: 0, width: 300, height: 200))
    for view in descendants(property) {
      if let control = view as? NSSegmentedControl {
        #expect(control.toolTip != nil)
        for segment in 0..<control.segmentCount { #expect(control.toolTip(forSegment: segment) != nil) }
      } else if view is NSButton || view is NSSlider || view is NSColorWell || view is AnnotationSwatchButton {
        #expect(view.toolTip?.isEmpty == false)
      }
    }
  }
  property.update(tool: .text, style: .defaults, cropRect: .zero)
  property.frame = CGRect(x: 120, y: 20, width: property.barSize.width, height: property.barSize.height)
  host.contentView!.layoutSubtreeIfNeeded()
  let alignment = try #require(descendants(property).compactMap { $0 as? NSSegmentedControl }.first {
    $0.toolTip == "对齐"
  })
  func hover(_ segment: Int) throws {
    let point = alignment.convert(
      CGPoint(x: alignment.bounds.width * (CGFloat(segment) + 0.5) / 3, y: alignment.bounds.midY), to: nil)
    let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point,
      modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
      eventNumber: 0, clickCount: 0, pressure: 0))
    property.mouseMoved(with: event)
  }
  try hover(1)
  try await Task.sleep(for: .milliseconds(400))
  let help = try #require(host.presentedHelp)
  #expect(host.helpOrdering == .above)
  #expect(help.level.rawValue > host.level.rawValue)
  #expect(help.ignoresMouseEvents)
  #expect(!help.isKeyWindow)
  let label = try #require(help.contentView?.subviews.compactMap { $0 as? NSTextField }.first)
  #expect(label.stringValue.hasPrefix("居中："))
  property.dismissHelp()
  #expect(!help.isVisible)
  host.presentedHelp = nil
  try hover(2)
  // Leaving a button or changing tools must cancel the pending delayed tooltip.
  property.update(tool: .crop, style: .defaults, cropRect: CGRect(x: 0, y: 0, width: 100, height: 80))
  try await Task.sleep(for: .milliseconds(400))
  #expect(host.presentedHelp == nil)
  #expect(descendants(property).compactMap { $0.toolTip }.contains { $0.contains("复制或保存时生效") })
}
