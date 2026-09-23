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
  private var didReportAlignment = false
  private var loopFrames = 0
  private var loopMerges = 0

  init(snapshot: DisplaySnapshot, captureRect: CGRect,
       frameCapture: (@MainActor (CGRect) async -> CGImage?)? = nil) {
    self.snapshot = snapshot
    self.captureRect = captureRect
    self.frameCapture = frameCapture
  }

  func startSession() async -> Bool {
    guard !isActive else { return true }
    let token = generation
    // 首帧抓一次就走,不等"稳定帧":页面只要有动画就永远等不到,开场能卡 5 秒。
    // 注意首帧必须和后续帧同源(都走 captureFrame):用触发瞬间的快照裁剪过,
    // 两条路径尺寸差几像素,匹配器要求等宽,结果每一帧都被无声拒掉,全程拼不上。
    guard let first = await captureFrame(), !Task.isCancelled, token == generation,
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
    ScreenshotDebugLog.log("滚动采样汇总:循环处理 \(loopFrames) 帧,接上 \(loopMerges) 次")
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

  /// 调试日志开着时把第一对对不上的帧原样存盘,供离线复盘匹配器(每次会话覆盖)。
  private func dumpFrames(_ previous: CGImage, _ current: CGImage) {
    guard let dir = ScreenshotDebugLog.logFileURL?.deletingLastPathComponent()
      .appendingPathComponent("scroll-debug", isDirectory: true) else { return }
    // PNG 编码要半秒,放后台,别卡住采样循环。
    Task.detached(priority: .utility) {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      for (name, image) in [("previous", previous), ("current", current)] {
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try? data?.write(to: dir.appendingPathComponent("\(name).png"))
      }
      ScreenshotDebugLog.log("对不上的两帧已存:\(dir.path)")
    }
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

  /// 尽力等画面静止,最多约 0.8 秒。超时不算失败,直接拿最近一帧——接不接得上由像素重叠
  /// 校验说了算。早先这里死等 30 次(约 5 秒)并占着抓帧锁,页面只要有动画就永远等不到,
  /// 整条管线被饿死,滚动期间一帧都接不上。
  private func captureSettledFrame(rect: CGRect? = nil) async -> CGImage? {
    var previous: CGImage?
    for _ in 0..<6 {
      guard !Task.isCancelled else { return nil }
      if let frame = await captureFrame(rect: rect) {
        if let previous {
          let tolerance = settleTolerance(width: frame.width, height: frame.height)
          if (changedPixels(previous, frame, stopAbove: tolerance) ?? Int.max) <= tolerance { return frame }
        }
        previous = frame
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return previous
  }

  /// 一次性诊断:画面到底哪里在动、动多大。只在等不到稳定帧时跑一次。
  private func diffReport(_ a: CGImage, _ b: CGImage) -> String {
    guard a.width == b.width, a.height == b.height, a.bytesPerRow == b.bytesPerRow,
          let ad = a.dataProvider?.data, let bd = b.dataProvider?.data,
          let ap = CFDataGetBytePtr(ad), let bp = CFDataGetBytePtr(bd) else { return "尺寸不一致" }
    return withExtendedLifetime((ad, bd)) {
      var changed = 0, maxDelta = 0
      var minX = a.width, maxX = -1, minY = a.height, maxY = -1
      for y in 0..<a.height {
        for x in 0..<a.width {
          let i = y * a.bytesPerRow + x * 4
          let delta = max(abs(Int(ap[i]) - Int(bp[i])), abs(Int(ap[i + 1]) - Int(bp[i + 1])),
                          abs(Int(ap[i + 2]) - Int(bp[i + 2])))
          guard delta > 0 else { continue }
          maxDelta = max(maxDelta, delta)
          if delta > 3 {
            changed += 1
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
          }
        }
      }
      let total = a.width * a.height
      let box = maxX < 0 ? "无" : "\(minX),\(minY) \(maxX - minX + 1)x\(maxY - minY + 1)"
      return "\(a.width)x\(a.height) 明显变化 \(changed)/\(total) 像素,最大通道差 \(maxDelta),变化区域 \(box)"
    }
  }

  /// 画面"没在动"的容差:千分之一的像素。真在滚动时差异远超这个量。
  private func settleTolerance(width: Int, height: Int) -> Int {
    max(64, width * height / 1000)
  }

  /// 逐字节相等太苛刻:色彩管理/HDR 的逐帧噪声、文本插入点和时钟闪一下,就永远等不到两帧全等。
  /// 只数"明显变了"的像素,超过容差立刻停。
  private func changedPixels(_ a: CGImage, _ b: CGImage, stopAbove limit: Int) -> Int? {
    guard a.width == b.width, a.height == b.height, a.bytesPerRow == b.bytesPerRow,
          let ad = a.dataProvider?.data, let bd = b.dataProvider?.data,
          CFDataGetLength(ad) == CFDataGetLength(bd),
          let ap = CFDataGetBytePtr(ad), let bp = CFDataGetBytePtr(bd) else { return nil }
    return withExtendedLifetime((ad, bd)) {
      let length = CFDataGetLength(ad)
      if memcmp(ap, bp, length) == 0 { return 0 }
      var changed = 0
      for i in stride(from: 0, to: length - 3, by: 4) where
        abs(Int(ap[i]) - Int(bp[i])) > 3 || abs(Int(ap[i + 1]) - Int(bp[i + 1])) > 3
          || abs(Int(ap[i + 2]) - Int(bp[i + 2])) > 3 {
        changed += 1
        if changed > limit { return changed }
      }
      return changed
    }
  }

  private func grabAndProcess() async {
    guard isActive, !isCapturing, !isFinishing else { return }
    isCapturing = true
    defer { isCapturing = false }
    guard let frame = await captureFrame(), isActive, !Task.isCancelled else { return }
    loopFrames += 1
    if await process(currentFrame: frame, isSettled: false) { loopMerges += 1 }
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
      ScrollFrameMatcher.match(current: currentFrame, previous: previous, rescue: isSettled)
    }.value
    guard isActive, !Task.isCancelled, shotA === previous else { return false }
    guard let match else {
      if isSettled {
        issue = .alignment
        ScreenshotDebugLog.log("滚动拼接:重叠不可信,保留原基准")
      }
      // 只存像滚动的那对(一成以上像素在变);页面上的动图原地变化也会对不上,但那不是要查的。
      if !didReportAlignment, ScreenshotDebugLog.isEnabled,
         let changed = changedPixels(previous, currentFrame, stopAbove: currentFrame.width * currentFrame.height / 10),
         changed > currentFrame.width * currentFrame.height / 10 {
        didReportAlignment = true
        ScreenshotDebugLog.log("对不上的两帧(\(isSettled ? "稳定帧" : "采样帧")):" + diffReport(previous, currentFrame))
        dumpFrames(previous, currentFrame)
      }
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
