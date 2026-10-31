import AppKit
import CoreText
import Testing
@testable import Velto

private func scrollDocument(width: Int = 320, height: Int = 2400) -> CGImage {
  var pixels = [UInt8](repeating: 255, count: width * height * 4)
  for y in 0..<height {
    for x in 0..<width {
      // Deterministic blocks provide both edges for Vision and unique document rows.
      let seed = UInt64(y / 3 + 1) &* 2_654_435_761 ^ UInt64(x / 5 + 1) &* 2_246_822_519
      for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = UInt8((seed >> (channel * 8)) & 255) }
    }
  }
  return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                 bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                   | CGBitmapInfo.byteOrder32Little.rawValue),
                 provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                 shouldInterpolate: false, intent: .defaultIntent)!
}

private func scrollFrame(_ document: CGImage, at offset: Int, height: Int = 240) -> CGImage {
  normalizedScrollImage(document.cropping(to: CGRect(x: 0, y: offset, width: document.width, height: height))!)
}

private func scrollContext(width: Int, height: Int) -> CGContext {
  CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}

private func normalizedScrollImage(_ image: CGImage) -> CGImage {
  let context = scrollContext(width: image.width, height: image.height)
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return context.makeImage()!
}

private func scrollPixels(_ image: CGImage) -> Data {
  normalizedScrollImage(image).dataProvider!.data! as Data
}

private func framedScrollImage(_ document: CGImage, offset: Int, bodyHeight: Int = 180) -> CGImage {
  let ctx = scrollContext(width: document.width, height: bodyHeight + 60)
  ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: document.width, height: bodyHeight + 60))
  ctx.draw(scrollFrame(document, at: offset, height: bodyHeight),
           in: CGRect(x: 0, y: 24, width: document.width, height: bodyHeight))
  return ctx.makeImage()!
}

@MainActor private func scrollController(first: CGImage) -> ScrollCaptureController {
  let rect = CGRect(x: 0, y: 0, width: first.width, height: first.height)
  return ScrollCaptureController(snapshot: DisplaySnapshot(displayID: 0, image: first, frame: rect, scale: 1),
                                 captureRect: rect, frameCapture: { _ in first })
}

@Test func scrollCaptureLocksAllHorizontalWheelRepresentations() throws {
  let rect = CGRect(x: 0, y: 0, width: 500, height: 500)
  let tap = ScrollCaptureKeyTap(preferences: .defaults, captureRect: rect)
  tap.update(captureRect: rect, controlRects: [], allowsScrolling: true)
  let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 3, wheel1: -30, wheel2: 18, wheel3: 7))
  event.flags = []
  event.location = CGPoint(x: 50, y: 50)
  let result = tap.handle(type: .scrollWheel, event: event)?.takeUnretainedValue()
  #expect(result != nil)
  #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) != 0)
  for field in [CGEventField.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2,
                .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventDeltaAxis3,
                .scrollWheelEventPointDeltaAxis3, .scrollWheelEventFixedPtDeltaAxis3] {
    #expect(event.getDoubleValueField(field) == 0)
  }
}

@Test @MainActor func scrollCaptureKeepsSmallFinalScroll() async {
  let document = scrollDocument()
  let first = scrollFrame(document, at: 0)
  let controller = scrollController(first: first)
  #expect(await controller.startSession())
  #expect(await controller.process(currentFrame: scrollFrame(document, at: 17), isSettled: true))
  #expect(controller.stitchedPixelSize.height == 257)
  controller.cancelSession()
}

@Test @MainActor func scrollCaptureAcceptsCleanOverlap() async {
  let document = scrollDocument()
  let first = scrollFrame(document, at: 0)
  let controller = scrollController(first: first)
  #expect(await controller.startSession())
  #expect(await controller.process(currentFrame: scrollFrame(document, at: 80), isSettled: true))
  #expect(controller.stitchedPixelSize.height == 320)
  #expect(scrollPixels(controller.stitchedImage!) == scrollPixels(scrollFrame(document, at: 0, height: 320)))
  controller.cancelSession()
}

@Test(arguments: [1, 2, 7, 17, 40, 96, 157, 168])
@MainActor func scrollCaptureExactOffsets(_ offset: Int) async {
  let document = scrollDocument()
  let controller = scrollController(first: scrollFrame(document, at: 0))
  #expect(await controller.startSession())
  #expect(await controller.process(currentFrame: scrollFrame(document, at: offset), isSettled: true))
  #expect(controller.stitchedPixelSize.height == CGFloat(240 + offset))
  #expect(scrollPixels(controller.stitchedImage!) == scrollPixels(scrollFrame(document, at: 0, height: 240 + offset)))
}

@Test @MainActor func scrollCaptureReverseAndResumeDoesNotRepeatRows() async {
  let document = scrollDocument()
  let controller = scrollController(first: scrollFrame(document, at: 0))
  #expect(await controller.startSession())
  var frontier = 0
  for offset in [1, 9, 80, 155, 94, 140, 166, 245, 400, 410, 410] {
    #expect(await controller.process(currentFrame: scrollFrame(document, at: offset), isSettled: true) == (offset > frontier))
    frontier = max(frontier, offset)
    #expect(controller.stitchedPixelSize.height == CGFloat(frontier + 240))
  }
  #expect(scrollPixels(controller.stitchedImage!) == scrollPixels(scrollFrame(document, at: 0, height: 650)))
}

@Test @MainActor func scrollCaptureNeverRebasesAcrossMissingContent() async {
  let document = scrollDocument()
  let controller = scrollController(first: scrollFrame(document, at: 0))
  #expect(await controller.startSession())
  for offset in [650, 730, 810, 900] {
    #expect(await !controller.process(currentFrame: scrollFrame(document, at: offset), isSettled: true))
    #expect(controller.stitchedPixelSize.height == 240)
    #expect(controller.issue == .alignment)
  }
  #expect(await controller.process(currentFrame: scrollFrame(document, at: 100), isSettled: true))
  #expect(controller.issue == nil)
  #expect(scrollPixels(controller.stitchedImage!) == scrollPixels(scrollFrame(document, at: 0, height: 340)))
}

@Test @MainActor func scrollCaptureKeepsFixedHeaderAndSingleFooter() async {
  let document = scrollDocument()
  let first = framedScrollImage(document, offset: 0)
  let controller = scrollController(first: first)
  #expect(await controller.startSession())
  for offset in [17, 80, 151] {
    #expect(await controller.process(currentFrame: framedScrollImage(document, offset: offset), isSettled: true))
    #expect(controller.stitchedPixelSize.height == CGFloat(240 + offset))
    #expect(scrollPixels(controller.stitchedImage!) == scrollPixels(framedScrollImage(document, offset: 0, bodyHeight: 180 + offset)))
  }
}

@Test @MainActor func scrollCaptureRejectsHorizontalAndUnrelatedFrames() async {
  let document = scrollDocument(width: 400)
  let first = normalizedScrollImage(document.cropping(to: CGRect(x: 0, y: 0, width: 320, height: 240))!)
  let controller = scrollController(first: first)
  #expect(await controller.startSession())
  for x in [1, 5, 40] {
    let shifted = normalizedScrollImage(document.cropping(to: CGRect(x: x, y: 80, width: 320, height: 240))!)
    #expect(await !controller.process(currentFrame: shifted, isSettled: true))
    #expect(controller.stitchedPixelSize.height == 240)
  }
}

@Test func scrollCaptureRejectsAmbiguousRepeatedPatterns() {
  let tile = scrollDocument(height: 48)
  let context = scrollContext(width: 320, height: 720)
  for y in stride(from: 0, to: 720, by: 48) { context.draw(tile, in: CGRect(x: 0, y: y, width: 320, height: 48)) }
  let document = context.makeImage()!
  #expect(ScrollFrameMatcher.match(current: scrollFrame(document, at: 17), previous: scrollFrame(document, at: 0)) == nil)
  // 完全相同的重复帧只能判为无变化,不能凭空增长。
  #expect(ScrollFrameMatcher.match(current: scrollFrame(document, at: 48), previous: scrollFrame(document, at: 0))?.offset == 0)
}

@Test func scrollCaptureSparseTextAndBlankMargins() {
  let context = scrollContext(width: 600, height: 1800)
  context.setFillColor(CGColor(gray: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 600, height: 1800))
  for row in 0..<60 {
    context.textPosition = CGPoint(x: 24, y: 1800 - row * 30 - 24)
    let text = NSAttributedString(string: "Line \(row): vertical capture keeps every row.",
      attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil),
                   .foregroundColor: CGColor(gray: 0.1, alpha: 1)])
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
  }
  let document = context.makeImage()!
  for offset in [1, 17, 83, 181] {
    #expect(ScrollFrameMatcher.match(current: scrollFrame(document, at: offset, height: 400),
      previous: scrollFrame(document, at: 0, height: 400))?.offset == offset)
  }
}

@Test @MainActor func scrollCaptureFinishFlushesLastFrame() async {
  let document = scrollDocument()
  var offset = 0
  let rect = CGRect(x: 0, y: 0, width: 320, height: 240)
  let controller = ScrollCaptureController(snapshot: DisplaySnapshot(displayID: 0, image: document, frame: rect, scale: 1),
    captureRect: rect, frameCapture: { _ in scrollFrame(document, at: offset) })
  #expect(await controller.startSession())
  offset = 17
  let result = await controller.finishSession()
  #expect(result?.height == 257)
  #expect(!controller.isActive)
  #expect(scrollPixels(result!) == scrollPixels(scrollFrame(document, at: 0, height: 257)))
}

@Test @MainActor func scrollCaptureFinishAlwaysExportsConfirmedContent() async {
  let document = scrollDocument()
  var offset = 0
  let rect = CGRect(x: 0, y: 0, width: 320, height: 240)
  let controller = ScrollCaptureController(snapshot: DisplaySnapshot(displayID: 0, image: document, frame: rect, scale: 1),
    captureRect: rect, frameCapture: { _ in scrollFrame(document, at: offset) })
  #expect(await controller.startSession())
  offset = 700
  #expect(await controller.finishSession()?.height == 240)
  #expect(!controller.isActive)
  #expect(controller.issue == .alignment)
}

@Test @MainActor func scrollCaptureExtensionKeepsBaselineAndPendingScroll() async {
  let document = scrollDocument()
  var offset = 0
  let screen = CGRect(x: 0, y: 0, width: 320, height: 800)
  let rect = CGRect(x: 0, y: 500, width: 320, height: 240)
  // 首帧之后原选区一律不供帧:采样循环会抢在下面的手动 process 之前拼上,打乱时序。
  // 扩大选区的请求来自 extendBottom,照常供。
  var opening = true
  let controller = ScrollCaptureController(snapshot: DisplaySnapshot(displayID: 0, image: document, frame: screen, scale: 1),
    captureRect: rect, frameCapture: { region in
      if region.height <= rect.height {
        guard opening else { return nil }
        opening = false
      }
      return scrollFrame(document, at: offset, height: Int(region.height))
    })
  #expect(await controller.startSession())
  offset = 80
  #expect(await controller.process(currentFrame: scrollFrame(document, at: offset), isSettled: true))
  offset = 87
  #expect(await controller.extendBottom(byPoints: 60))
  #expect(controller.stitchedPixelSize.height == 387)
  offset = 105
  _ = await controller.process(currentFrame: scrollFrame(document, at: offset, height: 300), isSettled: true)
  #expect(scrollPixels(controller.stitchedImage!) == scrollPixels(scrollFrame(document, at: 0, height: 405)))
  #expect(!(await controller.extendBottom(byPoints: .infinity)))
  #expect(!(await controller.extendBottom(byPoints: 600)))
}

@Test @MainActor func scrollCaptureCancelledStartCannotResurrectSession() async {
  // 首帧抓取要慢到取消能落在 startSession 途中,否则它瞬间就返回了,测不到复活。
  let frame = scrollFrame(scrollDocument(), at: 0)
  let rect = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
  let controller = ScrollCaptureController(
    snapshot: DisplaySnapshot(displayID: 0, image: frame, frame: rect, scale: 1),
    captureRect: rect,
    frameCapture: { _ in try? await Task.sleep(for: .milliseconds(80)); return frame })
  let task = Task { await controller.startSession() }
  try? await Task.sleep(for: .milliseconds(10))
  controller.cancelSession()
  #expect(!(await task.value))
  #expect(!controller.isActive)
  #expect(controller.stitchedImage == nil)
}

@Test func scrollCaptureLocksRegionModifiersAndPageDrag() throws {
  let rect = CGRect(x: -400, y: -200, width: 300, height: 240)
  let control = CGRect(x: -440, y: -240, width: 80, height: 30)
  let tap = ScrollCaptureKeyTap(preferences: .defaults, captureRect: rect)
  tap.update(captureRect: rect, controlRects: [control], allowsScrolling: true)
  let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
    wheelCount: 2, wheel1: -20, wheel2: 0, wheel3: 0))
  wheel.flags = []
  wheel.location = CGPoint(x: -300, y: -100)
  wheel.flags = .maskShift
  #expect(tap.handle(type: .scrollWheel, event: wheel) != nil)
  #expect(!wheel.flags.contains(.maskShift))
  wheel.flags = .maskCommand
  #expect(tap.handle(type: .scrollWheel, event: wheel) == nil)
  wheel.flags = []
  wheel.location = .zero
  #expect(tap.handle(type: .scrollWheel, event: wheel) == nil)
  wheel.location = CGPoint(x: -300, y: -100)
  tap.update(captureRect: rect, controlRects: [control], allowsScrolling: false)
  #expect(tap.handle(type: .scrollWheel, event: wheel) == nil)
  let click = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                  mouseCursorPosition: wheel.location, mouseButton: .left))
  click.flags = []
  #expect(tap.handle(type: .leftMouseDown, event: click) == nil)
  #expect(tap.handle(type: .leftMouseDragged, event: click) == nil)
  click.location = CGPoint(x: control.midX, y: control.midY)
  #expect(tap.handle(type: .leftMouseDown, event: click) != nil)
  click.location = .zero
  #expect(tap.handle(type: .leftMouseDragged, event: click) != nil)
  #expect(tap.handle(type: .leftMouseUp, event: click) != nil)
  #expect(tap.handle(type: .leftMouseDragged, event: click) == nil)
  for key in [UInt16(123), 124, 115, 119, 116, 121] {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
    event.flags = []
    #expect(tap.handle(type: .keyDown, event: event) == nil)
  }
  #expect(DisplayCoordinateConverter.flipped(CGRect(x: -500, y: 1100, width: 300, height: 200),
    primaryHeight: 1080) == CGRect(x: -500, y: -220, width: 300, height: 200))
}

@Test func scrollCaptureSeededOverlapSweep() {
  let document = scrollDocument(width: 96, height: 1800)
  var state: UInt64 = 0x1234ABCD
  for _ in 0..<80 {
    state = state &* 6_364_136_223_846_793_005 &+ 1
    let origin = Int(state % 1000)
    let offset = Int((state >> 32) % 130) + 1
    let result = ScrollFrameMatcher.match(current: scrollFrame(document, at: origin + offset),
      previous: scrollFrame(document, at: origin))
    #expect(result?.offset == offset, "origin=\(origin), offset=\(offset)")
  }
}

@Test func scrollCaptureRetinaMatchingBudget() {
  let document = scrollDocument(width: 1280, height: 2400)
  let previous = scrollFrame(document, at: 0, height: 1440)
  let current = scrollFrame(document, at: 327, height: 1440)
  let start = ContinuousClock.now
  #expect(ScrollFrameMatcher.match(current: current, previous: previous)?.offset == 327)
  print("Scroll matcher 1280x1440: \(start.duration(to: .now))")
}

@Test @MainActor func scrollCaptureFinishDuringAnimationExportsConfirmedContent() async {
  let document = scrollDocument()
  var animating = false, count = 0
  let rect = CGRect(x: 0, y: 0, width: 320, height: 240)
  let controller = ScrollCaptureController(snapshot: DisplaySnapshot(displayID: 0, image: document, frame: rect, scale: 1),
    captureRect: rect, frameCapture: { _ in
      count += 1
      return scrollFrame(document, at: animating ? 80 + count % 2 : 0)
    })
  #expect(await controller.startSession())
  animating = true
  // 收尾时画面还在动不再判失败:末帧只要过得了像素重叠校验就照样接上。
  #expect(await controller.finishSession()?.height ?? 0 >= 240)
  #expect(controller.issue == nil)
  #expect(!controller.isActive)
}

@Test @MainActor func scrollCaptureCancelledFinalFrameCannotMutateImage() async {
  let document = scrollDocument()
  var delay = false
  let rect = CGRect(x: 0, y: 0, width: 320, height: 240)
  let controller = ScrollCaptureController(snapshot: DisplaySnapshot(displayID: 0, image: document, frame: rect, scale: 1),
    captureRect: rect, frameCapture: { _ in
      if delay { try? await Task.sleep(for: .milliseconds(200)) }
      return scrollFrame(document, at: delay ? 80 : 0)
    })
  #expect(await controller.startSession())
  delay = true
  let task = Task { await controller.finishSession() }
  try? await Task.sleep(for: .milliseconds(10))
  controller.cancelSession()
  task.cancel()
  #expect(await task.value == nil)
  #expect(controller.stitchedPixelSize.height == 240)
  #expect(!controller.isActive)
}

@Test func scrollCaptureRejectsResizedOrTinyFrames() {
  let document = scrollDocument()
  #expect(ScrollFrameMatcher.match(current: scrollFrame(document, at: 80, height: 239),
    previous: scrollFrame(document, at: 0)) == nil)
  let tiny = scrollDocument(width: 3, height: 40)
  #expect(ScrollFrameMatcher.match(current: tiny, previous: tiny) == nil)
}

@Test func scrollCaptureChecksUpperOverlapAndPaddedRows() {
  let document = scrollDocument()
  let previous = scrollFrame(document, at: 0)
  let current = scrollFrame(document, at: 80)
  let context = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8,
    bytesPerRow: 320 * 4 + 64, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
  context.draw(current, in: CGRect(x: 0, y: 0, width: 320, height: 240))
  #expect(ScrollFrameMatcher.match(current: context.makeImage()!, previous: previous)?.offset == 80)
  // 上半段发生动态替换;只验证重叠区下半段会错误接受这帧。
  context.setFillColor(CGColor(gray: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 160, width: 320, height: 35))
  #expect(ScrollFrameMatcher.match(current: context.makeImage()!, previous: previous) == nil)
}

@Test func scrollCaptureToleratesAnimatedStickerInOverlap() {
  // 聊天里的动图表情只占几列,两帧之间换了画面:其余内容严格吻合就该接上,而不是整帧拒掉。
  let document = scrollDocument()
  let previous = scrollFrame(document, at: 0)
  func animated(_ frame: CGImage) -> CGImage {
    let context = scrollContext(width: frame.width, height: frame.height)
    context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
    context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 200, y: 60, width: 80, height: 90))
    return context.makeImage()!
  }
  #expect(ScrollFrameMatcher.match(current: animated(scrollFrame(document, at: 80)), previous: previous)?.offset == 80)
  // 没滚、只有动图在动:认成静止,不报对不上。
  #expect(ScrollFrameMatcher.match(current: animated(previous), previous: previous)?.offset == 0)
}

@Test @MainActor func scrollCaptureHeightLimitKeepsContinuousPrefix() async {
  let document = scrollDocument(width: 32, height: 30100)
  let first = scrollFrame(document, at: 0, height: 29950)
  let controller = scrollController(first: first)
  #expect(await controller.startSession())
  #expect(await !controller.process(currentFrame: scrollFrame(document, at: 80, height: 29950), isSettled: true))
  #expect(controller.issue == .limit)
  #expect(controller.stitchedPixelSize.height == 29950)
  let result = await controller.finishSession()
  #expect(result?.height == 29950)
  #expect(scrollPixels(result!) == scrollPixels(first))
}

@Test func scrollCaptureMouseWheelFallbackPreservesDirectionAndAxisLock() throws {
  var preferences = MouseControlPreferences.defaults
  preferences.enabled = true
  preferences.scroll.reverse = true
  preferences.scroll.reverseVertical = true
  preferences.scroll.smooth = true
  preferences.scroll.smoothVertical = true
  preferences.hotkeys.directionToggle = MouseInputTrigger(kind: .keyboard,
    code: MouseKeyCodes.leftShift, modifierFlags: 0, displayName: "⇧")
  let mouse = MouseControlController()
  mouse.updatePreferences(preferences)
  let shiftEvent = try #require(CGEvent(keyboardEventSource: nil,
    virtualKey: MouseKeyCodes.leftShift, keyDown: true))
  shiftEvent.flags = .maskShift
  _ = mouse.handleTriggerEvent(type: .flagsChanged, event: shiftEvent,
    normalizedFlags: CGEventFlags.maskShift.rawValue)

  let rect = CGRect(x: 0, y: 0, width: 500, height: 500)
  let tap = ScrollCaptureKeyTap(preferences: .defaults, captureRect: rect)
  tap.update(captureRect: rect, controlRects: [], allowsScrolling: true)
  let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
    wheelCount: 2, wheel1: -3, wheel2: 2, wheel3: 0))
  wheel.flags = []
  wheel.location = CGPoint(x: 100, y: 100)
  wheel.flags = .maskShift
  #expect(tap.handle(type: .scrollWheel, event: wheel) != nil)
  // 平滑无法启动(此事件无目标进程)时透传,并保留用户的鼠标反转方向。
  #expect(!mouse.handleScrollWheel(event: wheel, captureLocked: true))
  #expect(wheel.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3)
  #expect(wheel.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) == 0)
  #expect(wheel.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0)
}

@Test @MainActor func scrollCaptureCancelEndsEntireSessionOnce() {
  _ = NSApplication.shared
  var finished = 0
  let session = ScreenshotSession(snapshots: [], preferences: .defaults) { finished += 1 }
  session.cancelScrollCapture()
  #expect(finished == 1)
  session.cancel()
  #expect(finished == 1)
}

@Test @MainActor func scrollCaptureRetainsMouseWheelSpeedAndSmoothOutput() async throws {
  var preferences = MouseControlPreferences.defaults
  preferences.enabled = true
  preferences.scroll.reverse = true
  preferences.scroll.reverseVertical = true
  preferences.scroll.smooth = true
  preferences.scroll.smoothVertical = true
  preferences.scroll.minStep = 38.6
  preferences.scroll.speedGain = 3.35
  let mouse = MouseControlController()
  mouse.updatePreferences(preferences)
  func attach() {
    mouse.attachScrollRunLoop(CFRunLoopGetCurrent(), thread: Thread.current,
                              displayLink: mouse.makeScrollDisplayLink())
  }
  attach()
  defer { mouse.detachScrollRunLoop() }
  var outputs: [Double] = []
  mouse.animator.eventPoster = { event, _ in
    outputs.append(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
    #expect(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) == 0)
  }
  let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
    wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
  wheel.flags = []
  wheel.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(getpid()))
  wheel.location = CGPoint(x: 100, y: 100)
  let rect = CGRect(x: 0, y: 0, width: 500, height: 500)
  let tap = ScrollCaptureKeyTap(preferences: .defaults, captureRect: rect)
  tap.update(captureRect: rect, controlRects: [], allowsScrolling: true)
  var activities = 0
  tap.onScrollActivity = { activities += 1 }
  ScrollCaptureKeyTap.active.withLock { $0 = tap }
  #expect(mouse.handleScrollWheel(event: wheel, captureLocked: true))
  for _ in 0..<120 { mouse.animator.processing(dt: 1.0 / 120) }
  #expect(outputs.filter { $0 > 0 }.count > 1)
  #expect(outputs.allSatisfy { $0 >= 0 })
  #expect(outputs.reduce(0, +) > 80)
  // 暂停捕获时丢弃剩余惯性,重新允许滚动不会恢复旧尾巴。
  tap.update(captureRect: rect, controlRects: [], allowsScrolling: false)
  let beforePause = outputs.count
  mouse.animator.processing(dt: 1.0 / 60)
  tap.update(captureRect: rect, controlRects: [], allowsScrolling: true)
  mouse.animator.processing(dt: 1.0 / 60)
  #expect(outputs.count == beforePause)
  ScrollCaptureKeyTap.active.withLock { $0 = nil }
  // 验证合成帧真的通知捕获器,避免物理滚轮停了而动画还在滚时漏抓。
  await withCheckedContinuation { continuation in
    DispatchQueue.main.async { continuation.resume() }
  }
  #expect(activities == beforePause)
  tap.stop()
}

@Test @MainActor func scrollCaptureKeysExecuteConfiguredActionsAndStopInvalidatesQueuedKeys() async throws {
  var preferences = ScreenshotPreferences.defaults
  preferences.saveShortcut = Shortcut(keyCode: 35,
    modifierFlags: CGEventFlags([.maskCommand, .maskShift]).rawValue, displayName: "⇧⌘P")
  let tap = ScrollCaptureKeyTap(preferences: preferences,
    captureRect: CGRect(x: 0, y: 0, width: 500, height: 500))
  var copies = 0, saves = 0, cancels = 0
  tap.onCopy = { copies += 1 }
  tap.onSave = { saves += 1 }
  tap.onCancel = { cancels += 1 }
  for code: CGKeyCode in [49, 36, 35, 53] {
    let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
    key.flags = []
    if code == 35 { key.flags = [.maskCommand, .maskShift, .maskAlphaShift] }
    #expect(tap.handle(type: .keyDown, event: key) == nil)
    key.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    #expect(tap.handle(type: .keyDown, event: key) == nil)
    #expect(tap.handle(type: .keyUp, event: key) == nil)
  }
  await withCheckedContinuation { continuation in
    DispatchQueue.main.async { continuation.resume() }
  }
  #expect(copies == 2)
  #expect(saves == 1)
  #expect(cancels == 1)
  let space = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
  space.flags = []
  _ = tap.handle(type: .keyDown, event: space)
  tap.stop()
  _ = tap.handle(type: .keyDown, event: space)
  await withCheckedContinuation { continuation in
    DispatchQueue.main.async { continuation.resume() }
  }
  #expect(copies == 2)
}

@Test @MainActor func scrollCaptureInertiaNeverCrossesSessionBoundaries() throws {
  let animator = MouseSmoothScrollAnimator()
  animator.attach(runLoop: CFRunLoopGetCurrent(), thread: Thread.current,
                  displayLink: animator.makeDisplayLink())
  defer { animator.detach() }
  var delivered = 0
  animator.eventPoster = { _, _ in delivered += 1 }
  let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
    wheelCount: 2, wheel1: 1, wheel2: 2, wheel3: 0))
  wheel.flags = []
  wheel.location = CGPoint(x: 100, y: 100)
  wheel.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(getpid()))
  var profile = MouseScrollProfile.defaults
  profile.simulateTrackpad = false
  func submit() { animator.submit(event: wheel, debugID: 0, profile: profile,
                                 y: 50, x: 30, speedMultiplier: 1) }
  let rect = CGRect(x: 0, y: 0, width: 500, height: 500)
  let first = ScrollCaptureKeyTap(preferences: .defaults, captureRect: rect)
  first.update(captureRect: rect, controlRects: [], allowsScrolling: true)
  submit()
  let beforeEnter = delivered
  ScrollCaptureKeyTap.active.withLock { $0 = first }
  animator.processing(dt: 1.0 / 60)
  #expect(delivered == beforeEnter, "进入截图不能放行旧的横向惯性")
  submit()
  animator.eventPoster = { event, _ in
    delivered += 1
    #expect(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) == 0)
  }
  animator.processing(dt: 1.0 / 60)
  #expect(delivered > beforeEnter)
  let beforeCancel = delivered
  first.stop()
  animator.processing(dt: 1.0 / 60)
  #expect(delivered == beforeCancel, "取消后不能继续滚动目标页面")
  let second = ScrollCaptureKeyTap(preferences: .defaults, captureRect: rect)
  second.update(captureRect: rect, controlRects: [], allowsScrolling: true)
  ScrollCaptureKeyTap.active.withLock { $0 = second }
  defer { second.stop() }
  animator.processing(dt: 1.0 / 60)
  #expect(delivered == beforeCancel, "新会话不能恢复前一会话的惯性")
  submit()
  animator.processing(dt: 1.0 / 60)
  #expect(delivered > beforeCancel, "新会话仍可正常向下滚动")
}

@Test @MainActor func scrollCaptureSaveShortcutWritesImageDespiteAlignmentWarning() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  var preferences = ScreenshotPreferences.defaults
  preferences.saveDirectoryPath = folder.path
  preferences.saveAlsoCopiesToClipboard = false
  let document = scrollDocument()
  var offset = 0
  let rect = CGRect(x: 0, y: 0, width: 320, height: 240)
  let controller = ScrollCaptureController(snapshot: DisplaySnapshot(displayID: 0, image: document, frame: rect, scale: 1),
    captureRect: rect, frameCapture: { _ in scrollFrame(document, at: offset) })
  #expect(await controller.startSession())
  #expect(await controller.process(currentFrame: scrollFrame(document, at: 80), isSettled: true))
  offset = 700
  #expect(!(await controller.process(currentFrame: scrollFrame(document, at: offset), isSettled: true)))
  #expect(controller.issue == .alignment)
  var finished = 0
  let session = ScreenshotSession(snapshots: [], preferences: preferences) { finished += 1 }
  session.scrollController = controller
  let tap = ScrollCaptureKeyTap(preferences: preferences, captureRect: rect)
  tap.onSave = { session.finishScrollCapture(.save) }
  let save = try #require(CGEvent(keyboardEventSource: nil,
    virtualKey: preferences.saveShortcut.keyCode, keyDown: true))
  save.flags = CGEventFlags(rawValue: preferences.saveShortcut.modifierFlags)
  _ = tap.handle(type: .keyDown, event: save)
  for _ in 0..<100 where finished == 0 { try? await Task.sleep(for: .milliseconds(20)) }
  tap.stop()
  #expect(finished == 1)
  let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
  #expect(files.count == 1)
  let file = try #require(files.first)
  let image = try #require(NSBitmapImageRep(data: Data(contentsOf: file))?.cgImage)
  #expect(image.height == 320)
  #expect(scrollPixels(normalizedScrollImage(image)) == scrollPixels(scrollFrame(document, at: 0, height: 320)))
}

@Test @MainActor func scrollCaptureCancelDuringSaveProducesNoFile() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  var preferences = ScreenshotPreferences.defaults
  preferences.saveDirectoryPath = folder.path
  let document = scrollDocument()
  var delay = false
  let rect = CGRect(x: 0, y: 0, width: 320, height: 240)
  let controller = ScrollCaptureController(snapshot: DisplaySnapshot(displayID: 0, image: document, frame: rect, scale: 1),
    captureRect: rect, frameCapture: { _ in
      if delay { try? await Task.sleep(for: .milliseconds(150)) }
      return scrollFrame(document, at: delay ? 80 : 0)
    })
  #expect(await controller.startSession())
  var finished = 0
  let session = ScreenshotSession(snapshots: [], preferences: preferences) { finished += 1 }
  session.scrollController = controller
  delay = true
  session.finishScrollCapture(.save)
  try? await Task.sleep(for: .milliseconds(10))
  session.cancelScrollCapture()
  try? await Task.sleep(for: .milliseconds(250))
  #expect(finished == 1)
  #expect(!controller.isActive)
  #expect(session.scrollController == nil)
  #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
}

@Test @MainActor func scrollCaptureSamplesWithoutPhysicalWheelNotifications() async {
  let document = scrollDocument()
  var offset = 0
  let rect = CGRect(x: 0, y: 0, width: 320, height: 240)
  let controller = ScrollCaptureController(snapshot: DisplaySnapshot(displayID: 0, image: document, frame: rect, scale: 1),
    captureRect: rect, frameCapture: { _ in scrollFrame(document, at: offset) })
  #expect(await controller.startSession())
  defer { controller.cancelSession() }
  offset = 80
  // 等的是采样循环(50ms 一帧 + 一次拼接)落地。别用固定次数的轮询上限:全量并行跑
  // 时每次 sleep 都被拖长,40 次早早耗尽而拼接还没轮到,断言当场假红(CPU 压满时实测
  // 复现)。改成挂钟兜底,正常路径仍是拼上就走。
  let deadline = Date().addingTimeInterval(5)
  while controller.stitchedPixelSize.height == 240, Date() < deadline {
    try? await Task.sleep(for: .milliseconds(25))
  }
  #expect(controller.stitchedPixelSize.height == 320)
  #expect(scrollPixels(controller.stitchedImage!) == scrollPixels(scrollFrame(document, at: 0, height: 320)))
}

@Test func scrollCaptureRegistrationRecoversContentBetweenCoarseColumns() {
  let width = 600, height = 1600
  let original = scrollDocument(width: width, height: height)
  var pixels = [UInt8](scrollPixels(original))
  let sampled = Set((0..<32).map { 4 + $0 * (width - 32 - 4 - 1) / 31 })
  // Every coarse column is blank; only dense validation and registration see
  // the content. This exercises the Vision fallback rather than the fast path.
  for y in 0..<height {
    for x in 0..<width where sampled.contains(x) {
      for c in 0..<3 { pixels[(y * width + x) * 4 + c] = 255 }
    }
  }
  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
      | CGBitmapInfo.byteOrder32Little.rawValue), provider: CGDataProvider(data: Data(pixels) as CFData)!,
    decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  for offset in [17, 83, 181] {
    #expect(ScrollFrameMatcher.match(current: scrollFrame(image, at: offset, height: 400),
      previous: scrollFrame(image, at: 0, height: 400))?.offset == offset)
  }
}

/// Core Animation / fractional capture regions can change the rasterization phase
/// between frames. Integer crops of one bitmap cannot reproduce that failure.
@Test @MainActor func scrollCaptureSubpixelTextGrowsWithoutDrift() async {
  let width = 1280, height = 2400
  let context = scrollContext(width: width, height: height)
  context.setFillColor(CGColor(gray: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  for row in 0..<48 {
    context.textPosition = CGPoint(x: 24, y: height - row * 48 - 36)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
      string: "Row \(row) — 滚动截图连续性验证: Keep every line \(row * 7937).",
      attributes: [.font: CTFontCreateWithName("PingFangSC-Regular" as CFString, 26, nil),
                   .foregroundColor: CGColor(gray: 0.1, alpha: 1)])), context)
  }
  let document = context.makeImage()!
  func frame(_ offset: Double, x: Double = 0, fixedChrome: Bool = false) -> CGImage {
    let context = scrollContext(width: width, height: 600)
    context.interpolationQuality = .high
    context.draw(document, in: CGRect(x: -x, y: Double(600 - height) + offset,
      width: Double(width), height: Double(height)))
    if fixedChrome {
      context.setFillColor(CGColor(gray: 0.2, alpha: 1))
      context.fill(CGRect(x: 0, y: 564, width: width, height: 36))
      context.fill(CGRect(x: 0, y: 0, width: width, height: 24))
    }
    return context.makeImage()!
  }
  let first = frame(0)
  for offset in [80.25, 80.5, 80.75] {
    let match = ScrollFrameMatcher.match(current: frame(offset), previous: first)
    #expect(match != nil)
    #expect(abs(Double(match?.offset ?? 0) - offset) <= 0.5)
  }
  for x in [1.0, 5.0] {
    #expect(ScrollFrameMatcher.match(current: frame(80.5, x: x), previous: first) == nil)
  }
  let controller = scrollController(first: first)
  #expect(await controller.startSession())
  for step in 1...20 {
    let position = Double(step) * 80.5
    #expect(await controller.process(currentFrame: frame(position), isSettled: true))
    #expect(abs(Double(controller.stitchedPixelSize.height) - 600 - position) <= 1)
  }
  // Normalization is only for matching. Appended pixels must remain the source pixels.
  let lastStrip = controller.stitchedImage!.cropping(to: CGRect(x: 0,
    y: controller.stitchedImage!.height - 70, width: width, height: 70))!
  let originalStrip = frame(1610).cropping(to: CGRect(x: 0, y: 530, width: width, height: 70))!
  #expect(scrollPixels(lastStrip) == scrollPixels(originalStrip))
  controller.cancelSession()

  let chrome = scrollController(first: frame(0, fixedChrome: true))
  #expect(await chrome.startSession())
  var frontier = 0.0
  for position in [80.25, 160.5, 90.75, 240.75, 321.0, 401.25] {
    #expect(await chrome.process(currentFrame: frame(position, fixedChrome: true),
      isSettled: true) == (position > frontier))
    frontier = max(frontier, position)
    #expect(abs(Double(chrome.stitchedPixelSize.height) - 600 - frontier) <= 1)
  }
  for rect in [CGRect(x: 0, y: 0, width: width, height: 36),
               CGRect(x: 0, y: chrome.stitchedImage!.height - 24, width: width, height: 24)] {
    let strip = chrome.stitchedImage!.cropping(to: rect)!
    let expected = frame(0, fixedChrome: true).cropping(to: CGRect(x: 0,
      y: rect.minY == 0 ? 0 : 576, width: width, height: Int(rect.height)))!
    #expect(scrollPixels(strip) == scrollPixels(expected))
  }
  chrome.cancelSession()
}

@Test(arguments: [1.0, 2.0])
func scrollCaptureFractionalSelectionUsesOriginalPixelGrid(_ scale: Double) throws {
  let image = scrollDocument(width: Int(640 * scale), height: Int(480 * scale))
  let snapshot = DisplaySnapshot(displayID: 0, image: image,
    frame: CGRect(x: -640, y: -240, width: 640, height: 480), scale: scale)
  for rect in [CGRect(x: -627.875, y: -123.25, width: 210.375, height: 133.75),
               CGRect(x: -645.25, y: -241.125, width: 21.5, height: 33.25), snapshot.frame] {
    let configuration = try #require(ScreenshotCapturer.regionConfiguration(in: snapshot, globalRect: rect))
    let cropped = try #require(ScreenshotCapturer.crop(snapshot, toPointRect: rect))
    #expect(configuration.width == cropped.width)
    #expect(configuration.height == cropped.height)
    #expect(configuration.sourceRect.width * scale == Double(configuration.width))
    #expect(configuration.sourceRect.height * scale == Double(configuration.height))
    #expect(configuration.sourceRect.minX * scale == (configuration.sourceRect.minX * scale).rounded())
    #expect(configuration.sourceRect.minY * scale == (configuration.sourceRect.minY * scale).rounded())
  }
  for rect in [CGRect.zero, CGRect.infinite, CGRect(x: 2000, y: 2000, width: 20, height: 20)] {
    #expect(ScreenshotCapturer.regionConfiguration(in: snapshot, globalRect: rect) == nil)
  }
}

private func scrollImageWithCaret(_ image: CGImage) -> CGImage {
  let ctx = scrollContext(width: image.width, height: image.height)
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  ctx.setFillColor(CGColor(gray: 0, alpha: 1))
  ctx.fill(CGRect(x: 12, y: 20, width: 2, height: 16))
  return ctx.makeImage()!
}

@MainActor private func blinkingController(_ a: CGImage, _ b: CGImage) -> ScrollCaptureController {
  let rect = CGRect(x: 0, y: 0, width: a.width, height: a.height)
  var flip = false
  return ScrollCaptureController(
    snapshot: DisplaySnapshot(displayID: 0, image: a, frame: rect, scale: 1),
    captureRect: rect,
    frameCapture: { _ in flip.toggle(); return flip ? a : b })
}

@Test @MainActor func scrollCaptureStartsWhileCaretBlinks() async {
  // 抓帧有逐帧噪声、插入点会闪:要求两帧逐字节全等就永远取不到首帧,滚动截图直接起不来。
  let base = scrollFrame(scrollDocument(), at: 0)
  let controller = blinkingController(base, scrollImageWithCaret(base))
  #expect(await controller.startSession())
  controller.cancelSession()
}

@Test @MainActor func scrollCaptureStartsOnMovingPageWithoutStarvingPipeline() async {
  // 画面一直在动(动画/视频)时不能整个功能失败,也不能死等——早先等 30 次约 5 秒并占着
  // 抓帧锁,滚动期间一帧都接不上,最后拼出来只有一屏。
  let document = scrollDocument()
  let a = scrollFrame(document, at: 0)
  let b = scrollFrame(document, at: 40)
  let rect = CGRect(x: 0, y: 0, width: a.width, height: a.height)
  var grabs = 0
  var flip = false
  let controller = ScrollCaptureController(
    snapshot: DisplaySnapshot(displayID: 0, image: a, frame: rect, scale: 1),
    captureRect: rect,
    frameCapture: { _ in grabs += 1; flip.toggle(); return flip ? a : b })
  #expect(await controller.startSession())
  #expect(grabs <= 6)
  controller.cancelSession()
}

@Test @MainActor func scrollCaptureStartsWithSingleGrab() async {
  // 开场只抓一帧就走,不等静止;首帧必须和后续帧同源,否则尺寸差几像素就全程拼不上。
  let document = scrollDocument()
  let frozen = scrollFrame(document, at: 0)
  let rect = CGRect(x: 0, y: 0, width: frozen.width, height: frozen.height)
  var grabs = 0
  let controller = ScrollCaptureController(
    snapshot: DisplaySnapshot(displayID: 0, image: frozen, frame: rect, scale: 1),
    captureRect: rect,
    frameCapture: { _ in grabs += 1; return frozen })
  #expect(await controller.startSession())
  #expect(grabs == 1)
  #expect(controller.stitchedPixelSize.height == CGFloat(frozen.height))
  controller.cancelSession()
}

@Test func scrollCaptureMatcherFailureBudget() {
  let document = scrollDocument(width: 1495, height: 6000)
  let previous = scrollFrame(document, at: 0, height: 1540)
  let far = scrollFrame(document, at: 3000, height: 1540)
  let near = scrollFrame(document, at: 240, height: 1540)
  var start = ContinuousClock.now
  #expect(ScrollFrameMatcher.match(current: far, previous: previous) == nil)
  print("匹配失败(带救援) 1495x1540: \(start.duration(to: .now))")
  start = .now
  #expect(ScrollFrameMatcher.match(current: far, previous: previous, rescue: false) == nil)
  print("匹配失败(无救援) 1495x1540: \(start.duration(to: .now))")
  start = .now
  #expect(ScrollFrameMatcher.match(current: near, previous: previous)?.offset == 240)
  print("匹配成功 1495x1540: \(start.duration(to: .now))")
}

// 离线复盘:用调试日志存下来的真实帧。文件不存在就跳过。
private func loadDebugFrame(_ name: String) -> CGImage? {
  let url = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Velto/scroll-debug/\(name).png")
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
  return shiftedFrame(image, by: 0)
}

/// 内容上移 `rows` 行(模拟向下滚动),底部补白。
private func shiftedFrame(_ image: CGImage, by rows: CGFloat) -> CGImage? {
  guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
  else { return nil }
  context.setFillColor(.white)
  context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
  context.interpolationQuality = rows == rows.rounded() ? .none : .high
  context.draw(image, in: CGRect(x: 0, y: rows, width: CGFloat(image.width), height: CGFloat(image.height)))
  return context.makeImage()
}

@Test func scrollCaptureDebugFramesReplay() {
  guard let previous = loadDebugFrame("previous"), let current = loadDebugFrame("current") else { return }
  var t = ContinuousClock.now
  print("原始两帧:", ScrollFrameMatcher.match(current: current, previous: previous).map { "offset \($0.offset)" } ?? "nil", t.duration(to: .now))
  t = .now
  print("原始两帧无救援:", ScrollFrameMatcher.match(current: current, previous: previous, rescue: false).map { "offset \($0.offset)" } ?? "nil", t.duration(to: .now))
  for d in [60, 200, 400, 700, 60.5, 200.5, 400.25, 400.5] as [CGFloat] {
    let still = shiftedFrame(previous, by: d)!
    let animated = shiftedFrame(current, by: d)!
    let a = ScrollFrameMatcher.match(current: still, previous: previous)
    let b = ScrollFrameMatcher.match(current: animated, previous: previous)
    let t = ContinuousClock.now
    let c = ScrollFrameMatcher.match(current: animated, previous: previous, rescue: false)
    let cost = t.duration(to: .now)
    print("[\(cost)] ","滚 \(d): 无动画 \(a.map { "\($0.offset)" } ?? "nil") | 有动画 \(b.map { "\($0.offset)" } ?? "nil") | 有动画无救援 \(c.map { "\($0.offset)" } ?? "nil")")
  }
}

@Test func scrollCaptureLoopMatchesHalfPixelScroll() {
  // 采样帧不走 Vision 兜底,但必须接得上半像素滚动(Chrome 触控板滚动的常态)。
  let previous = scrollFrame(scrollDocument(), at: 0)
  let current = shiftedFrame(previous, by: 40.5)!
  let offset = ScrollFrameMatcher.match(current: current, previous: previous, rescue: false)?.offset
  #expect(offset == 40 || offset == 41)
}
