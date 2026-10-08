import Accelerate
import CoreGraphics
import Foundation
import Vision

/// 只接受有唯一像素重叠的竖直位移。粗采样搜索整段重叠范围,再用 RGB 边缘验证;
/// 空白或重复内容无法证明位移时返回 nil,不猜一个接缝。
enum ScrollFrameMatcher {
  struct Match: Sendable {
    let offset: Int
    // Fractional displacement is carried across frames; rounding each frame drifts.
    var fraction: Double = 0
    let header: Int
    let footer: Int
  }

  /// `rescue` 打开 Vision 配准兜底,只留给停下后的稳定帧。平滑重匹始终开着:Chrome 触控板
  /// 滚动几乎每帧都停在半个设备像素上,只有它接得上(用真实帧复盘,关掉后半像素全军覆没)。
  /// 严格匹配失败再容忍局部动画(聊天里的动图表情、页面里的视频):重叠区里动图换了一帧,
  /// 严格校验必然整帧拒掉,滚动截图就一次都接不上。
  static func match(current: CGImage, previous: CGImage, rescue: Bool = true) -> Match? {
    match(current: current, previous: previous, allowSmoothing: true, rescue: rescue)
      ?? match(current: current, previous: previous, allowSmoothing: true, rescue: false, tolerateMotion: true)
  }

  private static func match(current: CGImage, previous: CGImage, allowSmoothing: Bool,
                            rescue: Bool = true, tolerateMotion: Bool = false) -> Match? {
    guard current.width == previous.width, current.height == previous.height,
          current.bitsPerPixel == 32, previous.bitsPerPixel == 32,
          current.width >= 16, current.height >= 32,
          let a = current.dataProvider?.data, let b = previous.dataProvider?.data,
          CFDataGetLength(a) >= current.bytesPerRow * current.height,
          CFDataGetLength(b) >= previous.bytesPerRow * previous.height,
          let ap = CFDataGetBytePtr(a), let bp = CFDataGetBytePtr(b) else { return nil }
    return withExtendedLifetime((a, b)) {
      let width = current.width, height = current.height
      let aStride = current.bytesPerRow, bStride = previous.bytesPerRow
      // 排除两侧边框及右侧覆盖式滚动条;输出仍保留用户选定的完整宽度。
      let left = min(4, width / 16)
      let right = width - min(32, width / 10)
      let columns = (0..<32).map { left + $0 * (right - left - 1) / 31 }
      var rowsA = [Int](repeating: 0, count: height * 32)
      var rowsB = rowsA
      var equalRows = [Bool](repeating: false, count: height)
      for y in 0..<height {
        var difference = 0
        for (i, x) in columns.enumerated() {
          let ai = y * aStride + x * 4, bi = y * bStride + x * 4
          rowsA[y * 32 + i] = Int(ap[ai]) + Int(ap[ai + 1]) + Int(ap[ai + 2])
          rowsB[y * 32 + i] = Int(bp[bi]) + Int(bp[bi + 1]) + Int(bp[bi + 2])
          for c in 0..<3 { difference += abs(Int(ap[ai + c]) - Int(bp[bi + c])) }
        }
        equalRows[y] = difference <= 32 * 3
      }

      // 静止先验证完整画面,不能因稀疏样本相同就认定没有滚动。
      if equalRows.allSatisfy({ $0 }), verify(offset: 0, top: 0, bottom: height,
        left: left, right: right, a: ap, b: bp, aStride: aStride, bStride: bStride,
        requireTexture: false) != nil {
        return Match(offset: 0, header: 0, footer: 0)
      }
      // 没滚、只有动图在动:按整帧容忍校验认成静止,别把它当成对不上。
      if tolerateMotion, verify(offset: 0, top: 0, bottom: height, left: left, right: right,
        a: ap, b: bp, aStride: aStride, bStride: bStride, requireTexture: true, tolerateMotion: true) != nil {
        return Match(offset: 0, header: 0, footer: 0)
      }

      // Thin content can fall entirely between the coarse columns. A failed
      // dense stationary check must still reach registration in that case.
      let allCoarseRowsEqual = equalRows.allSatisfy { $0 }
      let top = allCoarseRowsEqual ? 0 : equalRows.prefix(while: { $0 }).count
      let bottom = allCoarseRowsEqual ? height : height - equalRows.reversed().prefix(while: { $0 }).count
      let bodyHeight = bottom - top
      let minOverlap = max(24, min(128, bodyHeight / 4))
      guard bodyHeight > minOverlap else { return nil }

      // ponytail: 每个位移仅取 24 行 × 32 列,成本随选区高度线性增长;
      // 极高分辨率若实测超出帧预算,再把行描述的搜索迁到 Accelerate。
      var candidates: [(offset: Int, score: Double)] = []
      let maxShift = bodyHeight - minOverlap
      offsets: for offset in -maxShift...maxShift {
        let start = max(top, top - offset)
        let end = min(bottom, bottom - offset)
        var error = 0, evidence = 0, inliers = 0
        for sample in 0..<24 {
          let row = start + sample * (end - start - 1) / 23
          let ai = row * 32, bi = (row + offset) * 32
          for x in 0..<32 {
            let av = rowsA[ai + x], bv = rowsB[bi + x]
            let ax = rowsA[ai + (x + 1) % 32], bx = rowsB[bi + (x + 1) % 32]
            let ay = rowsA[min(height - 1, row + 1) * 32 + x]
            let by = rowsB[min(height - 1, row + offset + 1) * 32 + x]
            if max(abs(av - ax), abs(bv - bx), abs(av - ay), abs(bv - by)) > 18 {
              let delta = abs(av - bv)
              error += delta
              evidence += 1
              if delta <= 24 { inliers += 1 }
            }
          }
          // 即便剩余所有采样都精确相等也过不了阈值,立即跳过该位移。
          if !tolerateMotion, error > 24 * (evidence + (23 - sample) * 32) { continue offsets }
        }
        // 动图那几列误差再大也不该拖垮均值:改按"吻合的采样数"投票,真实位移得票最多。
        if tolerateMotion {
          if inliers >= 24 { candidates.append((offset, -Double(inliers))) }
          continue
        }
        guard evidence >= 24 else { continue }
        let score = Double(error) / Double(evidence)
        guard score <= 24 else { continue }
        candidates.append((offset, score))
      }
      candidates.sort { $0.score < $1.score }
      var matches: [(offset: Int, score: Double, fraction: Double)] = []
      // 大量同分候选意味着空白/重复图案,不能任意选取一次位移。
      for candidate in candidates.prefix(12) {
        let fraction = allowSmoothing ? 0 : verticalPhase(offset: candidate.offset, top: top, bottom: bottom,
          left: left, right: right, a: ap, b: bp, aStride: aStride, bStride: bStride)
        if let score = verify(offset: candidate.offset, top: top, bottom: bottom,
          left: left, right: right, a: ap, b: bp, aStride: aStride, bStride: bStride,
          requireTexture: true, fraction: fraction, tolerateMotion: tolerateMotion) {
          matches.append((candidate.offset, score, fraction))
        }
      }
      // Subpixel rendering changes text edges even at the correct displacement.
      // Normalize vertically only, preserving sensitivity to horizontal drift.
      // These comparison images never enter the exported screenshot.
      if matches.isEmpty, allowSmoothing,
         let a = verticallySmoothed(current, top: top, bottom: bottom),
         let b = verticallySmoothed(previous, top: top, bottom: bottom),
         let match = match(current: a, previous: b, allowSmoothing: false, tolerateMotion: tolerateMotion) {
        return Match(offset: match.offset, fraction: match.fraction, header: top, footer: height - bottom)
      }
      // CapCap's 2D registration recovers candidates missed by sparse samples.
      // Keep it off the normal-frame path: full-resolution Vision is substantially
      // more expensive than a verified pixel match. Never override ambiguity.
      if matches.isEmpty, rescue, let registration = registeredOffset(current: current, previous: previous,
        rect: CGRect(x: left, y: top, width: right - left, height: bodyHeight)), abs(registration) <= maxShift {
        for offset in (registration - 2)...(registration + 2) where abs(offset) <= maxShift {
          let fraction = allowSmoothing ? 0 : verticalPhase(offset: offset, top: top, bottom: bottom,
            left: left, right: right, a: ap, b: bp, aStride: aStride, bStride: bStride)
          if let score = verify(offset: offset, top: top, bottom: bottom, left: left, right: right,
            a: ap, b: bp, aStride: aStride, bStride: bStride, requireTexture: true, fraction: fraction) {
            matches.append((offset, score, fraction))
          }
        }
      }
      matches.sort { $0.score < $1.score }
      guard let best = matches.first else { return nil }
      // Adjacent integer candidates can describe the same half-pixel position.
      // Distinct translations (including repeated rows) must still be unambiguous.
      if matches.dropFirst().contains(where: {
        abs(Double($0.offset - best.offset) + $0.fraction - best.fraction) > 0.5
          && $0.score <= max(1, best.score * 1.5)
      }) { return nil }
      return Match(offset: best.offset, fraction: best.fraction, header: top, footer: height - bottom)
    }
  }

  /// Nine rows suppress antialiasing phase changes without mixing adjacent columns.
  /// Crop before filtering so fixed headers/footers cannot bleed into moving text.
  private static func verticallySmoothed(_ image: CGImage, top: Int, bottom: Int) -> CGImage? {
    let height = bottom - top
    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
          let output = NSMutableData(length: image.width * height * 4) else { return nil }
    return withExtendedLifetime(data) {
      var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bytes + top * image.bytesPerRow),
        height: vImagePixelCount(height), width: vImagePixelCount(image.width), rowBytes: image.bytesPerRow)
      var target = vImage_Buffer(data: output.mutableBytes,
        height: source.height, width: source.width, rowBytes: image.width * 4)
      guard vImageBoxConvolve_ARGB8888(&source, &target, nil, 0, 0, 9, 1, nil,
        vImage_Flags(kvImageEdgeExtend)) == kvImageNoError,
        let provider = CGDataProvider(data: output as CFData) else { return nil }
      return CGImage(width: image.width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: image.width * 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: image.bitmapInfo, provider: provider, decode: nil,
        shouldInterpolate: false, intent: image.renderingIntent)
    }
  }

  /// Least-squares interpolation within half a pixel, shared by the entire overlap.
  /// Per-pixel tolerances would also accept warped or genuinely changed content.
  private static func verticalPhase(offset: Int, top: Int, bottom: Int, left: Int, right: Int,
    a: UnsafePointer<UInt8>, b: UnsafePointer<UInt8>, aStride: Int, bStride: Int) -> Double {
    let start = max(top, top - offset), end = min(bottom, bottom - offset)
    var best = 0.0, improvement = 0.0
    for direction in [-1, 1] {
      var numerator = 0.0, denominator = 0.0
      for y in stride(from: start, to: end, by: max(1, (end - start) / 180)) {
        for x in stride(from: left, to: right, by: max(1, (right - left) / 180)) {
          let ai = y * aStride + x * 4, bi = (y + offset) * bStride + x * 4
          let ni = min(bottom - 1, max(top, y + offset + direction)) * bStride + x * 4
          for c in 0..<3 {
            let gradient = Double(Int(b[ni + c]) - Int(b[bi + c]))
            numerator += Double(Int(a[ai + c]) - Int(b[bi + c])) * gradient
            denominator += gradient * gradient
          }
        }
      }
      guard denominator > 0 else { continue }
      let fraction = min(0.5, max(0, numerator / denominator))
      let gain = 2 * fraction * numerator - fraction * fraction * denominator
      if gain > improvement { improvement = gain; best = Double(direction) * fraction }
    }
    return best
  }

  private static func registeredOffset(current: CGImage, previous: CGImage, rect: CGRect) -> Int? {
    guard rect.width >= 50, rect.height >= 50,
          let target = previous.cropping(to: rect), let source = current.cropping(to: rect) else { return nil }
    let request = VNTranslationalImageRegistrationRequest(targetedCGImage: target)
    do { try VNImageRequestHandler(cgImage: source, options: [:]).perform([request]) }
    catch { return nil }
    guard let result = request.results?.first as? VNImageTranslationAlignmentObservation,
          result.alignmentTransform.ty.isFinite,
          abs(result.alignmentTransform.tx) <= 1 else { return nil }
    return Int(result.alignmentTransform.ty.rounded())
  }

  /// 比较整个有效重叠区,同时检查文字/图像边缘,避免大片白底稀释错位误差。
  /// `tolerateMotion`:按竖条分别校验,允许不到一半的竖条(动图所在列)对不上;
  /// 其余竖条照旧严格且要有足够纹理。整行横贯的变化(内容插入/替换)仍会拒掉。
  private static func verify(offset: Int, top: Int, bottom: Int, left: Int, right: Int,
    a: UnsafePointer<UInt8>, b: UnsafePointer<UInt8>, aStride: Int, bStride: Int,
    requireTexture: Bool, fraction: Double = 0, tolerateMotion: Bool = false) -> Double? {
    let start = max(top, top - offset), end = min(bottom, bottom - offset)
    guard end > start else { return nil }
    let stripCount = tolerateMotion ? 12 : 1
    var strips = [Tally](repeating: Tally(), count: stripCount)
    var rowTexture = [Bool](repeating: false, count: stripCount)
    for y in stride(from: start, to: end, by: max(1, (end - start) / 180)) {
      for i in 0..<stripCount { rowTexture[i] = false }
      for x in stride(from: left, to: right, by: max(1, (right - left) / 180)) {
        let strip = (x - left) * stripCount / (right - left)
        let ai = y * aStride + x * 4, bi = (y + offset) * bStride + x * 4
        let dx = x + 1 < right ? 4 : -4
        let aNext = min(end - 1, y + 1) * aStride + x * 4
        let bNext = min(end + offset - 1, y + offset + 1) * bStride + x * 4
        let phaseRow = min(bottom - 1, max(top, y + offset + (fraction < 0 ? -1 : 1))) * bStride + x * 4
        var difference = 0.0, texture = 0
        for c in 0..<3 {
          let target = Double(b[bi + c]) + abs(fraction) * Double(Int(b[phaseRow + c]) - Int(b[bi + c]))
          difference += abs(Double(a[ai + c]) - target)
          texture += abs(Int(a[ai + c]) - Int(a[ai + dx + c]))
            + abs(Int(b[bi + c]) - Int(b[bi + dx + c]))
            + abs(Int(a[ai + c]) - Int(a[aNext + c]))
            + abs(Int(b[bi + c]) - Int(b[bNext + c]))
        }
        strips[strip].error += difference
        strips[strip].samples += 1
        if texture > 18 {
          strips[strip].edges += 1
          strips[strip].edgeError += difference
          if difference > 30 { strips[strip].badEdges += 1 }
          rowTexture[strip] = true
        }
      }
      for i in 0..<stripCount where rowTexture[i] { strips[i].texturedRows += 1 }
    }
    let used = strips.filter { $0.samples > 0 }
    let passed = used.filter(\.passes)
    guard !passed.isEmpty, passed.count * 2 >= used.count else { return nil }
    let total = passed.reduce(into: Tally()) { $0.add($1) }
    if requireTexture && (total.edges < 48 || total.texturedRows < 3) { return nil }
    return (total.error + total.edgeError) / Double(total.samples + total.edges)
  }

  private struct Tally {
    var error = 0.0, edgeError = 0.0
    var samples = 0, edges = 0, badEdges = 0, texturedRows = 0

    var passes: Bool {
      samples > 0 && error / Double(samples) <= 6
        && (edges == 0 || (edgeError / Double(edges) <= 10 && Double(badEdges) / Double(edges) <= 0.04))
    }

    mutating func add(_ other: Tally) {
      error += other.error; edgeError += other.edgeError
      samples += other.samples; edges += other.edges
      badEdges += other.badEdges; texturedRows += other.texturedRows
    }
  }
}
