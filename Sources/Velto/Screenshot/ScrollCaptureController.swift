import AppKit
import Foundation
import Vision

/// macshot 滚动截图核心在 Velto 中的兼容实现。
///
/// macshot 的按需完整帧捕获由 SCScreenshotManager 替代;稳定帧判断、Vision 位移、
/// 固定头部检测、滚动条排除和增量拼接保持相同流程。
@MainActor
final class ScrollCaptureController {
  private(set) var stripCount = 0
  private(set) var stitchedImage: CGImage?
  private(set) var stitchedPixelSize: CGSize = .zero
  private(set) var isActive = false
  private(set) var frozenTopHeight: CGFloat = 0

  var onProgress: ((CGImage?, Int) -> Void)?

  private let snapshot: DisplaySnapshot
  private let captureRect: CGRect
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
  private var hasScrolledOnce = false
  private var consecutiveZeroShifts = 0
  private let maxZeroShiftsBeforeStop = 6

  private let manualCaptureInterval: TimeInterval = 0.15
  private let settlementInterval: TimeInterval = 0.25
  private var lastCaptureTime: TimeInterval = 0
  private var pendingCaptureTask: Task<Void, Never>?
  private var settlementTask: Task<Void, Never>?
  private var isCapturing = false

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
    hasScrolledOnce = false
    consecutiveZeroShifts = 0
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
    pendingCaptureTask?.cancel()
    pendingCaptureTask = nil
    settlementTask?.cancel()
    settlementTask = nil
    isCapturing = false
  }

  /// 由全局 event tap 在主线程上报。滚动中每 150ms 抓一帧,停止 250ms 后再抓稳定帧。
  func noteManualScroll() {
    guard isActive else { return }

    settlementTask?.cancel()
    settlementTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: .seconds(self.settlementInterval))
      guard !Task.isCancelled, self.isActive else { return }
      await self.settledCapture()
    }

    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastCaptureTime >= manualCaptureInterval else { return }
    lastCaptureTime = now
    guard pendingCaptureTask == nil else { return }
    pendingCaptureTask = Task { [weak self] in
      guard let self else { return }
      await self.grabAndProcess()
      self.pendingCaptureTask = nil
    }
  }

  // MARK: - Frame capture

  private func captureFrame() async -> CGImage? {
    guard let image = try? await ScreenshotCapturer.captureRegion(
      in: snapshot,
      globalRect: captureRect
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

  private func captureSettledFrame() async -> CGImage? {
    var previousTIFF: Data?
    var previousCG: CGImage?
    var wait = Duration.milliseconds(10)

    for _ in 0..<30 {
      guard !Task.isCancelled, let cg = await captureFrame() else {
        try? await Task.sleep(for: .milliseconds(30))
        continue
      }
      let currentTIFF = NSBitmapImageRep(cgImage: cg).tiffRepresentation
      if let previousTIFF, currentTIFF == previousTIFF {
        return cg
      }
      previousTIFF = currentTIFF
      previousCG = cg
      try? await Task.sleep(for: wait)
      wait = min(wait * 3 / 2, .milliseconds(80))
    }
    return previousCG
  }

  private func captureAndCompare() async -> Bool {
    try? await Task.sleep(for: .milliseconds(50))
    guard isActive, let currentFrame = await captureSettledFrame(), isActive else { return false }
    guard let previousFrame = shotA ?? mergedImage?.cropping(to: CGRect(
      x: 0, y: 0, width: currentFrame.width, height: currentFrame.height
    )) else {
      shotA = currentFrame
      return false
    }
    return process(currentFrame: currentFrame, previousFrame: previousFrame)
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
    _ = process(currentFrame: currentFrame, previousFrame: previousFrame)
  }

  private func settledCapture() async {
    guard isActive else { return }
    while isCapturing {
      try? await Task.sleep(for: .milliseconds(25))
      guard isActive, !Task.isCancelled else { return }
    }
    isCapturing = true
    defer { isCapturing = false }
    _ = await captureAndCompare()
  }

  private func process(currentFrame: CGImage, previousFrame: CGImage) -> Bool {
    if !rightMarginDetected {
      detectRightMargin(current: currentFrame, previous: previousFrame)
    }

    guard let offset = visionShift(current: currentFrame, previous: previousFrame) else {
      shotA = currentFrame
      consecutiveZeroShifts += 1
      return false
    }

    let offsetPx = Int(round(offset))
    guard offsetPx > 0 else {
      shotA = currentFrame
      if hasScrolledOnce {
        consecutiveZeroShifts += 1
        if consecutiveZeroShifts >= maxZeroShiftsBeforeStop {
          ScreenshotDebugLog.log("macshot核心:连续无位移,保留当前结果等待用户完成")
        }
      }
      return false
    }

    let minShift = currentFrame.height / 10
    guard offsetPx >= minShift else {
      // 不更新基准帧,让小位移继续累计到 macshot 的可信阈值。
      return false
    }

    consecutiveZeroShifts = 0
    hasScrolledOnce = true
    if frozenDetectionEnabled && !headerDetectionDone {
      detectHeader(current: currentFrame, previous: previousFrame, shiftPx: offsetPx)
    }

    let safeOffset = max(1, offsetPx - 1)
    guard mergeNewContent(currentFrame: currentFrame, offsetPx: safeOffset) else { return false }

    shotA = currentFrame
    stripCount += 1
    emitProgress()
    ScreenshotDebugLog.log("macshot核心:拼接成功 offset=\(offsetPx) safe=\(safeOffset) "
      + "header=\(headerHeight) margin=\(rightMarginPx) result="
      + "\(Int(stitchedPixelSize.width))x\(Int(stitchedPixelSize.height))")
    return true
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

  private func pixelData(for image: CGImage) -> UnsafePointer<UInt8>? {
    guard let data = image.dataProvider?.data else { return nil }
    return CFDataGetBytePtr(data)
  }

  // MARK: - Scrollbar and frozen header

  private func detectRightMargin(current: CGImage, previous: CGImage) {
    rightMarginDetected = true
    guard current.width == previous.width, current.height == previous.height,
          let currentData = pixelData(for: current),
          let previousData = pixelData(for: previous) else { return }

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
          let currentData = pixelData(for: current),
          let previousData = pixelData(for: previous) else { return }

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
