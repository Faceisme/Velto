public enum ScrollOverlapDetector {
  public static func appendableRowCount(
    canvasTail: [UInt64],
    frame: [UInt64],
    maxMismatchFraction: Double = 0.1,
    minOverlapRows: Int = 8
  ) -> Int? {
    guard !frame.isEmpty else { return 0 }
    guard !canvasTail.isEmpty else { return frame.count }

    let maxOverlap = min(canvasTail.count, frame.count)
    let minimumTrustedOverlap = max(minOverlapRows, maxOverlap / 5)
    guard maxOverlap >= minimumTrustedOverlap else { return nil }

    for overlap in stride(from: maxOverlap, through: minimumTrustedOverlap, by: -1) {
      let canvasStart = canvasTail.count - overlap
      let allowedMismatches = Int(Double(overlap) * maxMismatchFraction)
      var mismatches = 0

      // 比较画布尾部与新帧头部，只接受误差比例内的最长重叠。
      for row in 0..<overlap {
        if canvasTail[canvasStart + row] != frame[row] {
          mismatches += 1
          if mismatches > allowedMismatches {
            break
          }
        }
      }

      if mismatches <= allowedMismatches {
        return frame.count - overlap
      }
    }

    return nil
  }
}
