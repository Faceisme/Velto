import AppKit
import AVFoundation
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
    let windowInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] ?? []
    var result: [DisplaySnapshot] = []
    for display in content.displays {
      // I1:在循环顶部缓存 scale,避免每次重复查询 NSScreen
      let scale = displayScale(display)
      let image: CGImage
      let backend: String
      if requiresCompatibilityCapture(windowInfo: windowInfo, displayFrame: display.frame) {
        do {
          image = try await captureCompatibilityDisplayImage(displayID: display.displayID)
          backend = "AVCaptureScreenInput"
        } catch {
          ScreenshotDebugLog.log(
            "AV capture failed for display \(display.displayID), falling back: \(error.localizedDescription)"
          )
          image = try await screenCaptureKitImage(for: display, scale: scale)
          backend = "ScreenCaptureKit fallback"
        }
      } else {
        image = try await screenCaptureKitImage(for: display, scale: scale)
        backend = "ScreenCaptureKit"
      }
      result.append(DisplaySnapshot(
        displayID: display.displayID,
        image: image,
        // C1:NSScreen 查不到时用 cgFrameToNSFrame 翻转坐标系,而非直接用 CG 左上原点的 frame
        frame: nsScreenFrame(for: display.displayID) ?? cgFrameToNSFrame(display.frame),
        scale: scale
      ))
      ScreenshotDebugLog.log(
        "captured display \(display.displayID) \(image.width)x\(image.height) via \(backend)"
      )
    }
    return result
  }

  /// `sharingNone` 窗口唯一可用的整屏捕获后端。截图与切换器缩略图共用，
  /// 避免两边各维护一套 AVCaptureSession 生命周期。
  static func captureCompatibilityDisplayImage(
    displayID: CGDirectDisplayID,
    cropRect: CGRect? = nil,
    scaleFactor: CGFloat = 1
  ) async throws -> CGImage {
    try await AVDisplayFrameCapture(
      displayID: displayID,
      cropRect: cropRect,
      scaleFactor: scaleFactor
    ).capture()
  }

  static func requiresCompatibilityCapture(
    windowInfo: [[String: Any]],
    displayFrame: CGRect
  ) -> Bool {
    windowInfo.contains { window in
      guard
        (window[kCGWindowSharingState as String] as? NSNumber)?.uint32Value
          == CGWindowSharingType.none.rawValue,
        (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
        alpha > 0,
        let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
        !bounds.isEmpty
      else { return false }
      return bounds.intersects(displayFrame)
    }
  }

  /// 选区(全局点坐标)→ 在该快照上裁剪出像素图。
  static func crop(_ snapshot: DisplaySnapshot, toPointRect rect: CGRect) -> CGImage? {
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
    return snapshot.image.cropping(to: px.integral)
  }

  /// 实时捕获快照显示器内的全局点坐标选区。
  @MainActor
  static func captureRegion(in snapshot: DisplaySnapshot, globalRect: CGRect) async throws -> CGImage? {
    let filter: SCContentFilter
    if let cachedFilter = regionCaptureFilters[snapshot.displayID] {
      filter = cachedFilter
    } else {
      let content = try await SCShareableContent.current
      guard let display = content.displays.first(where: { $0.displayID == snapshot.displayID }) else {
        return nil
      }
      let excludedApplications = content.applications.filter {
        $0.processID == ProcessInfo.processInfo.processIdentifier
      }
      filter = SCContentFilter(
        display: display,
        excludingApplications: excludedApplications,
        exceptingWindows: []
      )
      regionCaptureFilters[snapshot.displayID] = filter
    }

    let localX = globalRect.minX - snapshot.frame.minX
    let localTopY = snapshot.frame.maxY - globalRect.maxY
    let config = SCStreamConfiguration()
    config.showsCursor = false
    config.sourceRect = CGRect(
      x: localX,
      y: localTopY,
      width: globalRect.width,
      height: globalRect.height
    )
    config.width = Int(globalRect.width * snapshot.scale)
    config.height = Int(globalRect.height * snapshot.scale)
    return try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: config
    )
  }

  // MARK: - 私有辅助

  private static func screenCaptureKitImage(for display: SCDisplay, scale: CGFloat) async throws -> CGImage {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.width = Int(CGFloat(display.width) * scale)
    config.height = Int(CGFloat(display.height) * scale)
    config.showsCursor = false
    return try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: config
    )
  }

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

private enum AVDisplayCaptureError: LocalizedError {
  case inputUnavailable(CGDirectDisplayID)
  case sessionConfigurationFailed(CGDirectDisplayID)
  case timedOut(CGDirectDisplayID)
  case missingPixelBuffer(CGDirectDisplayID)
  case imageConversionFailed(CGDirectDisplayID, OSStatus)

  var errorDescription: String? {
    switch self {
    case .inputUnavailable(let id):
      "无法创建显示器 \(id) 的 AV 截图输入"
    case .sessionConfigurationFailed(let id):
      "无法配置显示器 \(id) 的 AV 截图会话"
    case .timedOut(let id):
      "等待显示器 \(id) 的 AV 截图帧超时"
    case .missingPixelBuffer(let id):
      "显示器 \(id) 的 AV 截图帧没有像素缓冲区"
    case .imageConversionFailed(let id, let status):
      "显示器 \(id) 的 AV 截图帧转换失败: \(status)"
    }
  }
}

private final class AVDisplayFrameCapture: NSObject,
  AVCaptureVideoDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  private let displayID: CGDirectDisplayID
  private let cropRect: CGRect?
  private let scaleFactor: CGFloat
  private let queue: DispatchQueue
  private var continuation: CheckedContinuation<CGImage, any Error>?
  private var session: AVCaptureSession?
  private var output: AVCaptureVideoDataOutput?
  private var outcome: Result<CGImage, any Error>?

  init(displayID: CGDirectDisplayID, cropRect: CGRect?, scaleFactor: CGFloat) {
    self.displayID = displayID
    self.cropRect = cropRect
    self.scaleFactor = scaleFactor
    queue = DispatchQueue(label: "com.velto.screenshot.av-display-\(displayID)")
  }

  func capture() async throws -> CGImage {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.continuation = continuation
        self.start()
      }
    }
  }

  private func start() {
    guard let input = AVCaptureScreenInput(displayID: displayID) else {
      complete(.failure(AVDisplayCaptureError.inputUnavailable(displayID)))
      return
    }
    input.capturesCursor = false
    input.capturesMouseClicks = false
    if let cropRect {
      input.cropRect = cropRect
      input.scaleFactor = scaleFactor
    }

    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    output.setSampleBufferDelegate(self, queue: queue)

    let session = AVCaptureSession()
    guard session.canAddInput(input), session.canAddOutput(output) else {
      complete(.failure(AVDisplayCaptureError.sessionConfigurationFailed(displayID)))
      return
    }
    session.beginConfiguration()
    session.addInput(input)
    session.addOutput(output)
    session.commitConfiguration()
    self.output = output
    self.session = session
    session.startRunning()

    queue.asyncAfter(deadline: .now() + 2) {
      self.complete(.failure(AVDisplayCaptureError.timedOut(self.displayID)))
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      complete(.failure(AVDisplayCaptureError.missingPixelBuffer(displayID)))
      return
    }
    var image: CGImage?
    let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
    guard status == noErr, let image else {
      complete(.failure(AVDisplayCaptureError.imageConversionFailed(displayID, status)))
      return
    }
    complete(.success(image))
  }

  private func complete(_ result: Result<CGImage, any Error>) {
    guard continuation != nil, outcome == nil else { return }
    outcome = result
    output?.setSampleBufferDelegate(nil, queue: nil)
    queue.async { self.stopAndResume() }
  }

  private func stopAndResume() {
    if session?.isRunning == true { session?.stopRunning() }
    session = nil
    output = nil
    guard let continuation, let outcome else { return }
    self.continuation = nil
    self.outcome = nil
    continuation.resume(with: outcome)
  }
}
