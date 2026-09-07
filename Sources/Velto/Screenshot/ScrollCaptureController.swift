import AppKit
import Foundation

/// 捕获与拼接串行进行;只有通过像素重叠校验的帧才能推进长图和基准。
@MainActor
final class ScrollCaptureController {
  enum Issue { case alignment, capture, limit }

  private(set) var stripCount = 0
  private(set) var stitchedImage: CGImage?
  private(set) var stitchedPixelSize: CGSize = .zero
  private(set) var isActive = false
  private(set) var frozenTopHeight: CGFloat = 0
  private(set) var issue: Issue? {
    didSet { if issue != oldValue { onIssue?(issue) } }
  }
  var onProgress: ((CGImage?, Int) -> Void)?
  var onIssue: ((Issue?) -> Void)?

  private let snapshot: DisplaySnapshot
  private let frameCapture: (@MainActor (CGRect) async -> CGImage?)?
  private var captureRect: CGRect
  private let maxPixelHeight = 30_000
  private let maxPixelCount = 50_000_000
  private var shotA: CGImage?
  private var mergedImage: CGImage?
  private var fractionalOffset = 0.0
  private var generation = 0
  private var captureLoopTask: Task<Void, Never>?
  private var settlementTask: Task<Void, Never>?
  private var isCapturing = false
  private var isFinishing = false

  init(snapshot: DisplaySnapshot, captureRect: CGRect,
       frameCapture: (@MainActor (CGRect) async -> CGImage?)? = nil) {
    self.snapshot = snapshot
    self.captureRect = captureRect
    self.frameCapture = frameCapture
  }

  func startSession() async -> Bool {
    guard !isActive else { return true }
    let token = generation
    guard let first = await captureSettledFrame(), !Task.isCancelled, token == generation,
          first.width >= 16, first.height >= 32,
          first.height <= min(maxPixelHeight, maxPixelCount / first.width) else { return false }
    isActive = true
    isFinishing = false
    shotA = first
    mergedImage = first
    fractionalOffset = 0
    issue = nil
    frozenTopHeight = 0
    stripCount = 1
    stitchedImage = first
    stitchedPixelSize = CGSize(width: first.width, height: first.height)
    emitProgress()
    startCaptureLoop()
    return true
  }

  /// 完成前锁住输入并补齐最后一帧,不能在异步抓帧途中直接返回旧画布。
  func finishSession() async -> CGImage? {
    guard isActive, !isFinishing else { return nil }
    isFinishing = true
    captureLoopTask?.cancel()
    settlementTask?.cancel()
    if issue != .limit { await settledCapture() }
    guard isActive, !Task.isCancelled else { return nil }
    // 用户随时可完成已确认的连续内容;异常末帧不追加,也不吞掉完成操作。
    let result = mergedImage
    stopWork()
    return result
  }

  func cancelSession() { stopWork() }

  private func stopWork() {
    generation += 1
    isActive = false
    captureLoopTask?.cancel()
    captureLoopTask = nil
    settlementTask?.cancel()
    settlementTask = nil
    // 在飞的任务仍持有抓帧锁,由它自己的 defer 释放。
  }

  func noteManualScroll() {
    guard isActive, !isFinishing, issue != .limit else { return }
    settlementTask?.cancel()
    settlementTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      await self?.settledCapture()
    }
  }

  /// CapCap-style independent sampling: page inertia, keyboard scrolling and
  /// application-driven scrolls are captured even without a new wheel event.
  private func startCaptureLoop() {
    guard captureLoopTask == nil else { return }
    captureLoopTask = Task { [weak self] in
      defer { self?.captureLoopTask = nil }
      while !Task.isCancelled {
        guard await self?.captureNextFrame() == true else { return }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  private func captureNextFrame() async -> Bool {
    guard isActive else { return false }
    await grabAndProcess()
    return isActive
  }

  private func captureFrame(rect: CGRect? = nil) async -> CGImage? {
    let image: CGImage?
    if let frameCapture {
      image = await frameCapture(rect ?? captureRect)
    } else {
      image = try? await ScreenshotCapturer.captureRegion(in: snapshot, globalRect: rect ?? captureRect)
    }
    guard !Task.isCancelled, let image else { return nil }
    return normalizeFrame(image)
  }

  /// SCScreenshotManager 可能返回不同像素格式或行 padding;统一为紧凑 BGRA。
  private func normalizeFrame(_ image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
      | CGBitmapInfo.byteOrder32Little.rawValue
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: bitmapInfo
    ) else { return nil }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  private func captureSettledFrame(rect: CGRect? = nil) async -> CGImage? {
    var previous: CGImage?
    for _ in 0..<30 {
      guard !Task.isCancelled else { return nil }
      if let frame = await captureFrame(rect: rect) {
        if let previous, framesPixelEqual(previous, frame) { return frame }
        previous = frame
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    // 超时仍在动画中的画面不是稳定帧,不能当作最终截图。
    return nil
  }

  private func framesPixelEqual(_ a: CGImage, _ b: CGImage) -> Bool {
    guard a.width == b.width, a.height == b.height, a.bytesPerRow == b.bytesPerRow,
          let ad = a.dataProvider?.data, let bd = b.dataProvider?.data,
          CFDataGetLength(ad) == CFDataGetLength(bd),
          let ap = CFDataGetBytePtr(ad), let bp = CFDataGetBytePtr(bd) else { return false }
    return withExtendedLifetime((ad, bd)) { memcmp(ap, bp, CFDataGetLength(ad)) == 0 }
  }

  private func grabAndProcess() async {
    guard isActive, !isCapturing, !isFinishing else { return }
    isCapturing = true
    defer { isCapturing = false }
    guard let frame = await captureFrame(), isActive, !Task.isCancelled else { return }
    _ = await process(currentFrame: frame, isSettled: false)
  }

  private func settledCapture() async {
    guard isActive, !Task.isCancelled else { return }
    while isCapturing {
      try? await Task.sleep(for: .milliseconds(25))
      guard isActive, !Task.isCancelled else { return }
    }
    isCapturing = true
    defer { isCapturing = false }
    let frame = await captureSettledFrame()
    guard isActive, !Task.isCancelled else { return }
    guard let frame else { issue = .capture; return }
    _ = await process(currentFrame: frame, isSettled: true)
  }

  @discardableResult
  func process(currentFrame: CGImage, isSettled: Bool) async -> Bool {
    guard isActive, issue != .limit, let previous = shotA else { return false }
    let match = await Task.detached(priority: .userInitiated) {
      ScrollFrameMatcher.match(current: currentFrame, previous: previous)
    }.value
    guard isActive, !Task.isCancelled, shotA === previous else { return false }
    guard let match else {
      if isSettled { issue = .alignment }
      if isSettled { ScreenshotDebugLog.log("滚动拼接:重叠不可信,保留原基准") }
      return false
    }
    // 向上回看不改变最远位置的基准;再次向下越过该位置才追加。
    let displacement = Double(match.offset) + match.fraction + fractionalOffset
    let offset = Int(displacement.rounded())
    guard offset > 0 else {
      issue = nil
      return false
    }
    guard mergeNewContent(currentFrame: currentFrame, offsetPx: offset, footer: match.footer) else {
      issue = .limit
      return false
    }
    shotA = currentFrame
    fractionalOffset = displacement - Double(offset)
    issue = nil
    frozenTopHeight = CGFloat(match.header) / snapshot.scale
    stripCount += 1
    emitProgress()
    ScreenshotDebugLog.log("滚动拼接:追加 \(offset)px header=\(match.header) footer=\(match.footer) height=\(mergedImage?.height ?? 0)")
    return true
  }

  /// 同一张稳定的扩大选区帧同时提供旧区和新增条带,避免两次抓屏之间发生滚动。
  func extendBottom(byPoints delta: CGFloat) async -> Bool {
    guard isActive, !isFinishing, delta.isFinite, delta >= 1, issue != .limit else { return false }
    let expandedRect = CGRect(x: captureRect.minX, y: captureRect.minY - delta,
      width: captureRect.width, height: captureRect.height + delta)
    guard snapshot.frame.contains(expandedRect) else { return false }
    while isCapturing {
      try? await Task.sleep(for: .milliseconds(25))
      guard isActive, !Task.isCancelled else { return false }
    }
    isCapturing = true
    defer { isCapturing = false }
    guard let expanded = await captureSettledFrame(rect: expandedRect),
          isActive, !Task.isCancelled, let previous = shotA,
          expanded.width == previous.width, expanded.height > previous.height,
          let oldArea = expanded.cropping(to: CGRect(x: 0, y: 0,
            width: previous.width, height: previous.height)),
          let current = normalizeFrame(oldArea) else { return false }
    let match = await Task.detached(priority: .userInitiated) {
      ScrollFrameMatcher.match(current: current, previous: previous)
    }.value
    guard isActive, !Task.isCancelled, let match, match.offset >= 0 else { return false }
    let displacement = Double(match.offset) + match.fraction + fractionalOffset
    if Int(displacement.rounded()) > 0 {
      guard await process(currentFrame: current, isSettled: true) else { return false }
    } else {
      fractionalOffset = displacement
    }
    guard mergeNewContent(currentFrame: expanded, offsetPx: expanded.height - previous.height) else { return false }
    captureRect = expandedRect
    // 新区完整首帧已在手中,不能置空基准后漏掉下一次短滚动。
    shotA = expanded
    issue = nil
    stripCount += 1
    emitProgress()
    return true
  }

  private func mergeNewContent(currentFrame: CGImage, offsetPx: Int, footer: Int = 0) -> Bool {
    guard let existing = mergedImage, currentFrame.width == existing.width,
          offsetPx > 0, footer >= 0, offsetPx + footer <= currentFrame.height else { return false }
    let width = existing.width
    let totalHeight = existing.height + offsetPx
    // 不能只追加最后一部分条带:那会在达到上限时主动跳过内容。
    guard totalHeight <= min(maxPixelHeight, maxPixelCount / width),
          let strip = currentFrame.cropping(to: CGRect(x: 0,
            y: currentFrame.height - offsetPx - footer, width: width, height: offsetPx + footer)),
          let context = CGContext(data: nil, width: width, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: existing.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return false }
    context.interpolationQuality = .none
    context.draw(existing, in: CGRect(x: 0, y: offsetPx, width: width, height: existing.height))
    // 只追加新增行;固定底栏覆盖旧底栏,固定头部和已拼正文保持原像素。
    context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: offsetPx + footer))
    guard let merged = context.makeImage() else { return false }
    mergedImage = merged
    stitchedImage = merged
    stitchedPixelSize = CGSize(width: width, height: totalHeight)
    return true
  }

  // MARK: - Preview

  private func emitProgress() {
    guard let image = mergedImage else { return }
    onProgress?(thumbnail(of: image, maxWidth: 200), image.height)
  }

  private func thumbnail(of image: CGImage, maxWidth: Int) -> CGImage? {
    guard image.width > maxWidth else { return image }
    let width = maxWidth
    let height = max(1, Int((CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)).rounded()))
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .low
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }
}
