import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

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
