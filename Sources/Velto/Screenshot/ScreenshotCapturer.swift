import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import VideoToolbox

struct DisplaySnapshot {
  let displayID: CGDirectDisplayID
  let image: CGImage
  let frame: CGRect   // 全局点坐标(NSScreen.frame 语义,左下原点)
  let scale: CGFloat
}

enum ScreenshotCapturer {
  @MainActor private static var regionCaptureFilters: [CGDirectDisplayID: SCContentFilter] = [:]

  /// 启动后预热,SCShareableContent 首次查询有延迟。
  static func prewarm() {
    Task.detached(priority: .utility) { _ = try? await SCShareableContent.current }
  }

  static func captureAllDisplays() async throws -> [DisplaySnapshot] {
    let content = try await SCShareableContent.current
    var result: [DisplaySnapshot] = []
    for display in content.displays {
      // I1:在循环顶部缓存 scale,避免每次重复查询 NSScreen
      let scale = displayScale(display)
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let config = SCStreamConfiguration()
      config.width = Int(CGFloat(display.width) * scale)
      config.height = Int(CGFloat(display.height) * scale)
      config.showsCursor = false
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
      result.append(DisplaySnapshot(
        displayID: display.displayID,
        image: image,
        // C1:NSScreen 查不到时用 cgFrameToNSFrame 翻转坐标系,而非直接用 CG 左上原点的 frame
        frame: nsScreenFrame(for: display.displayID) ?? cgFrameToNSFrame(display.frame),
        scale: scale
      ))
      ScreenshotDebugLog.log("captured display \(display.displayID) \(image.width)x\(image.height)")
    }
    return result
  }

  /// 选区(全局点坐标)→ 在该快照上裁剪出像素图。
  static func crop(_ snapshot: DisplaySnapshot, toPointRect rect: CGRect) -> CGImage? {
    snapshot.image.cropping(to: pixelRect(in: snapshot, globalRect: rect))
  }

  private static func pixelRect(in snapshot: DisplaySnapshot, globalRect rect: CGRect) -> CGRect {
    guard !rect.isNull, !rect.isInfinite, snapshot.scale.isFinite, snapshot.scale > 0,
          rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
          rect.width > 0, rect.height > 0 else { return .null }
    // 把全局点坐标换成「相对快照左上角」的像素坐标。
    // NSScreen 左下原点 → CGImage 左上原点要翻转 Y。
    let relX = rect.origin.x - snapshot.frame.origin.x
    let relTopY = snapshot.frame.maxY - rect.maxY   // 翻转:距快照顶部的点距离
    let px = CGRect(
      x: relX * snapshot.scale,
      y: relTopY * snapshot.scale,
      width: rect.width * snapshot.scale,
      height: rect.height * snapshot.scale
    )
    return px.integral.intersection(CGRect(x: 0, y: 0,
      width: snapshot.image.width, height: snapshot.image.height))
  }

  static func regionConfiguration(in snapshot: DisplaySnapshot, globalRect: CGRect) -> SCStreamConfiguration? {
    let pixels = pixelRect(in: snapshot, globalRect: globalRect)
    guard !pixels.isNull, !pixels.isEmpty else { return nil }
    let config = SCStreamConfiguration()
    config.showsCursor = false
    // Match ordinary cropping on the backing-pixel grid. A fractional source
    // resized to truncated integer dimensions resamples every captured text edge.
    config.sourceRect = CGRect(x: pixels.minX / snapshot.scale, y: pixels.minY / snapshot.scale,
      width: pixels.width / snapshot.scale, height: pixels.height / snapshot.scale)
    config.width = Int(pixels.width)
    config.height = Int(pixels.height)
    return config
  }

  /// 实时捕获快照显示器内的全局点坐标选区。
  @MainActor
  static func captureRegion(in snapshot: DisplaySnapshot, globalRect: CGRect) async throws -> CGImage? {
    guard let config = regionConfiguration(in: snapshot, globalRect: globalRect),
          let filter = try await regionFilter(for: snapshot) else { return nil }
    return try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: config
    )
  }

  /// 整屏排除 Velto 自身窗口的滤镜,按显示器缓存。
  @MainActor
  static func regionFilter(for snapshot: DisplaySnapshot) async throws -> SCContentFilter? {
    if let cachedFilter = regionCaptureFilters[snapshot.displayID] { return cachedFilter }
    let content = try await SCShareableContent.current
    guard let display = content.displays.first(where: { $0.displayID == snapshot.displayID }) else {
      return nil
    }
    let excludedApplications = content.applications.filter {
      $0.processID == ProcessInfo.processInfo.processIdentifier
    }
    let filter = SCContentFilter(
      display: display,
      excludingApplications: excludedApplications,
      exceptingWindows: []
    )
    regionCaptureFilters[snapshot.displayID] = filter
    return filter
  }

  // MARK: - 私有辅助

  /// I2:接收 SCDisplay,NSScreen 查不到时用 CG API 从像素/点比例推算真实 scale。
  /// 只有 display.height 为 0 的退化情形才最后退回 2.0。
  private static func displayScale(_ display: SCDisplay) -> CGFloat {
    if let s = nsScreen(for: display.displayID)?.backingScaleFactor { return s }
    let pixelHigh = CGFloat(CGDisplayPixelsHigh(display.displayID))
    return display.height > 0 ? pixelHigh / CGFloat(display.height) : 2.0
  }

  /// C1:把 SCDisplay.frame(CG 左上原点)转成 NSScreen 左下原点全局坐标。
  /// 仅在 NSScreen 查不到对应 displayID 的兜底路径用。
  private static func cgFrameToNSFrame(_ cgFrame: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? cgFrame.height
    return CGRect(
      x: cgFrame.origin.x,
      y: primaryHeight - cgFrame.maxY,
      width: cgFrame.width,
      height: cgFrame.height
    )
  }

  private static func nsScreen(for id: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
    }
  }

  private static func nsScreenFrame(for id: CGDirectDisplayID) -> CGRect? {
    nsScreen(for: id)?.frame
  }
}

/// 滚动截图期间常驻的选区采集流。逐帧调 SCScreenshotManager 每次都是一次新的采集会话:
/// tccd/syspolicyd/trustd 要重新校验、菜单栏录屏指示器要刷新,每秒十来次能吃掉近一个核,
/// 滚动明显发卡。常驻流只在开头校验一次,取帧也从 ~55ms 变成直接拿最新帧。
final class RegionFrameStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private var stream: SCStream?
  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private var stopped = false
  private var count = 0

  /// 每来一张有新内容的帧加一;没变就不必重新匹配。
  var sequence: Int { lock.withLock { count } }

  /// 起流并等到首帧(最多 0.5 秒);失败返回 nil,调用方退回逐帧截图。
  @MainActor
  static func start(in snapshot: DisplaySnapshot, globalRect: CGRect) async -> RegionFrameStream? {
    guard let config = ScreenshotCapturer.regionConfiguration(in: snapshot, globalRect: globalRect),
          let filter = try? await ScreenshotCapturer.regionFilter(for: snapshot) else { return nil }
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.queueDepth = 5
    let output = RegionFrameStream()
    let stream = SCStream(filter: filter, configuration: config, delegate: output)
    output.stream = stream
    do {
      try stream.addStreamOutput(output, type: .screen,
        sampleHandlerQueue: DispatchQueue(label: "com.face.velto.screenshot.region-stream", qos: .userInitiated))
      try await stream.startCapture()
    } catch {
      output.stop()
      return nil
    }
    for _ in 0..<50 where output.sequence == 0 {
      try? await Task.sleep(for: .milliseconds(10))
    }
    guard output.sequence > 0 else {
      output.stop()
      return nil
    }
    return output
  }

  /// 最新一帧;流已停(出错、显示器睡眠等)返回 nil。
  func latestImage() -> CGImage? {
    guard let buffer = lock.withLock({ stopped ? nil : latest }) else { return nil }
    var image: CGImage?
    VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
    return image
  }

  func stop() {
    let stream = lock.withLock {
      stopped = true
      latest = nil
      defer { self.stream = nil }
      return self.stream
    }
    guard let stream else { return }
    try? stream.removeStreamOutput(self, type: .screen)
    stream.stopCapture { _ in }
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen,
          let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
          let status = info.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
          let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    lock.withLock {
      guard !stopped else { return }
      latest = buffer
      count += 1
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    ScreenshotDebugLog.log("滚动截图采集流中断,退回逐帧截图:\(error.localizedDescription)")
    lock.withLock {
      stopped = true
      latest = nil
    }
  }
}
