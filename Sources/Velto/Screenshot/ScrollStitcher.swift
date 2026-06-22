import CoreGraphics
import Foundation
import VeltoAnnotationCore

final class ScrollStitcher {
  enum Outcome: Equatable {
    case first(rows: Int)
    case grew(rows: Int)
    case unchanged
    case skippedNoOverlap
    case reachedLimit
  }

  private static let samplesPerRow = 32

  private let maxPixelHeight: Int
  private let maxPixelCount: Int
  private var pixelWidth = 0
  private(set) var pixelHeight = 0
  private var strips: [CGImage] = []
  private var fingerprints: [UInt64] = []

  init(maxPixelHeight: Int = 30_000, maxPixelCount: Int = 50_000_000) {
    self.maxPixelHeight = max(0, maxPixelHeight)
    self.maxPixelCount = max(0, maxPixelCount)
  }

  func append(frame: CGImage) -> Outcome {
    guard pixelHeight < maxPixelHeight else { return .reachedLimit }
    if !strips.isEmpty {
      guard frame.width == pixelWidth else { return .skippedNoOverlap }
    }
    let rowLimit = pixelRowLimit(forWidth: frame.width)
    guard pixelHeight < rowLimit else { return .reachedLimit }

    let frameFingerprints = Self.rowFingerprints(
      of: frame,
      samples: Self.samplesPerRow
    )
    guard frameFingerprints.count == frame.height else { return .skippedNoOverlap }

    if strips.isEmpty {
      let rows = min(frame.height, rowLimit)
      guard rows > 0,
            let strip = crop(frame, fromTopRow: 0, rowCount: rows) else {
        return .reachedLimit
      }
      pixelWidth = frame.width
      pixelHeight = rows
      strips.append(strip)
      fingerprints.append(contentsOf: frameFingerprints.prefix(rows))
      if rows == rowLimit { return .reachedLimit }
      return .first(rows: rows)
    }

    let canvasTail = Array(fingerprints.suffix(frameFingerprints.count))
    guard let appendableRows = ScrollOverlapDetector.appendableRowCount(
      canvasTail: canvasTail,
      frame: frameFingerprints
    ) else {
      return .skippedNoOverlap
    }
    guard appendableRows > 0 else { return .unchanged }

    let rows = min(appendableRows, rowLimit - pixelHeight)
    guard rows > 0 else { return .reachedLimit }
    let firstNewRow = frame.height - appendableRows
    guard let strip = crop(frame, fromTopRow: firstNewRow, rowCount: rows) else {
      return .skippedNoOverlap
    }

    strips.append(strip)
    fingerprints.append(contentsOf: frameFingerprints[firstNewRow..<(firstNewRow + rows)])
    pixelHeight += rows
    if pixelHeight == rowLimit { return .reachedLimit }
    return .grew(rows: rows)
  }

  func finalize() -> CGImage? {
    guard let context = makeContext(width: pixelWidth, height: pixelHeight) else { return nil }

    var topRow = 0
    for strip in strips {
      let y = pixelHeight - topRow - strip.height
      context.draw(strip, in: CGRect(x: 0, y: y, width: strip.width, height: strip.height))
      topRow += strip.height
    }
    return context.makeImage()
  }

  func thumbnail(maxHeight: Int) -> CGImage? {
    guard pixelHeight > 0, pixelWidth > 0, maxHeight > 0 else { return nil }

    let targetHeight = min(pixelHeight, maxHeight)
    let scale = Double(targetHeight) / Double(pixelHeight)
    let targetWidth = max(1, Int((Double(pixelWidth) * scale).rounded()))
    guard let context = makeContext(width: targetWidth, height: targetHeight) else { return nil }
    context.interpolationQuality = .low

    // 用累计边界取整，避免逐条带缩放时产生缝隙或越界。
    var sourceTop = 0
    for strip in strips {
      let scaledTop = Int((Double(sourceTop) * scale).rounded())
      sourceTop += strip.height
      let scaledBottom = Int((Double(sourceTop) * scale).rounded())
      let height = scaledBottom - scaledTop
      guard height > 0 else { continue }
      context.draw(strip, in: CGRect(
        x: 0,
        y: targetHeight - scaledBottom,
        width: targetWidth,
        height: height
      ))
    }
    return context.makeImage()
  }

  static func rowFingerprints(of image: CGImage, samples: Int) -> [UInt64] {
    guard image.width > 0,
          image.height > 0,
          image.bitsPerPixel > 0,
          let data = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else {
      return []
    }

    let bytesPerPixel = (image.bitsPerPixel + 7) / 8
    guard bytesPerPixel > 0 else { return [] }
    let sampleCount = min(max(1, samples), image.width)
    let dataLength = CFDataGetLength(data)
    let rgbOffsets = rgbByteOffsets(for: image, bytesPerPixel: bytesPerPixel)
    var result: [UInt64] = []
    result.reserveCapacity(image.height)

    for row in 0..<image.height {
      let rowOffset = row * image.bytesPerRow
      var hash: UInt64 = 14_695_981_039_346_656_037

      for sample in 0..<sampleCount {
        let x = sampleCount == 1
          ? image.width / 2
          : sample * (image.width - 1) / (sampleCount - 1)
        let pixelOffset = rowOffset + x * image.bitsPerPixel / 8
        guard pixelOffset >= 0, pixelOffset + bytesPerPixel <= dataLength else { continue }

        let channels: (UInt8, UInt8, UInt8)
        if let offsets = rgbOffsets {
          channels = (
            bytes[pixelOffset + offsets.r],
            bytes[pixelOffset + offsets.g],
            bytes[pixelOffset + offsets.b]
          )
        } else {
          // 灰度或少见布局用首分量作为 RGB，仍保持稳定的逐行比较语义。
          let value = bytes[pixelOffset]
          channels = (value, value, value)
        }

        for nibble in [channels.0 >> 4, channels.1 >> 4, channels.2 >> 4] {
          hash ^= UInt64(nibble)
          hash &*= 1_099_511_628_211
        }
      }
      result.append(hash)
    }
    return result
  }

  // MARK: - 私有辅助

  private func pixelRowLimit(forWidth width: Int) -> Int {
    guard width > 0 else { return 0 }
    return min(maxPixelHeight, maxPixelCount / width)
  }

  private func crop(_ image: CGImage, fromTopRow row: Int, rowCount: Int) -> CGImage? {
    guard row >= 0, rowCount > 0, row + rowCount <= image.height else { return nil }
    guard let cropped = image.cropping(to: CGRect(
      x: 0,
      y: row,
      width: image.width,
      height: rowCount
    )), let context = makeContext(width: cropped.width, height: cropped.height) else {
      return nil
    }

    // cropping 可能与整帧共用 provider；重绘后条带只保留自身尺寸的 backing。
    context.interpolationQuality = .none
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
    return context.makeImage()
  }

  private func makeContext(width: Int, height: Int) -> CGContext? {
    guard width > 0, height > 0 else { return nil }
    return CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  }

  private static func rgbByteOffsets(
    for image: CGImage,
    bytesPerPixel: Int
  ) -> (r: Int, g: Int, b: Int)? {
    guard image.bitsPerComponent == 8, bytesPerPixel >= 3 else { return nil }

    let logicalOffsets: (r: Int, g: Int, b: Int)
    switch image.alphaInfo {
    case .premultipliedFirst, .first, .noneSkipFirst:
      guard bytesPerPixel >= 4 else { return nil }
      logicalOffsets = (1, 2, 3)
    case .premultipliedLast, .last, .noneSkipLast, .none:
      logicalOffsets = (0, 1, 2)
    case .alphaOnly:
      return nil
    @unknown default:
      return nil
    }

    let order = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
    let isLittleEndian = order == CGBitmapInfo.byteOrder16Little.rawValue
      || order == CGBitmapInfo.byteOrder32Little.rawValue
    guard isLittleEndian else { return logicalOffsets }
    return (
      bytesPerPixel - 1 - logicalOffsets.r,
      bytesPerPixel - 1 - logicalOffsets.g,
      bytesPerPixel - 1 - logicalOffsets.b
    )
  }
}
