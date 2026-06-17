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
  /// 启动后预热,SCShareableContent 首次查询有延迟。
  static func prewarm() {
    Task.detached(priority: .utility) { _ = try? await SCShareableContent.current }
  }

  static func captureAllDisplays() async throws -> [DisplaySnapshot] {
    let content = try await SCShareableContent.current
    var result: [DisplaySnapshot] = []
    for display in content.displays {
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let config = SCStreamConfiguration()
      config.width = Int(CGFloat(display.width) * displayScale(display.displayID))
      config.height = Int(CGFloat(display.height) * displayScale(display.displayID))
      config.showsCursor = false
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
      result.append(DisplaySnapshot(
        displayID: display.displayID,
        image: image,
        frame: nsScreenFrame(for: display.displayID) ?? display.frame,
        scale: displayScale(display.displayID)
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

  // MARK: - 私有辅助

  private static func displayScale(_ id: CGDirectDisplayID) -> CGFloat {
    nsScreen(for: id)?.backingScaleFactor ?? 2.0
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
