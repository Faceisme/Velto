import ApplicationServices
import CoreGraphics
import XCTest
@testable import Velto

/// 回归:富途牛牛这类对 Accessibility 零窗口暴露的 app,靠 CGWindowList 兜底
/// 进切换器。这里只测行过滤纯函数 cgFallbackProbe —— 真窗口留下、噪音丢弃。
final class SwitcherCgFallbackProbeTests: XCTestCase {
    private let appElement = AXUIElementCreateApplication(getpid())
    private let pid: pid_t = 4242

    private func row(
        pid: Int? = 4242,
        layer: Int? = 0,
        wid: Int? = 100,
        name: String? = "富途牛牛",
        alpha: Double = 1.0,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 1728, height: 1026)
    ) -> [String: Any] {
        var r: [String: Any] = [:]
        if let pid { r[kCGWindowOwnerPID as String] = pid }
        if let layer { r[kCGWindowLayer as String] = layer }
        if let wid { r[kCGWindowNumber as String] = wid }
        if let name { r[kCGWindowName as String] = name }
        r[kCGWindowAlpha as String] = alpha
        r[kCGWindowBounds as String] = [
            "X": bounds.origin.x, "Y": bounds.origin.y,
            "Width": bounds.size.width, "Height": bounds.size.height,
        ]
        return r
    }

    private func probe(_ r: [String: Any]) -> SwitcherWindowProbe? {
        SwitcherWindowList.cgFallbackProbe(row: r, pid: pid, appElement: appElement)
    }

    func testKeepsRealTitledMainWindow() {
        let p = probe(row())
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.wid, 100)
        XCTAssertEqual(p?.title, "富途牛牛")
        XCTAssertTrue(p?.isCgOnly ?? false)
        XCTAssertEqual(p?.subrole, kAXStandardWindowSubrole as String)
    }

    func testDropsOtherApp() {
        XCTAssertNil(probe(row(pid: 9999)))
    }

    func testDropsNonZeroLayer() {
        XCTAssertNil(probe(row(layer: 25)))          // 菜单/浮层
    }

    func testDropsUntitledStrip() {
        XCTAssertNil(probe(row(name: "", bounds: CGRect(x: 0, y: 0, width: 1728, height: 33))))
        XCTAssertNil(probe(row(name: nil)))
    }

    func testDropsNearInvisibleAlpha() {
        XCTAssertNil(probe(row(name: "牛牛AI", alpha: 0.001)))
    }

    func testDropsTooSmall() {
        XCTAssertNil(probe(row(bounds: CGRect(x: 0, y: 0, width: 80, height: 40))))
    }

    func testTrimsWhitespaceTitle() {
        XCTAssertNil(probe(row(name: "   ")))
    }
}
