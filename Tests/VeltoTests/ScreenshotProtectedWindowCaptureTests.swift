import CoreGraphics
import XCTest
@testable import Velto

final class ScreenshotProtectedWindowCaptureTests: XCTestCase {
  func testIntersectingSharingNoneWindowRequiresCompatibilityCapture() {
    let windows = [windowInfo(
      sharing: CGWindowSharingType.none.rawValue,
      layer: 0,
      alpha: 1,
      bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
    )]

    XCTAssertTrue(ScreenshotCapturer.requiresCompatibilityCapture(
      windowInfo: windows,
      displayFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117)
    ))
  }

  func testOrdinaryOrInvisibleWindowsKeepScreenCaptureKitPath() {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let windows = [
      windowInfo(sharing: CGWindowSharingType.readOnly.rawValue, layer: 0, alpha: 1,
                 bounds: CGRect(x: 100, y: 100, width: 500, height: 400)),
      windowInfo(sharing: CGWindowSharingType.none.rawValue, layer: 1, alpha: 1,
                 bounds: CGRect(x: 100, y: 100, width: 500, height: 400)),
      windowInfo(sharing: CGWindowSharingType.none.rawValue, layer: 0, alpha: 0,
                 bounds: CGRect(x: 100, y: 100, width: 500, height: 400)),
      windowInfo(sharing: CGWindowSharingType.none.rawValue, layer: 0, alpha: 1,
                 bounds: CGRect(x: 2000, y: 100, width: 500, height: 400)),
    ]

    XCTAssertFalse(ScreenshotCapturer.requiresCompatibilityCapture(
      windowInfo: windows,
      displayFrame: display
    ))
  }

  private func windowInfo(
    sharing: UInt32,
    layer: Int,
    alpha: Double,
    bounds: CGRect
  ) -> [String: Any] {
    [
      kCGWindowSharingState as String: NSNumber(value: sharing),
      kCGWindowLayer as String: NSNumber(value: layer),
      kCGWindowAlpha as String: NSNumber(value: alpha),
      kCGWindowBounds as String: CGRectCreateDictionaryRepresentation(bounds),
    ]
  }
}
