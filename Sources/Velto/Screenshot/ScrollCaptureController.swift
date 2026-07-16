import AppKit
import Foundation
import Vision

/// macshot 滚动截图核心在 Velto 中的兼容实现。
///
/// macshot 的按需完整帧捕获由 SCScreenshotManager 替代;稳定帧判断、Vision 位移、
/// 固定头部检测、滚动条排除和增量拼接保持相同流程。在其基础上增加接缝像素校验:
/// Vision 的位移只当估计值,±4px 内逐候选比对重叠区像素得到精确整数位移,
/// 校验不过的帧整帧丢弃,避免动画中间帧/配准误差把错位内容永久拼进结果。
@MainActor
final class ScrollCaptureController {
  private(set) var stripCount = 0
  private(set) var stitchedImage: CGImage?
  private(set) var stitchedPixelSize: CGSize = .zero
  private(set) var isActive = false
  private(set) var frozenTopHeight: CGFloat = 0

  var onProgress: ((CGImage?, Int) -> Void)?

  private let snapshot: DisplaySnapshot
  /// 捕获区(全局点坐标)。底边扩展后原地放大,后续抓帧按新区进行。
  private var captureRect: CGRect
  private let backingScale: CGFloat
  private let maxPixelHeight = 30_000
  private let maxPixelCount = 50_000_000

  private var shotA: CGImage?
  private var mergedImage: CGImage?
  private var headerHeight = 0
  private var headerDetectionDone = false
  private var headerDetectionSamples = 0
  private let frozenDetectionEnabled = true

  private var rightMarginPx = 0
  private var rightMarginDetected = false

  /// 最近一次滚轮事件距今超过该值即认为滚动停止,连续抓帧循环退出。
  private let scrollIdleInterval: TimeInterval = 0.4
  private let settlementInterval: TimeInterval = 0.25
  /// 接缝校验阈值:重叠区采样平均 SAD(BGR 三通道求和)。对齐正确的静止内容接近 0,
  /// 亚像素动画中间帧/错位帧会显著超过该值。
  private let seamAcceptThreshold: UInt64 = 10
  private var lastScrollActivity: TimeInterval = 0
  private var captureLoopTask: Task<Void, Never>?
  private var settlementTask: Task<Void, Never>?
  private var isCapturing = false
  private var consecutiveSettledFailures = 0

  init(snapshot: DisplaySnapshot, captureRect: CGRect) {
    self.snapshot = snapshot
    self.captureRect = captureRect
    backingScale = snapshot.scale
  }

  func startSession() async -> Bool {
    guard !isActive else { return true }
    guard let firstFrame = await captureSettledFrame() else { return false }

    isActive = true
    // SCScreenshotManager 是异步抓帧;保留首帧作基准,避免首个短滚动只来得及抓一次而被漏掉。
    shotA = firstFrame
    mergedImage = firstFrame
    headerHeight = 0
    headerDetectionDone = false
    headerDetectionSamples = 0
    rightMarginPx = 0
    rightMarginDetected = false
    consecutiveSettledFailures = 0
    lastScrollActivity = 0
    frozenTopHeight = 0
    stripCount = 1
    stitchedImage = firstFrame
    stitchedPixelSize = CGSize(width: firstFrame.width, height: firstFrame.height)
    emitProgress()
    ScreenshotDebugLog.log("macshot核心:首帧稳定 image=\(firstFrame.width)x\(firstFrame.height)")
    return true
  }

  func stopSession() -> CGImage? {
    let result = mergedImage
    stopWork()
    return result
  }

  func cancelSession() {
    stopWork()
  }

  private func stopWork() {
    isActive = false
    captureLoopTask?.cancel()
    captureLoopTask = nil
    settlementTask?.cancel()
    settlementTask = nil
    isCapturing = false
  }

  /// 由全局 event tap 在主线程上报。滚动活跃期间由连续抓帧循环持续采帧,
  /// 停止 250ms 后再补一帧稳定帧收尾。
  func noteManualScroll() {
    guard isActive else { return }
    lastScrollActivity = ProcessInfo.processInfo.systemUptime

    settlementTask?.cancel()
    settlementTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: .seconds(self.settlementInterval))
      guard !Task.isCancelled, self.isActive else { return }
      await self.settledCapture()
    }

    ensureCaptureLoop()
  }

  /// 滚动活跃期间尽可能快地连续抓帧(抓帧+配准耗时构成天然节流)。
  /// 相邻帧间隔越短重叠区越大,配准越稳,快速滚动也不易丢内容——
  /// 旧的「滚轮事件驱动 + 150ms 节流 + 抓帧中丢触发」在快滚时会拉大帧距导致配准失败。
  private func ensureCaptureLoop() {
    guard captureLoopTask == nil else { return }
    captureLoopTask = Task { [weak self] in
      defer { self?.captureLoopTask = nil }
      while let self, self.isActive, !Task.isCancelled {
        guard ProcessInfo.processInfo.systemUptime - self.lastScrollActivity
          < self.scrollIdleInterval else { return }
        await self.grabAndProcess()
        try? await Task.sleep(for: .milliseconds(30))
      }
    }
  }

  // MARK: - Frame capture

  private func captureFrame(rect: CGRect? = nil) async -> CGImage? {
    guard let image = try? await ScreenshotCapturer.captureRegion(
      in: snapshot,
      globalRect: rect ?? captureRect
    ) else { return nil }
    return normalizeFrame(image)
  }

  /// SCScreenshotManager 可能返回带行对齐 padding 的图像;归一化为 macshot 像素扫描所需的紧凑 BGRA。
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
    var previousCG: CGImage?
    var wait = Duration.milliseconds(10)

    for _ in 0..<30 {
      guard !Task.isCancelled, let cg = await captureFrame(rect: rect) else {
        try? await Task.sleep(for: .milliseconds(30))
        continue
      }
      // 连续两帧逐像素相同即认定画面已静止。等价于此前的 TIFF 全等比较,但省掉把整幅
      // retina 图编码成 TIFF 的开销:两帧均为 normalizeFrame 输出的紧凑 BGRA,尺寸一致
      // 时可直接比较底层字节。
      if let previousCG, framesPixelEqual(previousCG, cg) {
        return cg
      }
      previousCG = cg
      try? await Task.sleep(for: wait)
      wait = min(wait * 3 / 2, .milliseconds(80))
    }
    return previousCG
  }

  /// 两帧逐像素全等判定。两帧都经 normalizeFrame 输出紧凑 BGRA(bytesPerRow == width*4),
  /// 尺寸/行距一致时直接 memcmp 底层字节,与旧的 TIFF 全等比较结果逐位一致。
  private func framesPixelEqual(_ a: CGImage, _ b: CGImage) -> Bool {
    guard a.width == b.width, a.height == b.height, a.bytesPerRow == b.bytesPerRow,
          let aData = pixelData(for: a), let bData = pixelData(for: b) else { return false }
    let length = CFDataGetLength(aData)
    guard length == CFDataGetLength(bData),
          let aPtr = CFDataGetBytePtr(aData), let bPtr = CFDataGetBytePtr(bData) else { return false }
    return memcmp(aPtr, bPtr, length) == 0
  }

  private func grabAndProcess() async {
    guard isActive, !isCapturing else { return }
    isCapturing = true
    defer { isCapturing = false }

    guard let currentFrame = await captureFrame(), isActive else { return }
    guard let previousFrame = shotA else {
      shotA = currentFrame
      return
    }
    _ = process(currentFrame: currentFrame, previousFrame: previousFrame, isSettled: false)
  }

  private func settledCapture() async {
    guard isActive else { return }
    while isCapturing {
      try? await Task.sleep(for: .milliseconds(25))
      guard isActive, !Task.isCancelled else { return }
    }
    isCapturing = true
    defer { isCapturing = false }

    guard let currentFrame = await captureSettledFrame(), isActive else { return }
    guard let previousFrame = shotA else {
      shotA = currentFrame
      return
    }
    _ = process(currentFrame: currentFrame, previousFrame: previousFrame, isSettled: true)
  }

  /// 选区底边向下扩展 delta 点:抓取新露出的条带(稳定帧)追加到长图底部,并原地放大捕获区。
  /// 拼好的长图底部就是最近一帧的选区底边,紧邻其下的屏上条带天然连续,可直接追加。
  /// 扩展后旧基准帧尺寸已对不上,作废之;继续滚动时下一帧自动成为新基准,拼接照常。
  /// 失败(高度超上限 / 抓帧失败 / 宽度不一致)返回 false,捕获区保持不变。
  func extendBottom(byPoints delta: CGFloat) async -> Bool {
    guard isActive, delta >= 1, mergedImage != nil else { return false }
    while isCapturing {
      try? await Task.sleep(for: .milliseconds(25))
      guard isActive, !Task.isCancelled else { return false }
    }
    isCapturing = true
    defer { isCapturing = false }

    let stripRect = CGRect(
      x: captureRect.minX, y: captureRect.minY - delta,
      width: captureRect.width, height: delta
    )
    guard let strip = await captureSettledFrame(rect: stripRect), isActive,
          let existing = mergedImage else { return false }
    let rowLimit = min(maxPixelHeight, maxPixelCount / max(1, existing.width))
    guard strip.width == existing.width,
          existing.height + strip.height <= rowLimit,
          mergeNewContent(currentFrame: strip, offsetPx: strip.height) else {
      ScreenshotDebugLog.log("macshot核心:底边扩展失败 strip=\(strip.width)x\(strip.height) "
        + "existing=\(existing.width)x\(existing.height) rowLimit=\(rowLimit)")
      return false
    }

    captureRect = CGRect(
      x: captureRect.minX, y: captureRect.minY - delta,
      width: captureRect.width, height: captureRect.height + delta
    )
    shotA = nil
    stripCount += 1
    emitProgress()
    ScreenshotDebugLog.log("macshot核心:底边扩展 +\(strip.height)px result="
      + "\(Int(stitchedPixelSize.width))x\(Int(stitchedPixelSize.height))")
    return true
  }

  private func process(currentFrame: CGImage, previousFrame: CGImage, isSettled: Bool) -> Bool {
    guard let offset = visionShift(current: currentFrame, previous: previousFrame) else {
      noteProcessFailure(currentFrame: currentFrame, isSettled: isSettled, reason: "Vision配准失败")
      return false
    }

    let estimate = Int(offset.rounded())
    // 无位移/向上回滚:画面没有新内容,基准帧保持不变继续等待。
    guard estimate > 0 else {
      if isSettled { consecutiveSettledFailures = 0 }
      return false
    }

    // 小位移不动基准帧,继续累计到 macshot 的可信阈值。
    let minShift = currentFrame.height / 10
    guard estimate >= minShift else { return false }

    // Vision 位移只是浮点估计;像素级精修出准确整数位移,错位帧整帧拒绝。
    guard let offsetPx = refineOffset(
      current: currentFrame, previous: previousFrame, estimate: estimate
    ) else {
      noteProcessFailure(currentFrame: currentFrame, isSettled: isSettled,
                         reason: "接缝校验未过 estimate=\(estimate)")
      return false
    }

    if !rightMarginDetected {
      // 确认发生真实滚动后再测滚动条;静止帧对全图无差异,会把检测一次定死为「无滚动条」。
      detectRightMargin(current: currentFrame, previous: previousFrame)
    }
    if frozenDetectionEnabled && !headerDetectionDone {
      detectHeader(current: currentFrame, previous: previousFrame, shiftPx: offsetPx)
    }

    guard mergeNewContent(currentFrame: currentFrame, offsetPx: offsetPx) else { return false }

    shotA = currentFrame
    consecutiveSettledFailures = 0
    stripCount += 1
    emitProgress()
    ScreenshotDebugLog.log("macshot核心:拼接成功 vision=\(estimate) exact=\(offsetPx) "
      + "header=\(headerHeight) margin=\(rightMarginPx) settled=\(isSettled) result="
      + "\(Int(stitchedPixelSize.width))x\(Int(stitchedPixelSize.height))")
    return true
  }

  /// 配准/校验失败不再退化成「用当前帧顶替基准帧」——那会把两帧之间已滚过的内容静默丢掉。
  /// 滚动中的失败帧直接丢弃等下一帧;稳定帧连续失败说明基准已失联(滚太远),
  /// 此时才重置基准并明确记录缺口风险。
  private func noteProcessFailure(currentFrame: CGImage, isSettled: Bool, reason: String) {
    ScreenshotDebugLog.log("macshot核心:丢弃帧(\(reason)) settled=\(isSettled)")
    guard isSettled else { return }
    consecutiveSettledFailures += 1
    if consecutiveSettledFailures >= 2 {
      shotA = currentFrame
      consecutiveSettledFailures = 0
      ScreenshotDebugLog.log("macshot核心:稳定帧连续失败,重置基准帧,此处可能存在内容缺口")
    }
  }

  // MARK: - Incremental stitching

  private func mergeNewContent(currentFrame: CGImage, offsetPx: Int) -> Bool {
    guard let existing = mergedImage, currentFrame.width == existing.width else { return false }
    let width = currentFrame.width
    let rowLimit = min(maxPixelHeight, maxPixelCount / max(1, width))
    let availableRows = rowLimit - existing.height
    let newRows = min(offsetPx, availableRows)
    guard newRows > 0, newRows <= currentFrame.height else { return false }

    let totalHeight = existing.height + newRows
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
      | CGBitmapInfo.byteOrder32Little.rawValue
    guard let context = CGContext(
      data: nil,
      width: width,
      height: totalHeight,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: existing.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: bitmapInfo
    ) else { return false }

    context.draw(existing, in: CGRect(x: 0, y: newRows, width: width, height: existing.height))
    if headerDetectionDone && headerHeight > 0 {
      let stripY = currentFrame.height - newRows
      guard let strip = currentFrame.cropping(to: CGRect(
        x: 0, y: stripY, width: width, height: newRows
      )) else { return false }
      context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: newRows))
    } else {
      context.draw(currentFrame, in: CGRect(
        x: 0, y: 0, width: width, height: currentFrame.height
      ))
    }

    guard let merged = context.makeImage() else { return false }
    mergedImage = merged
    stitchedImage = merged
    stitchedPixelSize = CGSize(width: width, height: totalHeight)
    return true
  }

  // MARK: - Vision shift detection

  private func visionShift(current: CGImage, previous: CGImage) -> CGFloat? {
    var currentImage = current
    var previousImage = previous
    let cropY = headerDetectionDone ? min(headerHeight, current.height / 5) : 0
    let cropWidth = current.width - rightMarginPx
    let cropHeight = current.height - cropY
    if cropY > 0 || rightMarginPx > 0 {
      guard cropHeight > 20, cropWidth > 20 else { return nil }
      let cropRect = CGRect(x: 0, y: cropY, width: cropWidth, height: cropHeight)
      guard let croppedCurrent = current.cropping(to: cropRect),
            let croppedPrevious = previous.cropping(to: cropRect) else { return nil }
      currentImage = croppedCurrent
      previousImage = croppedPrevious
    }

    let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previousImage)
    let handler = VNImageRequestHandler(cgImage: currentImage, options: [:])
    guard (try? handler.perform([request])) != nil,
          let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
      return nil
    }
    return observation.alignmentTransform.ty
  }

  // MARK: - Seam verification

  /// 在 Vision 估计值 ±4px 内逐候选比对重叠区像素,返回 SAD 最小且低于阈值的精确位移;
  /// 全部候选都超阈值(动画中间帧、配准错位)则返回 nil,由调用方丢弃该帧。
  /// 采样只取重叠区下半段:未检测出的固定头部/工具栏都贴顶,下半段不受污染。
  private func refineOffset(current: CGImage, previous: CGImage, estimate: Int) -> Int? {
    guard current.width == previous.width, current.height == previous.height,
          let currentCFData = pixelData(for: current),
          let previousCFData = pixelData(for: previous),
          let currentData = CFDataGetBytePtr(currentCFData),
          let previousData = CFDataGetBytePtr(previousCFData) else { return nil }

    let width = current.width
    let height = current.height
    let bytesPerRow = width * 4
    let usableWidth = max(4, width - rightMarginPx)
    let headerRows = headerDetectionDone ? headerHeight : 0
    let searchRadius = 4

    var bestOffset = 0
    var bestScore = UInt64.max
    for candidate in (estimate - searchRadius)...(estimate + searchRadius) {
      guard candidate >= 1, candidate < height else { continue }
      // 当前帧第 r 行的内容在上一帧位于第 r+candidate 行(内容整体上移)。
      let overlapEnd = height - candidate
      let overlapStart = max(headerRows, overlapEnd / 2)
      guard overlapEnd - overlapStart >= 24 else { continue }

      var sad: UInt64 = 0
      var samples = 0
      let rowStep = max(1, (overlapEnd - overlapStart) / 120)
      for row in stride(from: overlapStart, to: overlapEnd, by: rowStep) {
        let currentBase = row * bytesPerRow
        let previousBase = (row + candidate) * bytesPerRow
        for column in stride(from: 0, to: usableWidth, by: 8) {
          let c = currentBase + column * 4
          let p = previousBase + column * 4
          sad += UInt64(abs(Int(currentData[c]) - Int(previousData[p]))
            + abs(Int(currentData[c + 1]) - Int(previousData[p + 1]))
            + abs(Int(currentData[c + 2]) - Int(previousData[p + 2])))
          samples += 1
        }
      }
      guard samples > 0 else { continue }
      let score = sad / UInt64(samples)
      if score < bestScore {
        bestScore = score
        bestOffset = candidate
      }
    }

    guard bestOffset > 0, bestScore <= seamAcceptThreshold else {
      ScreenshotDebugLog.log("macshot核心:接缝校验拒绝 estimate=\(estimate) "
        + "best=\(bestOffset) score=\(bestScore) 阈值=\(seamAcceptThreshold)")
      return nil
    }
    return bestOffset
  }

  /// 返回 CGImage 底层像素 buffer 的 CFData。**必须由调用方持有返回值至指针用完**——
  /// 直接在这里 `CFDataGetBytePtr` 再返回裸指针会在 CFData 释放后悬垂。
  private func pixelData(for image: CGImage) -> CFData? {
    image.dataProvider?.data
  }

  // MARK: - Scrollbar and frozen header

  private func detectRightMargin(current: CGImage, previous: CGImage) {
    rightMarginDetected = true
    guard current.width == previous.width, current.height == previous.height,
          let currentCFData = pixelData(for: current),
          let previousCFData = pixelData(for: previous),
          let currentData = CFDataGetBytePtr(currentCFData),
          let previousData = CFDataGetBytePtr(previousCFData) else { return }

    let width = current.width
    let height = current.height
    let bytesPerRow = width * 4
    let rowStart = height * 2 / 10
    let rowEnd = height * 8 / 10
    let rowStep = max(1, (rowEnd - rowStart) / 40)
    var scrollbarWidth = 0

    for columnOffset in 0..<min(50, width / 8) {
      let column = width - 1 - columnOffset
      var sad: UInt64 = 0
      var samples = 0
      for row in stride(from: rowStart, to: rowEnd, by: rowStep) {
        let index = row * bytesPerRow + column * 4
        sad += UInt64(abs(Int(currentData[index]) - Int(previousData[index]))
          + abs(Int(currentData[index + 1]) - Int(previousData[index + 1]))
          + abs(Int(currentData[index + 2]) - Int(previousData[index + 2])))
        samples += 1
      }
      guard samples > 0 else { continue }
      if sad / UInt64(samples) > 8 {
        scrollbarWidth = columnOffset + 1
      } else if scrollbarWidth > 0 {
        break
      }
    }

    if scrollbarWidth >= 3, scrollbarWidth <= 40 {
      rightMarginPx = scrollbarWidth + 4
    }
  }

  private func detectHeader(current: CGImage, previous: CGImage, shiftPx: Int) {
    guard current.width == previous.width, current.height == previous.height, shiftPx > 5,
          let currentCFData = pixelData(for: current),
          let previousCFData = pixelData(for: previous),
          let currentData = CFDataGetBytePtr(currentCFData),
          let previousData = CFDataGetBytePtr(previousCFData) else { return }

    let width = current.width
    let height = current.height
    let bytesPerRow = width * 4
    let compareBytes = max(4, width - rightMarginPx) * 4
    var frozenRows = 0

    for row in 0..<height {
      var rowSAD: UInt64 = 0
      var samples = 0
      let offset = row * bytesPerRow
      for column in stride(from: 0, to: compareBytes, by: 16) {
        rowSAD += UInt64(abs(Int(currentData[offset + column]) - Int(previousData[offset + column]))
          + abs(Int(currentData[offset + column + 1]) - Int(previousData[offset + column + 1]))
          + abs(Int(currentData[offset + column + 2]) - Int(previousData[offset + column + 2])))
        samples += 1
      }
      let average = samples > 0 ? rowSAD / UInt64(samples) : 999
      if average > 8 {
        frozenRows = row
        break
      }
      if row == height - 1 { return }
    }

    if frozenRows >= 10, frozenRows < height * 6 / 10 {
      headerDetectionSamples += 1
      if headerDetectionSamples == 1 {
        headerHeight = frozenRows
        frozenTopHeight = CGFloat(headerHeight) / backingScale
        headerDetectionDone = true
      } else {
        if abs(frozenRows - headerHeight) <= 5 {
          headerHeight = min(headerHeight, frozenRows)
          frozenTopHeight = CGFloat(headerHeight) / backingScale
        } else {
          headerHeight = 0
          frozenTopHeight = 0
        }
        headerDetectionDone = true
      }
    } else if frozenRows < 10 {
      headerDetectionDone = true
    }
  }

  // MARK: - Preview

  private func emitProgress() {
    guard let image = mergedImage else { return }
    onProgress?(thumbnail(of: image, maxHeight: 260), image.height)
  }

  private func thumbnail(of image: CGImage, maxHeight: Int) -> CGImage? {
    guard image.height > maxHeight else { return image }
    let scale = CGFloat(maxHeight) / CGFloat(image.height)
    let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
    guard let context = CGContext(
      data: nil,
      width: width,
      height: maxHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .low
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: maxHeight))
    return context.makeImage()
  }
}
