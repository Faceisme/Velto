import AppKit
import Testing
import VeltoAnnotationCore
@testable import Velto

@MainActor private final class CaptureActions: ScreenshotOverlayDelegate {
  var actions: [ScreenshotSessionAction] = []
  var cancelCount = 0
  var document: AnnotationDocument?
  var region: CGRect?
  func overlayDidActivateSelection(_ overlay: ScreenshotOverlayView) {}
  func overlayDidCancel() { cancelCount += 1 }
  func overlayDidRequest(_ action: ScreenshotSessionAction, globalRect: CGRect, document: AnnotationDocument?) {
    actions.append(action)
    self.document = document
    region = globalRect
  }
}

private func screenshotTestImage(width: Int = 1000, height: Int = 720) -> CGImage {
  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  for row in stride(from: 0, to: height, by: 40) {
    context.setFillColor(CGColor(gray: row % 80 == 0 ? 0.8 : 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: row, width: width, height: 40))
  }
  return context.makeImage()!
}

@MainActor private func pointer(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
  NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
    windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}

@Test @MainActor func screenshotResizeAcrossOppositeEdgeUsesOriginalAnchor() {
  let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 1000, height: 720))
  view.setSelectionGlobalRect(CGRect(x: 100, y: 100, width: 120, height: 120))
  view.mouseDown(with: pointer(.leftMouseDown, 220, 220))
  view.mouseDragged(with: pointer(.leftMouseDragged, 20, 20))
  view.mouseDragged(with: pointer(.leftMouseDragged, 30, 40))
  #expect(view.currentSelectionGlobal == CGRect(x: 30, y: 40, width: 70, height: 60))
}

@Test @MainActor func screenshotCanRedrawEmptySelectionAndToolbarStaysInsideScreen() {
  let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 1000, height: 720))
  view.snapshotImage = screenshotTestImage()
  view.scale = 1
  view.mouseDown(with: pointer(.leftMouseDown, 100, 100))
  view.mouseDragged(with: pointer(.leftMouseDragged, 550, 400))
  view.mouseUp(with: pointer(.leftMouseUp, 550, 400))
  view.mouseDown(with: pointer(.leftMouseDown, 700, 450))
  view.mouseDragged(with: pointer(.leftMouseDragged, 900, 650))
  view.mouseUp(with: pointer(.leftMouseUp, 900, 650))
  #expect(view.currentSelectionGlobal == CGRect(x: 700, y: 450, width: 200, height: 200))
  let bars = view.subviews.compactMap { $0 as? AnnotationToolbarView }
  #expect(bars.count == 2)
  #expect(bars.allSatisfy { view.bounds.contains($0.frame) })
  #expect(!bars[0].frame.intersects(bars[1].frame))
}

@Test func screenshotWindowSnapFollowsVisibleWindowUnderPointer() {
  func window(_ id: Int, _ pid: Int32, _ rect: CGRect, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
    [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
     kCGWindowAlpha as String: alpha, kCGWindowBounds as String: rect.dictionaryRepresentation]
  }
  let a = CGRect(x: 0, y: 0, width: 400, height: 600)
  let b = CGRect(x: 400, y: 0, width: 500, height: 600)
  let point = CGPoint(x: 600, y: 100)
  let windows = [window(3, 99, b, alpha: 0), window(1, 10, a), window(2, 20, b)]
  #expect(WindowFrameDetector.hitWindowBounds(in: windows, atGlobalPoint: point,
    excludingWindowNumbers: [], activeAppPID: 10) == b)
}

@Test @MainActor func screenshotLongImageEditorKeepsFullResolutionAndCopyKeys() throws {
  let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 1000, height: 720))
  view.scale = 2
  view.snapshotImage = screenshotTestImage()
  let actions = CaptureActions()
  view.delegate = actions
  view.presentImageForEditing(screenshotTestImage(width: 1200, height: 4000))
  let scroll = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
  let canvas = try #require(scroll.documentView as? AnnotationCanvasView)
  #expect(canvas.editor.document.canvasSize == CGSize(width: 600, height: 2000))
  #expect(scroll.frame.height < canvas.bounds.height)
  for code: UInt16 in [49, 36] {
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
      isARepeat: false, keyCode: code))
    canvas.keyDown(with: key)
  }
  #expect(actions.actions == [.copy, .copy])
  #expect(actions.document?.canvasSize == CGSize(width: 600, height: 2000))
}

@Test @MainActor func screenshotCropWithoutAnnotationsExportsOnlyCrop() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  var prefs = ScreenshotPreferences.defaults
  prefs.saveDirectoryPath = folder.path
  let rect = CGRect(x: 0, y: 0, width: 500, height: 360)
  let snap = DisplaySnapshot(displayID: 0, image: screenshotTestImage(), frame: rect, scale: 2)
  var finished = 0
  let session = ScreenshotSession(snapshots: [snap], preferences: prefs) { finished += 1 }
  var document = AnnotationDocument(canvasSize: rect.size)
  document.cropRect = CGRect(x: 25, y: 30, width: 150, height: 90)
  session.overlayDidRequest(.save, globalRect: rect, document: document)
  #expect(finished == 1)
  let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
  #expect(files.count == 1)
  let data = try Data(contentsOf: #require(files.first))
  let image = try #require(NSBitmapImageRep(data: data))
  #expect(image.pixelsWide == 300)
  #expect(image.pixelsHigh == 180)
}

@Test @MainActor func screenshotTextEditingSaveAndEscapeKeepSessionSemantics() throws {
  let actions = CaptureActions()
  var prefs = ScreenshotPreferences.defaults
  prefs.annotationLineWidth = 5
  let snap = DisplaySnapshot(displayID: 0, image: screenshotTestImage(),
    frame: CGRect(x: 0, y: 0, width: 1000, height: 720), scale: 1)
  let window = ScreenshotOverlayWindow(screenSnapshot: snap, delegate: actions, activeAppPID: 0, preferences: prefs)
  let overlay = window.screenshotOverlayView
  overlay.presentImageForEditing(screenshotTestImage(width: 600, height: 1600))
  let scroll = try #require(overlay.subviews.compactMap { $0 as? NSScrollView }.first)
  let canvas = try #require(scroll.documentView as? AnnotationCanvasView)
  #expect(canvas.editor.style.lineWidth == 5)
  #expect(abs(canvas.visibleRect.maxY - canvas.bounds.maxY) < 1)
  canvas.onBeginTextEditing?(CGRect(x: 30, y: 40, width: 200, height: 40), nil)
  let editor = try #require(canvas.subviews.compactMap { $0 as? AnnotationTextEditor }.first)
  let textScroll = try #require(editor.subviews.compactMap { $0 as? NSScrollView }.first)
  let text = try #require(textScroll.documentView as? NSTextView)
  text.string = "long capture annotation"
  let save = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "s",
    charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
  #expect(window.performKeyEquivalent(with: save))
  #expect(actions.actions == [.save])
  #expect(actions.document?.elements.count == 1)
  canvas.onBeginTextEditing?(CGRect(x: 30, y: 100, width: 200, height: 40), nil)
  let nextEditor = try #require(canvas.subviews.compactMap { $0 as? AnnotationTextEditor }.first)
  let nextScroll = try #require(nextEditor.subviews.compactMap { $0 as? NSScrollView }.first)
  let nextText = try #require(nextScroll.documentView as? NSTextView)
  #expect(nextEditor.textView(nextText, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
  #expect(actions.cancelCount == 1)
  overlay.tearDownAnnotationUI()
}

@Test @MainActor func screenshotCropAlsoDefinesLongCaptureRegion() throws {
  let overlay = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 1000, height: 720))
  overlay.scale = 1
  overlay.snapshotImage = screenshotTestImage()
  let actions = CaptureActions()
  overlay.delegate = actions
  overlay.mouseDown(with: pointer(.leftMouseDown, 100, 100))
  overlay.mouseDragged(with: pointer(.leftMouseDragged, 600, 500))
  overlay.mouseUp(with: pointer(.leftMouseUp, 600, 500))
  let canvas = try #require(overlay.subviews.compactMap { $0 as? AnnotationCanvasView }.first)
  canvas.editor.updateCrop(CGRect(x: 25, y: 30, width: 300, height: 200))
  let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
    timestamp: 0, windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s",
    isARepeat: false, keyCode: 1))
  canvas.keyDown(with: key)
  #expect(actions.actions == [.scroll])
  #expect(actions.region == CGRect(x: 125, y: 270, width: 300, height: 200))
  #expect(overlay.currentSelectionGlobal == actions.region)
}
